import Foundation

public protocol ApprovalRequesting: Sendable {
    func requestApproval(_ preview: ApprovalPreview) async -> Bool
}

public struct FixedApprovalRequester: ApprovalRequesting, Sendable {
    public var approved: Bool
    public init(approved: Bool) { self.approved = approved }
    public func requestApproval(_ preview: ApprovalPreview) async -> Bool { approved }
}

public struct StructuredToolExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .structuredTool

    private let capabilityProbe: CapabilityProbing
    private let appResolver: AppContainerResolving
    private let resourceResolver: ResourceResolver
    private let fileService: FileService
    private let ipaService: IPAService
    private let trashService: TrashService
    private let transactionEngine: TransactionEngine
    private let policy: PolicyEngine
    private let audit: AuditLogStore
    private let approval: ApprovalRequesting

    public init(
        capabilityProbe: CapabilityProbing,
        appResolver: AppContainerResolving,
        resourceResolver: ResourceResolver,
        fileService: FileService,
        ipaService: IPAService,
        trashService: TrashService,
        transactionEngine: TransactionEngine,
        policy: PolicyEngine,
        audit: AuditLogStore,
        approval: ApprovalRequesting
    ) {
        self.capabilityProbe = capabilityProbe
        self.appResolver = appResolver
        self.resourceResolver = resourceResolver
        self.fileService = fileService
        self.ipaService = ipaService
        self.trashService = trashService
        self.transactionEngine = transactionEngine
        self.policy = policy
        self.audit = audit
        self.approval = approval
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        let supported: Set<String> = [
            "capability.probe", "apps.list", "apps.inspect", "container.resolve",
            "files.list", "files.search", "files.read", "storage.analyze", "files.create",
            "files.modify", "files.delete", "trash.restore", "trash.purge",
            "ipa.locate", "ipa.inspect", "ipa.extract", "ipa.repack"
        ]
        return supported.contains(tool.name)
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        switch call.name {
        case "capability.probe":
            let profile = await capabilityProbe.probe()
            let payload = Dictionary(uniqueKeysWithValues: profile.records.map { ($0.id, $0.status.rawValue) })
            return ToolResult(toolCallID: call.id, success: true, summary: "Capability probe completed", payload: payload)

        case "apps.list":
            let apps = await appResolver.installedApps()
            let encoded = try String(data: JSONEncoder.pretty.encode(apps), encoding: .utf8) ?? "[]"
            return ToolResult(toolCallID: call.id, success: true, summary: "Found \(apps.count) apps", payload: ["apps": encoded])

        case "apps.inspect":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let node = try await resourceResolver.resolve(ResourceID("app://\(bundleID)"))
            let dataContainer = await appResolver.dataContainerPath(for: bundleID)
            var payload = node.metadata
            payload["bundleId"] = bundleID
            payload["bundlePath"] = node.resolvedPath ?? ""
            payload["dataContainer"] = dataContainer ?? ""
            return ToolResult(toolCallID: call.id, success: true, summary: "Resolved \(bundleID)", payload: payload)

        case "container.resolve":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let node = try await resourceResolver.resolve(ResourceID("container://\(bundleID)"))
            return ToolResult(toolCallID: call.id, success: true, summary: "Container resolved", payload: ["logical": node.logicalLocation, "path": node.resolvedPath ?? ""])

        case "files.list":
            let url = try requiredURL(call, key: "path")
            let entries = try fileService.list(directory: url, allowedRoot: context.allowedRoot)
            return try result(call.id, summary: "Listed \(entries.count) entries", key: "entries", value: entries)

        case "files.search":
            let root = try requiredURL(call, key: "path")
            let query = FileSearchQuery(
                nameContains: call.arguments["query"],
                extensions: call.arguments["extension"].map { [$0.lowercased()] } ?? [],
                maxDepth: Int(call.arguments["maxDepth"] ?? "6") ?? 6,
                maxResults: Int(call.arguments["maxResults"] ?? "500") ?? 500
            )
            let entries = try fileService.search(root: root, query: query, allowedRoot: context.allowedRoot)
            return try result(call.id, summary: "Found \(entries.count) entries", key: "entries", value: entries)

        case "files.read":
            let url = try requiredURL(call, key: "path")
            let text = try fileService.readText(url, allowedRoot: context.allowedRoot)
            let envelope = ToolOutputEnvelope(trust: .untrustedData, source: url.path, content: text)
            return ToolResult(toolCallID: call.id, success: true, summary: "Read \(url.lastPathComponent)", payload: ["content": envelope.promptSafeRepresentation])

        case "storage.analyze":
            let root = try requiredURL(call, key: "path")
            let entries = try fileService.analyzeStorage(root: root, allowedRoot: context.allowedRoot, top: Int(call.arguments["top"] ?? "50") ?? 50)
            return try result(call.id, summary: "Analyzed storage", key: "largestFiles", value: entries)

        case "files.create":
            let target = try requiredURL(call, key: "path")
            let guarded = try PathGuard().validate(target: target, allowedRoot: context.allowedRoot, rejectSymlink: true)
            if FileManager.default.fileExists(atPath: guarded.path) { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: guarded.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((call.arguments["content"] ?? "").utf8).write(to: guarded, options: [.atomic])
            let verification = VerificationResult(passed: FileManager.default.fileExists(atPath: guarded.path), checks: ["created target exists"], failures: [])
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: guarded.path, risk: descriptor.risk, result: verification.passed ? "created" : "verification_failed"))
            return ToolResult(toolCallID: call.id, success: verification.passed, summary: "Created \(guarded.lastPathComponent)", payload: ["path": guarded.path], verification: verification)

        case "files.modify":
            let target = try requiredURL(call, key: "path")
            let proposed = Data((call.arguments["content"] ?? "").utf8)
            let transaction = try await transactionEngine.replaceFile(
                target: target,
                proposedData: proposed,
                tool: descriptor,
                sessionID: call.sessionID,
                toolCallID: call.id,
                mode: context.permissionMode,
                reason: call.arguments["reason"] ?? "Agent requested modification",
                allowedRoot: context.allowedRoot,
                approval: { preview in await approval.requestApproval(preview) },
                verify: { url in
                    let actual = try Data(contentsOf: url)
                    let passed = actual == proposed
                    return VerificationResult(passed: passed, checks: ["re-read target after atomic replace"], failures: passed ? [] : ["target bytes differ from proposal"])
                }
            )
            return try result(call.id, summary: "Transaction \(transaction.state.rawValue)", key: "transaction", value: transaction)

        case "files.delete":
            let target = try requiredURL(call, key: "path")
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: target.path)
            if decision == .requireConfirmation {
                let size = (try? FileManager.default.allocatedSizeOfItem(at: target)) ?? 0
                let preview = ApprovalPreview(
                    title: "Move to Cloud Code Trash",
                    target: target.path,
                    originalSummary: "\(size) bytes",
                    reason: call.arguments["reason"] ?? "Agent requested deletion",
                    plan: ["Validate target", "Snapshot metadata", "Move to Trash", "Verify source removed", "Journal record"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let record = try await trashService.moveToTrash(
                target: target,
                logicalResourceID: call.arguments["logicalResourceId"] ?? "file://\(target.path)",
                sessionID: call.sessionID,
                toolCallID: call.id,
                reason: call.arguments["reason"] ?? "Agent requested deletion",
                sourceApp: call.arguments["sourceApp"],
                allowedRoot: context.allowedRoot
            )
            let passed = !FileManager.default.fileExists(atPath: target.path) && FileManager.default.fileExists(atPath: record.trashPath)
            let verification = VerificationResult(passed: passed, checks: ["source removed", "trash target exists"], failures: passed ? [] : ["trash postcondition failed"])
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: target.path, risk: descriptor.risk, result: passed ? "trashed" : "verification_failed", detail: ["trashID": record.id.uuidString]))
            return try result(call.id, summary: "Moved to Cloud Code Trash", key: "trashRecord", value: record, verification: verification)

        case "trash.restore":
            guard let raw = call.arguments["id"], let id = UUID(uuidString: raw) else { throw CocoaError(.fileNoSuchFile) }
            let record = try await trashService.restore(id)
            let passed = FileManager.default.fileExists(atPath: record.originalPath)
            return try result(call.id, summary: "Restored \(record.filename)", key: "trashRecord", value: record, verification: VerificationResult(passed: passed, checks: ["original path exists"], failures: passed ? [] : ["restore target missing"]))

        case "trash.purge":
            guard let raw = call.arguments["id"], let id = UUID(uuidString: raw) else { throw CocoaError(.fileNoSuchFile) }
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, explicitlyPermanent: true)
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(title: "Permanently delete Trash item", target: raw, reason: "Permanent deletion cannot be restored", plan: ["Locate Trash record", "Delete Trash payload", "Update journal"], risk: .permanentDestructive)
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            try await trashService.permanentlyDelete(id)
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: raw, risk: descriptor.risk, result: "permanently_deleted"))
            return ToolResult(toolCallID: call.id, success: true, summary: "Trash item permanently deleted")

        case "ipa.locate":
            let root = try requiredURL(call, key: "path")
            let entries = try ipaService.locate(root: root, fileService: fileService)
            return try result(call.id, summary: "Found \(entries.count) IPA files", key: "ipas", value: entries)

        case "ipa.inspect":
            let target = try requiredURL(call, key: "path")
            let inspection = try ipaService.inspect(target)
            return try result(call.id, summary: "Inspected IPA \(inspection.bundleIdentifier ?? target.lastPathComponent)", key: "inspection", value: inspection)

        case "ipa.extract":
            let target = try requiredURL(call, key: "path")
            guard let destinationRaw = call.arguments["destination"] else { throw ToolRouterError.noExecutionRoute("destination missing") }
            let destination = URL(fileURLWithPath: destinationRaw)
            _ = try PathGuard().validate(target: destination, allowedRoot: context.allowedRoot, rejectSymlink: true)
            try ipaService.extract(target, to: destination)
            let passed = FileManager.default.fileExists(atPath: destination.path)
            let verification = VerificationResult(passed: passed, checks: ["extraction destination exists"], failures: passed ? [] : ["destination missing"])
            return ToolResult(toolCallID: call.id, success: passed, summary: "IPA extracted", payload: ["destination": destination.path], verification: verification)

        case "ipa.repack":
            let source = try requiredURL(call, key: "source")
            let destination = try requiredURL(call, key: "destination")
            _ = try PathGuard().validate(target: source, allowedRoot: context.allowedRoot, rejectSymlink: true)
            _ = try PathGuard().validate(target: destination, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: destination.path)
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: "Repack IPA",
                    target: destination.path,
                    originalSummary: nil,
                    reason: call.arguments["reason"] ?? "Agent requested IPA repack",
                    plan: ["Validate source tree", "Reject symlinks/path traversal", "Create new IPA", "Re-open and inspect archive"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            try ipaService.repack(sourceRoot: source, to: destination)
            let inspection = try ipaService.inspect(destination)
            let verification = VerificationResult(
                passed: inspection.bundleIdentifier != nil,
                checks: ["re-opened generated IPA", "resolved Payload app Info.plist"],
                failures: inspection.bundleIdentifier == nil ? ["generated IPA has no bundle identifier"] : []
            )
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: destination.path, risk: descriptor.risk, result: verification.passed ? "repacked" : "verification_failed"))
            return try result(call.id, summary: "IPA repacked", key: "inspection", value: inspection, verification: verification)

        default:
            throw ToolRouterError.noExecutionRoute(call.name)
        }
    }

    private func requiredURL(_ call: ToolCall, key: String) throws -> URL {
        guard let raw = call.arguments[key], !raw.isEmpty else { throw ToolRouterError.noExecutionRoute("\(key) missing") }
        return URL(fileURLWithPath: raw)
    }

    private func result<T: Encodable>(_ id: UUID, summary: String, key: String, value: T, verification: VerificationResult? = nil) throws -> ToolResult {
        let encoded = try JSONEncoder.pretty.encode(value)
        return ToolResult(toolCallID: id, success: verification?.passed ?? true, summary: summary, payload: [key: String(data: encoded, encoding: .utf8) ?? ""], verification: verification)
    }
}
