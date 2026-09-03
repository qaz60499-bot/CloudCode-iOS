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
    private let secureFileMutation: SecureFileMutation

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
        approval: ApprovalRequesting,
        secureFileMutation: SecureFileMutation = SecureFileMutation()
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
        self.secureFileMutation = secureFileMutation
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
            return ToolResult(toolCallID: call.id, success: true, summary: "能力检测完成", payload: payload)

        case "apps.list":
            let apps = await appResolver.installedApps()
            return try untrustedResult(call.id, summary: "发现 \(apps.count) 个应用", key: "apps", value: apps, source: "apps.list")

        case "apps.inspect":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let node = try await resourceResolver.resolve(ResourceID("app://\(bundleID)"))
            let dataContainer = await appResolver.dataContainerPath(for: bundleID)
            var payload = node.metadata
            payload["bundleId"] = bundleID
            payload["bundlePath"] = node.resolvedPath ?? ""
            payload["dataContainer"] = dataContainer ?? ""
            return try untrustedResult(call.id, summary: "已解析 \(bundleID)", key: "app", value: payload, source: "apps.inspect")

        case "container.resolve":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let node = try await resourceResolver.resolve(ResourceID("container://\(bundleID)"))
            let payload = ["logical": node.logicalLocation, "path": node.resolvedPath ?? ""]
            return try untrustedResult(call.id, summary: "容器解析完成", key: "container", value: payload, source: "container.resolve")

        case "files.list":
            let url = try requiredURL(call, key: "path")
            let entries = try fileService.list(directory: url, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "列出 \(entries.count) 个项目", key: "entries", value: entries, source: "files.list")

        case "files.search":
            let root = try requiredURL(call, key: "path")
            let query = FileSearchQuery(
                nameContains: call.arguments["query"],
                extensions: call.arguments["extension"].map { [$0.lowercased()] } ?? [],
                maxDepth: Int(call.arguments["maxDepth"] ?? "6") ?? 6,
                maxResults: Int(call.arguments["maxResults"] ?? "500") ?? 500
            )
            let entries = try fileService.search(root: root, query: query, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "找到 \(entries.count) 个项目", key: "entries", value: entries, source: "files.search")

        case "files.read":
            let url = try requiredURL(call, key: "path")
            let text = try fileService.readText(url, allowedRoot: context.allowedRoot)
            let envelope = ToolOutputEnvelope(trust: .untrustedData, source: url.path, content: text)
            return ToolResult(toolCallID: call.id, success: true, summary: "已读取 \(url.lastPathComponent)", payload: ["content": envelope.promptSafeRepresentation])

        case "storage.analyze":
            let root = try requiredURL(call, key: "path")
            let entries = try fileService.analyzeStorage(root: root, allowedRoot: context.allowedRoot, top: Int(call.arguments["top"] ?? "50") ?? 50)
            return try untrustedResult(call.id, summary: "存储分析完成", key: "largestFiles", value: entries, source: "storage.analyze")

        case "files.create":
            let target = try requiredURL(call, key: "path")
            let guarded = try PathGuard().validate(target: target, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let approvedParentIdentity = try? secureFileMutation.parentIdentity(of: guarded, allowedRoot: context.allowedRoot)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: guarded.path)
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: "创建文件",
                    target: guarded.path,
                    reason: call.arguments["reason"] ?? "Agent 请求创建可能敏感的文件",
                    plan: ["验证目标路径", "确认后重新验证目标身份", "创建文件", "重新读取并验证内容"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let finalTarget = try PathGuard().validate(target: target, allowedRoot: context.allowedRoot, rejectSymlink: true)
            guard finalTarget.path == guarded.path else { throw PathSafetyError.targetChangedAfterApproval }
            let expected = Data((call.arguments["content"] ?? "").utf8)
            try secureFileMutation.createFile(
                at: finalTarget,
                data: expected,
                allowedRoot: context.allowedRoot,
                createIntermediates: true,
                expectedParentIdentity: approvedParentIdentity
            )
            let passed = true
            let verification = VerificationResult(
                passed: passed,
                checks: ["最终创建相对固定目录 FD 执行", "写入后通过固定文件 FD 重新读取并验证字节"],
                failures: []
            )
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: finalTarget.path, risk: descriptor.risk, result: verification.passed ? "created" : "verification_failed"))
            return ToolResult(toolCallID: call.id, success: verification.passed, summary: "已创建 \(finalTarget.lastPathComponent)", payload: ["path": finalTarget.path], verification: verification)

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
                reason: call.arguments["reason"] ?? "Agent 请求修改",
                allowedRoot: context.allowedRoot,
                approval: { preview in await approval.requestApproval(preview) },
                verify: { url in
                    let actual = try Data(contentsOf: url)
                    let passed = actual == proposed
                    return VerificationResult(passed: passed, checks: ["原子替换后重新读取目标"], failures: passed ? [] : ["目标内容与计划修改不一致"])
                }
            )
            return try untrustedResult(call.id, summary: "事务状态：\(transaction.state.rawValue)", key: "transaction", value: transaction, source: "files.modify")

        case "files.delete":
            let target = try requiredURL(call, key: "path")
            if PathGuard.isSystemManagedApplicationContainerTarget(target.standardizedFileURL.resolvingSymlinksInPath()) {
                throw PathSafetyError.systemManagedApplicationContainer
            }
            // Fail before presenting a generic "move to Cloud Code trash" approval for an installed App.
            // System-managed App bundles/top-level data containers must go through apps.uninstall so
            // LaunchServices registration and container state stay consistent.
            let approvedTarget = try PathGuard().validate(
                target: target,
                allowedRoot: context.allowedRoot,
                rejectSymlink: true,
                recursiveDelete: FileManager.default.directoryExists(at: target)
            )
            let approvedSourceIdentity = try secureFileMutation.identity(of: approvedTarget, allowedRoot: context.allowedRoot)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: approvedTarget.path)
            if decision == .requireConfirmation {
                let size = (try? FileManager.default.allocatedSizeOfItem(at: target)) ?? 0
                let preview = ApprovalPreview(
                    title: "移动到 Cloud Code 回收站",
                    target: approvedTarget.path,
                    originalSummary: "\(size) 字节",
                    reason: call.arguments["reason"] ?? "Agent 请求删除",
                    plan: ["验证目标", "记录元数据快照", "移动到回收站", "验证原位置已移除", "写入日志"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let record = try await trashService.moveToTrash(
                target: target,
                logicalResourceID: call.arguments["logicalResourceId"] ?? "file://\(target.path)",
                sessionID: call.sessionID,
                toolCallID: call.id,
                reason: call.arguments["reason"] ?? "Agent 请求删除",
                sourceApp: call.arguments["sourceApp"],
                allowedRoot: context.allowedRoot,
                expectedResolvedTarget: approvedTarget,
                expectedSourceIdentity: approvedSourceIdentity
            )
            let payloadVerified = await trashService.verifyTrashed(record)
            let passed = !FileManager.default.fileExists(atPath: target.path) && payloadVerified
            let verification = VerificationResult(passed: passed, checks: ["原位置已移除", "回收站内容指纹与删除前快照一致"], failures: passed ? [] : ["回收站最终状态或内容指纹验证失败"])
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: target.path, risk: descriptor.risk, result: passed ? "trashed" : "verification_failed", detail: ["trashID": record.id.uuidString]))
            return try untrustedResult(call.id, summary: "已移动到 Cloud Code 回收站", key: "trashRecord", value: record, source: "files.delete", verification: verification)

        case "trash.restore":
            guard let raw = call.arguments["id"], let id = UUID(uuidString: raw) else { throw CocoaError(.fileNoSuchFile) }
            guard let existingRecord = (try await trashService.records()).first(where: { $0.id == id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let originalTarget = URL(fileURLWithPath: existingRecord.originalPath)
            let approvedTarget = try PathGuard().validate(target: originalTarget, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let approvedParentIdentity = try? secureFileMutation.parentIdentity(of: approvedTarget, allowedRoot: context.allowedRoot)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: approvedTarget.path)
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: "恢复回收站项目",
                    target: approvedTarget.path,
                    reason: "恢复会写回原始路径。",
                    plan: ["定位回收站记录", "验证原始路径", "确认后重新验证目标身份", "恢复文件", "验证恢复后的内容指纹"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let record = try await trashService.restore(
                id,
                allowedRoot: context.allowedRoot,
                expectedResolvedTarget: approvedTarget,
                expectedDestinationParentIdentity: approvedParentIdentity
            )
            let passed = await trashService.verifyRestored(record)
            return try untrustedResult(call.id, summary: "已恢复 \(record.filename)", key: "trashRecord", value: record, source: "trash.restore", verification: VerificationResult(passed: passed, checks: ["原路径存在", "恢复后的内容指纹与回收站记录一致"], failures: passed ? [] : ["恢复内容与回收站记录不一致"]))

        case "trash.purge":
            guard let raw = call.arguments["id"], let id = UUID(uuidString: raw) else { throw CocoaError(.fileNoSuchFile) }
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, explicitlyPermanent: true)
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(title: "永久删除回收站项目", target: raw, reason: "永久删除后无法恢复", plan: ["定位回收站记录", "删除回收站内容", "更新日志"], risk: .permanentDestructive)
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let beforeRecords = try await trashService.records()
            let before = beforeRecords.first(where: { $0.id == id })
            try await trashService.permanentlyDelete(id)
            let after = try await trashService.records()
            let journalGone = !after.contains(where: { $0.id == id })
            let payloadGone = before.map { !FileManager.default.fileExists(atPath: $0.trashPath) } ?? true
            let passed = journalGone && payloadGone
            let verification = VerificationResult(passed: passed, checks: ["回收站日志记录已移除", "回收站内容已移除"], failures: passed ? [] : ["永久删除最终状态验证失败"])
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: raw, risk: descriptor.risk, result: passed ? "permanently_deleted" : "verification_failed"))
            return ToolResult(toolCallID: call.id, success: passed, summary: passed ? "回收站项目已永久删除" : "回收站永久删除验证失败", verification: verification)

        case "ipa.locate":
            let root = try requiredURL(call, key: "path")
            let entries = try ipaService.locate(root: root, allowedRoot: context.allowedRoot, fileService: fileService)
            return try untrustedResult(call.id, summary: "找到 \(entries.count) 个 IPA 文件", key: "ipas", value: entries, source: "ipa.locate")

        case "ipa.inspect":
            let target = try requiredURL(call, key: "path")
            let inspection = try ipaService.inspect(target, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "已检查 IPA：\(inspection.bundleIdentifier ?? target.lastPathComponent)", key: "inspection", value: inspection, source: "ipa.inspect")

        case "ipa.extract":
            let target = try requiredURL(call, key: "path")
            let guardedSource = try PathGuard().validate(target: target, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let approvedSourceIdentity = try secureFileMutation.identity(of: guardedSource, allowedRoot: context.allowedRoot)
            guard let destinationRaw = call.arguments["destination"] else { throw ToolRouterError.noExecutionRoute("destination missing") }
            let destination = URL(fileURLWithPath: destinationRaw)
            let guardedDestination = try PathGuard().validate(target: destination, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let approvedDestinationParentIdentity = try? secureFileMutation.parentIdentity(of: guardedDestination, allowedRoot: context.allowedRoot)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: guardedDestination.path)
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: "解压 IPA",
                    target: guardedDestination.path,
                    reason: "解压会在目标目录创建文件。",
                    plan: ["验证 IPA 与目标目录", "确认后重新验证源和目标身份", "安全解压", "检查 Payload App 元数据"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let finalSource = try PathGuard().validate(target: target, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let finalDestination = try PathGuard().validate(target: destination, allowedRoot: context.allowedRoot, rejectSymlink: true)
            guard finalSource.path == guardedSource.path, finalDestination.path == guardedDestination.path else {
                throw PathSafetyError.targetChangedAfterApproval
            }
            try ipaService.extract(
                finalSource,
                to: finalDestination,
                allowedRoot: context.allowedRoot,
                expectedResolvedSource: guardedSource,
                expectedResolvedDestination: guardedDestination,
                expectedSourceIdentity: approvedSourceIdentity,
                expectedDestinationParentIdentity: approvedDestinationParentIdentity
            )
            let payload = finalDestination.appendingPathComponent("Payload", isDirectory: true)
            let appInfoFound = ((try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { $0.pathExtension == "app" }
                .contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Info.plist").path) }
            let passed = FileManager.default.fileExists(atPath: finalDestination.path) && appInfoFound
            let verification = VerificationResult(passed: passed, checks: ["解压目标存在", "Payload App 的 Info.plist 存在"], failures: passed ? [] : ["解压后的 IPA 内容不完整"])
            return ToolResult(toolCallID: call.id, success: passed, summary: "IPA 已解压", payload: ["destination": finalDestination.path], verification: verification)

        case "ipa.repack":
            let source = try requiredURL(call, key: "source")
            let destination = try requiredURL(call, key: "destination")
            let approvedSource = try PathGuard().validate(target: source, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let approvedSourceIdentity = try secureFileMutation.identity(of: approvedSource, allowedRoot: context.allowedRoot)
            let approvedDestination = try PathGuard().validate(target: destination, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let approvedDestinationParentIdentity = try? secureFileMutation.parentIdentity(of: approvedDestination, allowedRoot: context.allowedRoot)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: approvedDestination.path)
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: "重新打包 IPA",
                    target: approvedDestination.path,
                    originalSummary: nil,
                    reason: call.arguments["reason"] ?? "Agent 请求重新打包 IPA",
                    plan: ["验证源目录", "拒绝符号链接和路径穿越", "创建新 IPA", "重新打开并检查归档"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            try ipaService.repack(
                sourceRoot: source,
                to: destination,
                allowedRoot: context.allowedRoot,
                expectedResolvedSource: approvedSource,
                expectedResolvedDestination: approvedDestination,
                expectedSourceIdentity: approvedSourceIdentity,
                expectedDestinationParentIdentity: approvedDestinationParentIdentity
            )
            let inspection = try ipaService.inspect(approvedDestination, allowedRoot: context.allowedRoot)
            let verification = VerificationResult(
                passed: inspection.bundleIdentifier != nil,
                checks: ["重新打开生成的 IPA", "已解析 Payload App 的 Info.plist"],
                failures: inspection.bundleIdentifier == nil ? ["生成的 IPA 缺少 Bundle Identifier"] : []
            )
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: approvedDestination.path, risk: descriptor.risk, result: verification.passed ? "repacked" : "verification_failed"))
            return try untrustedResult(call.id, summary: "IPA 已重新打包", key: "inspection", value: inspection, source: "ipa.repack", verification: verification)

        default:
            throw ToolRouterError.noExecutionRoute(call.name)
        }
    }

    private func requiredURL(_ call: ToolCall, key: String) throws -> URL {
        guard let raw = call.arguments[key], !raw.isEmpty else { throw ToolRouterError.noExecutionRoute("\(key) missing") }
        return URL(fileURLWithPath: raw)
    }

    private func untrustedResult<T: Encodable>(_ id: UUID, summary: String, key: String, value: T, source: String, verification: VerificationResult? = nil) throws -> ToolResult {
        let encoded = try JSONEncoder.pretty.encode(value)
        let content = String(data: encoded, encoding: .utf8) ?? ""
        let envelope = ToolOutputEnvelope(trust: .untrustedData, source: source, content: content)
        return ToolResult(toolCallID: id, success: verification?.passed ?? true, summary: summary, payload: [key: envelope.promptSafeRepresentation], verification: verification)
    }
}
