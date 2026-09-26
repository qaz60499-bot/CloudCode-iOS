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
    private let plistService: NativePropertyListService
    private let jsonService: NativeJSONService
    private let sqliteService: NativeSQLiteService
    private let resourceIndex: ProgressiveResourceIndex?
    private let appKnowledgeRegistry: AppKnowledgeRegistry?

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
        secureFileMutation: SecureFileMutation = SecureFileMutation(),
        plistService: NativePropertyListService = NativePropertyListService(),
        jsonService: NativeJSONService = NativeJSONService(),
        sqliteService: NativeSQLiteService = NativeSQLiteService(),
        resourceIndex: ProgressiveResourceIndex? = nil,
        appKnowledgeRegistry: AppKnowledgeRegistry? = nil
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
        self.plistService = plistService
        self.jsonService = jsonService
        self.sqliteService = sqliteService
        self.resourceIndex = resourceIndex
        self.appKnowledgeRegistry = appKnowledgeRegistry
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        let supported: Set<String> = [
            "capability.probe", "apps.list", "apps.inspect", "container.resolve", "container.list", "container.search",
            "files.list", "files.search", "files.read", "files.inspectDocument", "files.stat", "files.metadata", "files.hash", "files.diff", "files.copy", "files.move",
            "plist.read", "plist.query", "plist.metadata",
            "json.read", "json.query", "json.filter", "json.aggregate",
            "sqlite.discover", "sqlite.tables", "sqlite.schema", "sqlite.query", "sqlite.filter", "sqlite.aggregate", "sqlite.sample",
            "data.localQuery", "storage.analyze", "files.create", "files.modify", "files.delete", "trash.restore", "trash.purge",
            "ipa.locate", "ipa.inspect", "ipa.extract", "ipa.repack"
        ]
        return supported.contains(tool.name)
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        switch call.name {
        case "capability.probe":
            // Model-driven tool calls must never initiate privileged/private probing. The
            // session context already contains the capability profile established by the app:
            // startup-safe by default, or privileged only after an explicit user validation.
            let profile = context.capabilityProfile
            var payload = Dictionary(profile.records.map { ($0.id, $0.status.rawValue) }, uniquingKeysWith: { _, latest in latest })
            payload["runtime_validation.apps.list"] = "bounded_isolated"
            payload["runtime_validation.apps.inspect"] = "bounded_isolated"
            payload["runtime_validation.container.resolve"] = "bounded_isolated"
            payload["runtime_validation.apps.launch"] = "bounded_isolated"
            return ToolResult(toolCallID: call.id, success: true, summary: "当前会话能力快照；部分 App 读取/启动工具会在执行时做有界隔离验证", payload: payload)

        case "apps.list":
            let apps = await appResolver.installedApps()
            var enumerationFreshness = "fresh"
            if let enumerationProvider = appResolver as? any AppEnumerationCapabilityProviding {
                guard await enumerationProvider.canUseInstalledAppIndex() else {
                    let detail = await enumerationProvider.installedAppEnumerationDetail()
                    return ToolResult(
                        toolCallID: call.id,
                        success: false,
                        summary: "跨 App 应用索引当前不可用；未将 Cloud Code 自身视为完整安装列表。",
                        payload: [
                            "enumeration": "unavailable",
                            "detail": String(detail.prefix(2_048)),
                            "ownAppFallbackSuppressed": "true"
                        ]
                    )
                }
                if !(await enumerationProvider.canEnumerateInstalledApps()) {
                    enumerationFreshness = "stale_last_known_good"
                }
            }
            let query = call.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let filtered: [ResourceNode]
            if query.isEmpty {
                filtered = apps
            } else {
                filtered = apps.filter { app in
                    app.displayName.localizedCaseInsensitiveContains(query)
                        || (app.ownerBundleID?.localizedCaseInsensitiveContains(query) ?? false)
                }
            }
            let offset = max(0, Int(call.arguments["offset"] ?? "0") ?? 0)
            let limit = min(50, max(1, Int(call.arguments["limit"] ?? "24") ?? 24))
            let boundedOffset = min(offset, filtered.count)
            let page = filtered.dropFirst(boundedOffset).prefix(limit)

            // A successful installed-App lookup is already enough evidence to establish the target's
            // stable identity. Persist a minimal AppKnowledge record for the returned page so a later
            // GUI/native step does not fall back to Cloud Code-only knowledge simply because the model
            // has not paid for apps.inspect yet. Static metadata/deep links remain lazy and are filled
            // by apps.inspect; this seed never trusts or persists container UUID paths.
            if let appKnowledgeRegistry {
                for app in page {
                    guard let bundleID = app.ownerBundleID, !bundleID.isEmpty else { continue }
                    if var existing = await appKnowledgeRegistry.knowledge(for: bundleID) {
                        var changed = false
                        if existing.appName != app.displayName {
                            existing.appName = app.displayName
                            changed = true
                        }
                        let version = app.metadata["version"]
                        if version?.isEmpty == false, existing.appVersion != version {
                            existing.appVersion = version
                            changed = true
                        }
                        if changed { try? await appKnowledgeRegistry.upsert(existing) }
                    } else {
                        let knowledge = AppKnowledge(
                            appName: app.displayName,
                            bundleID: bundleID,
                            preferredRoutes: [.structuredTool, .privateFramework, .guiFallback],
                            successRate: 0.5,
                            estimatedCost: 0.5,
                            appVersion: app.metadata["version"]
                        )
                        try? await appKnowledgeRegistry.upsert(knowledge)
                    }
                }
            }

            // apps.list is a discovery/index tool, not a container dump. Return a bounded page and
            // keep bundle/data paths behind apps.inspect/container.resolve. This prevents a device
            // with hundreds of apps from repeatedly injecting the entire inventory into the Agent
            // transcript while still allowing exact search by display name or bundle ID.
            let compactApps: [[String: String]] = page.map { app in
                var item: [String: String] = ["name": app.displayName]
                if let bundleID = app.ownerBundleID, !bundleID.isEmpty { item["bundleId"] = bundleID }
                if let version = app.metadata["version"], !version.isEmpty { item["version"] = version }
                return item
            }
            let encoded = try JSONEncoder.pretty.encode(compactApps)
            let content = String(data: encoded, encoding: .utf8) ?? "[]"
            let envelope = ToolOutputEnvelope(trust: .untrustedData, source: "apps.list", content: content)
            let hasMore = boundedOffset + compactApps.count < filtered.count
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: query.isEmpty
                    ? "App 索引共 \(apps.count) 项；返回 \(compactApps.count) 项"
                    : "App 索引共 \(apps.count) 项；“\(query)”匹配 \(filtered.count) 项，返回 \(compactApps.count) 项",
                payload: [
                    "apps": envelope.promptSafeRepresentation,
                    "totalCount": String(apps.count),
                    "matchedCount": String(filtered.count),
                    "offset": String(boundedOffset),
                    "limit": String(limit),
                    "hasMore": String(hasMore),
                    "enumeration": enumerationFreshness
                ]
            )

        case "apps.inspect":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            // Prefer the already-indexed identity before paying for another exact helper lookup.
            // This is especially important after a transient refresh failure: a retained
            // last-known-good entry still proves that the read-only target is known, even though
            // fresh enumeration authority is unavailable for destructive operations.
            let indexedApps = await appResolver.installedApps()
            let indexedNode = indexedApps.first(where: { $0.ownerBundleID == bundleID })
            let node: ResourceNode
            if let indexedNode, indexedNode.resolvedPath != nil {
                node = indexedNode
            } else {
                node = try await resourceResolver.resolve(ResourceID("app://\(bundleID)"))
            }
            let dataContainer = await appResolver.dataContainerPath(for: bundleID)
            var payload = node.metadata
            payload["bundleId"] = bundleID
            payload["displayName"] = node.displayName
            payload["bundlePath"] = node.resolvedPath ?? ""
            payload["dataContainer"] = dataContainer ?? ""

            if let provider = appResolver as? any AppIntrospectionProviding,
               let introspection = await provider.appIntrospection(bundleID: bundleID) {
                payload["build"] = introspection.build
                payload["executable"] = introspection.executable
                payload["urlSchemes"] = introspection.urlSchemes.joined(separator: ",")
                payload["documentTypes"] = introspection.documentTypes.joined(separator: ",")
                payload["utTypes"] = introspection.utTypes.joined(separator: ",")
                payload["extensions"] = introspection.extensions.joined(separator: ",")
                payload["frameworks"] = introspection.frameworks.joined(separator: ",")
                payload["appGroups"] = introspection.appGroups.joined(separator: ",")
                payload["introspection"] = "bounded_cached"

                var metadata: [String: String] = [
                    "build": introspection.build,
                    "executable": introspection.executable,
                    "documentTypes": introspection.documentTypes.joined(separator: ","),
                    "extensions": introspection.extensions.joined(separator: ","),
                    "frameworks": introspection.frameworks.joined(separator: ","),
                    "appGroups": introspection.appGroups.joined(separator: ",")
                ]
                metadata = metadata.filter { !$0.value.isEmpty }
                if let existing = await appKnowledgeRegistry?.knowledge(for: bundleID) {
                    var updated = existing
                    updated.appName = introspection.displayName
                    updated.appVersion = introspection.version
                    updated.supportedUTTypes = introspection.utTypes
                    updated.urlSchemes = introspection.urlSchemes
                    updated.introspectionMetadata = metadata
                    updated.localDataMap = introspection.localData
                    try? await appKnowledgeRegistry?.upsert(updated)
                } else if appKnowledgeRegistry != nil {
                    let knowledge = AppKnowledge(
                        appName: introspection.displayName,
                        bundleID: bundleID,
                        supportedUTTypes: introspection.utTypes,
                        urlSchemes: introspection.urlSchemes,
                        preferredRoutes: [.structuredTool, .privateFramework, .urlScheme, .guiFallback],
                        successRate: 0.5,
                        estimatedCost: 0.5,
                        appVersion: introspection.version,
                        introspectionMetadata: metadata,
                        localDataMap: introspection.localData
                    )
                    try? await appKnowledgeRegistry?.upsert(knowledge)
                }

                if let resourceIndex {
                    let localNodes = introspection.localData.map { alias, path in
                        ResourceNode(
                            id: ResourceID(URL(fileURLWithPath: path).absoluteString),
                            kind: .directory,
                            displayName: alias,
                            logicalLocation: "appdata://\(bundleID)/\(alias)",
                            resolvedPath: path,
                            ownerBundleID: bundleID,
                            metadata: ["semanticAlias": alias, "source": "app_introspection"]
                        )
                    }
                    if !localNodes.isEmpty { try? await resourceIndex.add(localNodes, source: "app_introspection") }
                }
            } else {
                // Metadata enrichment is optional for read-only inspection. Do not translate an
                // introspection helper timeout/unavailability into "App does not exist" when the
                // installed-App index already supplied a valid identity/path/version baseline.
                payload["introspection"] = "degraded_unavailable"
            }
            return try untrustedResult(call.id, summary: "已解析 \(bundleID) 并按需更新 AppKnowledge", key: "app", value: payload, source: "apps.inspect")

        case "container.resolve":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let node = try await resourceResolver.resolve(containerResourceID(bundleID: bundleID, relativePath: nil))
            try? await resourceIndex?.add(node)
            let payload = ["logical": node.logicalLocation, "path": node.resolvedPath ?? ""]
            return try untrustedResult(call.id, summary: "容器解析完成", key: "container", value: payload, source: "container.resolve")

        case "container.list":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let rootNode = try await resourceResolver.resolve(containerResourceID(bundleID: bundleID, relativePath: nil))
            let node = try await resourceResolver.resolve(containerResourceID(bundleID: bundleID, relativePath: call.arguments["relativePath"]))
            guard let rootPath = rootNode.resolvedPath, let resolvedPath = node.resolvedPath else { throw ToolRouterError.noExecutionRoute("container path unavailable") }
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let targetURL = URL(fileURLWithPath: resolvedPath, isDirectory: true)
            _ = try PathGuard().validate(target: targetURL, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let entries = try fileService.list(directory: targetURL, allowedRoot: rootURL)
            try? await resourceIndex?.add(rootNode)
            try? await resourceIndex?.add(node)
            try? await index(entries: entries, ownerBundleID: bundleID)
            scheduleContainerIndexWarmup(rootNode: rootNode, rootURL: rootURL, ownerBundleID: bundleID)
            return try untrustedResult(call.id, summary: "容器目录列出 \(entries.count) 项", key: "entries", value: entries, source: "container.list")

        case "container.search":
            guard let bundleID = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let rootNode = try await resourceResolver.resolve(containerResourceID(bundleID: bundleID, relativePath: nil))
            let node = try await resourceResolver.resolve(containerResourceID(bundleID: bundleID, relativePath: call.arguments["relativePath"]))
            guard let rootPath = rootNode.resolvedPath, let resolvedPath = node.resolvedPath else { throw ToolRouterError.noExecutionRoute("container path unavailable") }
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let targetURL = URL(fileURLWithPath: resolvedPath, isDirectory: true)
            _ = try PathGuard().validate(target: targetURL, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let query = makeFileSearchQuery(call, defaultMaxDepth: 6, defaultMaxResults: 200)
            try? await resourceIndex?.add(rootNode)
            try? await resourceIndex?.add(node)
            if let indexed = await revalidatedIndexedSearch(root: targetURL, query: query, ownerBundleID: bundleID, allowedRoot: rootURL), !indexed.isEmpty {
                scheduleContainerIndexWarmup(rootNode: rootNode, rootURL: rootURL, ownerBundleID: bundleID)
                var result = try untrustedResult(call.id, summary: "持久资源索引命中并重新验证 \(indexed.count) 项", key: "entries", value: indexed, source: "container.search.index")
                result.payload["searchPath"] = "persistent_index_revalidated"
                return result
            }
            let entries = try fileService.search(root: targetURL, query: query, allowedRoot: rootURL)
            try? await index(entries: entries, ownerBundleID: bundleID)
            scheduleContainerIndexWarmup(rootNode: rootNode, rootURL: rootURL, ownerBundleID: bundleID)
            var result = try untrustedResult(call.id, summary: "容器有界扫描找到 \(entries.count) 项并增量更新索引", key: "entries", value: entries, source: "container.search.scan")
            result.payload["searchPath"] = "bounded_scan_then_index"
            return result

        case "files.list":
            let url = try requiredURL(call, key: "path")
            let entries = try fileService.list(directory: url, allowedRoot: context.allowedRoot)
            try? await index(entries: entries, ownerBundleID: nil)
            return try untrustedResult(call.id, summary: "列出 \(entries.count) 个项目", key: "entries", value: entries, source: "files.list")

        case "files.search":
            let root = try requiredURL(call, key: "path")
            let query = makeFileSearchQuery(call, defaultMaxDepth: 6, defaultMaxResults: 500)
            _ = try fileService.stat(root, allowedRoot: context.allowedRoot)
            if let indexed = await revalidatedIndexedSearch(root: root, query: query, ownerBundleID: nil, allowedRoot: context.allowedRoot), !indexed.isEmpty {
                var result = try untrustedResult(call.id, summary: "持久资源索引命中并重新验证 \(indexed.count) 项", key: "entries", value: indexed, source: "files.search.index")
                result.payload["searchPath"] = "persistent_index_revalidated"
                return result
            }
            let entries = try fileService.search(root: root, query: query, allowedRoot: context.allowedRoot)
            try? await index(entries: entries, ownerBundleID: nil)
            var result = try untrustedResult(call.id, summary: "有界目录扫描找到 \(entries.count) 项并增量更新索引", key: "entries", value: entries, source: "files.search.scan")
            result.payload["searchPath"] = "bounded_scan_then_index"
            return result

        case "files.read":
            let url = try requiredURL(call, key: "path")
            let text = try fileService.readText(url, allowedRoot: context.allowedRoot)
            let envelope = ToolOutputEnvelope(trust: .untrustedData, source: url.path, content: text)
            return ToolResult(toolCallID: call.id, success: true, summary: "已读取 \(url.lastPathComponent)", payload: ["content": envelope.promptSafeRepresentation])

        case "files.inspectDocument":
            let url = try requiredURL(call, key: "path")
            let inspection = try DocumentInspectionService().inspect(url, allowedRoot: context.allowedRoot)
            return try untrustedResult(
                call.id,
                summary: "已在本机解析 \(url.lastPathComponent)（\(inspection.kind)）",
                key: "document",
                value: inspection,
                source: "files.inspectDocument"
            )

        case "files.stat", "files.metadata":
            let url = try requiredURL(call, key: "path")
            let metadata = try fileService.stat(url, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "已读取当前文件元数据", key: "metadata", value: metadata, source: call.name)

        case "files.hash":
            let url = try requiredURL(call, key: "path")
            let maxBytes = min(max(Int(call.arguments["maxBytes"] ?? "67108864") ?? 67_108_864, 1), 67_108_864)
            let hash = try fileService.sha256(url, allowedRoot: context.allowedRoot, maxBytes: maxBytes)
            return ToolResult(toolCallID: call.id, success: true, summary: "SHA-256 计算完成", payload: ["path": url.standardizedFileURL.path, "sha256": hash])

        case "files.diff":
            let left = try requiredURL(call, key: "leftPath")
            let right = try requiredURL(call, key: "rightPath")
            let diff = try fileService.diffText(left, right, allowedRoot: context.allowedRoot, maxBytesPerFile: min(max(Int(call.arguments["maxBytesPerFile"] ?? "1000000") ?? 1_000_000, 1), 2_000_000))
            return try untrustedResult(call.id, summary: diff.identical ? "文本内容一致" : "文本差异已计算", key: "diff", value: diff, source: "files.diff")

        case "files.copy", "files.move":
            let source = try requiredURL(call, key: "source")
            let destination = try requiredURL(call, key: "destination")
            if call.name == "files.move", PathGuard.isSystemManagedApplicationContainerTarget(source.standardizedFileURL.resolvingSymlinksInPath()) {
                throw PathSafetyError.systemManagedApplicationContainer
            }
            let guardedSource = try PathGuard().validate(target: source, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let guardedDestination = try PathGuard().validate(target: destination, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let sourceIdentity = try secureFileMutation.identity(of: guardedSource, allowedRoot: context.allowedRoot)
            let destinationParentIdentity = try? secureFileMutation.parentIdentity(of: guardedDestination, allowedRoot: context.allowedRoot)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: guardedDestination.path)
            if decision == .deny { throw TransactionError.confirmationDenied }
            if decision == .requireConfirmation {
                let title = call.name == "files.copy" ? "复制文件" : "移动文件"
                let preview = ApprovalPreview(
                    title: title,
                    target: guardedDestination.path,
                    originalSummary: guardedSource.path,
                    reason: call.arguments["reason"] ?? "Agent 请求\(title)",
                    plan: ["重新验证源路径身份", "重新验证目标父目录身份", title, "验证最终状态", "写入审计日志"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let finalSource = try PathGuard().validate(target: source, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let finalDestination = try PathGuard().validate(target: destination, allowedRoot: context.allowedRoot, rejectSymlink: true)
            guard finalSource.path == guardedSource.path, finalDestination.path == guardedDestination.path else {
                throw PathSafetyError.targetChangedAfterApproval
            }
            if call.name == "files.copy" {
                try secureFileMutation.copyFile(
                    from: finalSource,
                    sourceAllowedRoot: context.allowedRoot,
                    to: finalDestination,
                    destinationAllowedRoot: context.allowedRoot,
                    createDestinationIntermediates: true,
                    expectedSourceIdentity: sourceIdentity,
                    expectedDestinationParentIdentity: destinationParentIdentity
                )
            } else {
                try secureFileMutation.moveItem(
                    from: finalSource,
                    sourceAllowedRoot: context.allowedRoot,
                    to: finalDestination,
                    destinationAllowedRoot: context.allowedRoot,
                    createDestinationIntermediates: true,
                    expectedSourceIdentity: sourceIdentity,
                    expectedDestinationParentIdentity: destinationParentIdentity
                )
            }
            let sourceExists = FileManager.default.fileExists(atPath: finalSource.path)
            let destinationExists = FileManager.default.fileExists(atPath: finalDestination.path)
            let passed = destinationExists && (call.name == "files.copy" ? sourceExists : !sourceExists)
            let verification = VerificationResult(
                passed: passed,
                checks: call.name == "files.copy"
                    ? ["descriptor-pinned source/destination", "copied bytes re-read through file descriptors", "source and destination exist"]
                    : ["descriptor-pinned source/destination", "exclusive rename identity verified", "source removed and destination exists"],
                failures: passed ? [] : ["最终文件状态不符合预期"]
            )
            try await audit.append(AuditEvent(sessionID: call.sessionID, toolCallID: call.id, action: call.name, target: finalDestination.path, risk: descriptor.risk, result: passed ? "completed" : "verification_failed", detail: ["source": finalSource.path]))
            if passed {
                if call.name == "files.move" {
                    try? await resourceIndex?.remove([ResourceID(finalSource.absoluteString)])
                }
                if let metadata = try? fileService.stat(finalDestination, allowedRoot: context.allowedRoot) {
                    try? await index(metadata: metadata, ownerBundleID: nil)
                }
            }
            return ToolResult(toolCallID: call.id, success: passed, summary: passed ? "\(call.name == "files.copy" ? "复制" : "移动")完成" : "最终状态验证失败", payload: ["source": finalSource.path, "destination": finalDestination.path], verification: verification)

        case "plist.read":
            let path = try requiredURL(call, key: "path")
            return try untrustedAnyResult(call.id, summary: "plist 已读取", key: "value", value: plistService.read(path: path, allowedRoot: context.allowedRoot), source: "plist.read")

        case "plist.query":
            let path = try requiredURL(call, key: "path")
            let keyPath = call.arguments["keyPath"] ?? "$"
            return try untrustedAnyResult(call.id, summary: "plist 查询完成", key: "value", value: plistService.query(path: path, keyPath: keyPath, allowedRoot: context.allowedRoot), source: "plist.query")

        case "plist.metadata":
            let path = try requiredURL(call, key: "path")
            let metadata = try plistService.metadata(path: path, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "plist 元数据读取完成", key: "metadata", value: metadata, source: "plist.metadata")

        case "json.read":
            let path = try requiredURL(call, key: "path")
            return try untrustedAnyResult(call.id, summary: "JSON 已读取", key: "value", value: jsonService.read(path: path, allowedRoot: context.allowedRoot), source: "json.read")

        case "json.query":
            let path = try requiredURL(call, key: "path")
            return try untrustedAnyResult(call.id, summary: "JSON 查询完成", key: "value", value: jsonService.query(path: path, keyPath: call.arguments["keyPath"] ?? "$", allowedRoot: context.allowedRoot), source: "json.query")

        case "json.filter":
            let path = try requiredURL(call, key: "path")
            guard let field = call.arguments["field"], let equals = call.arguments["equals"] else { throw ToolRouterError.noExecutionRoute("field/equals missing") }
            let value = try jsonService.filter(path: path, keyPath: call.arguments["keyPath"] ?? "$", field: field, equals: equals, limit: Int(call.arguments["limit"] ?? "100") ?? 100, allowedRoot: context.allowedRoot)
            return try untrustedAnyResult(call.id, summary: "JSON 过滤完成", key: "value", value: value, source: "json.filter")

        case "json.aggregate":
            let path = try requiredURL(call, key: "path")
            guard let operation = call.arguments["operation"] else { throw ToolRouterError.noExecutionRoute("operation missing") }
            let value = try jsonService.aggregate(path: path, keyPath: call.arguments["keyPath"] ?? "$", field: call.arguments["field"], operation: operation, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "JSON 聚合完成", key: "aggregate", value: value, source: "json.aggregate")

        case "sqlite.discover":
            let root = try requiredURL(call, key: "path")
            var query = makeFileSearchQuery(call, defaultMaxDepth: 8, defaultMaxResults: 200)
            query.extensions = ["sqlite", "sqlite3", "db"]
            let entries = try fileService.search(root: root, query: query, allowedRoot: context.allowedRoot).filter { !$0.isDirectory }
            try? await index(entries: entries, ownerBundleID: nil)
            return try untrustedResult(call.id, summary: "发现 \(entries.count) 个 SQLite 候选", key: "entries", value: entries, source: "sqlite.discover")

        case "sqlite.tables":
            let path = try requiredURL(call, key: "path")
            return try untrustedResult(call.id, summary: "SQLite 表/视图读取完成", key: "result", value: sqliteService.tables(path: path, allowedRoot: context.allowedRoot), source: "sqlite.tables")

        case "sqlite.schema":
            let path = try requiredURL(call, key: "path")
            return try untrustedResult(call.id, summary: "SQLite schema 读取完成", key: "result", value: sqliteService.schema(path: path, table: call.arguments["table"], allowedRoot: context.allowedRoot), source: "sqlite.schema")

        case "sqlite.query":
            let path = try requiredURL(call, key: "path")
            guard let sql = call.arguments["sql"] else { throw ToolRouterError.noExecutionRoute("sql missing") }
            let result = try sqliteService.query(path: path, sql: sql, parametersJSON: call.arguments["params"], rowLimit: Int(call.arguments["rowLimit"] ?? "200") ?? 200, timeoutMS: Int(call.arguments["timeoutMs"] ?? "2000") ?? 2_000, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "SQLite 只读查询完成", key: "result", value: result, source: "sqlite.query")

        case "sqlite.filter":
            let path = try requiredURL(call, key: "path")
            guard let table = call.arguments["table"], let field = call.arguments["field"], let equals = call.arguments["equals"] else { throw ToolRouterError.noExecutionRoute("table/field/equals missing") }
            let result = try sqliteService.filter(path: path, table: table, field: field, equals: equals, limit: Int(call.arguments["limit"] ?? "100") ?? 100, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "SQLite 过滤完成", key: "result", value: result, source: "sqlite.filter")

        case "sqlite.aggregate":
            let path = try requiredURL(call, key: "path")
            guard let table = call.arguments["table"], let operation = call.arguments["operation"] else { throw ToolRouterError.noExecutionRoute("table/operation missing") }
            let result = try sqliteService.aggregate(path: path, table: table, field: call.arguments["field"], operation: operation, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "SQLite 聚合完成", key: "result", value: result, source: "sqlite.aggregate")

        case "sqlite.sample":
            let path = try requiredURL(call, key: "path")
            guard let table = call.arguments["table"] else { throw ToolRouterError.noExecutionRoute("table missing") }
            let result = try sqliteService.sample(path: path, table: table, limit: Int(call.arguments["limit"] ?? "20") ?? 20, allowedRoot: context.allowedRoot)
            return try untrustedResult(call.id, summary: "SQLite sample 完成", key: "result", value: result, source: "sqlite.sample")

        case "data.localQuery":
            return try await executeBoundedDataMacro(call, context: context)

        case "storage.analyze":
            let root = try requiredURL(call, key: "path")
            let entries = try fileService.analyzeStorage(root: root, allowedRoot: context.allowedRoot, top: Int(call.arguments["top"] ?? "50") ?? 50)
            return try untrustedResult(call.id, summary: "存储分析完成", key: "largestFiles", value: entries, source: "storage.analyze")

        case "files.create":
            let target = try requiredURL(call, key: "path")
            let guarded = try PathGuard().validate(target: target, allowedRoot: context.allowedRoot, rejectSymlink: true)
            let approvedParentIdentity = try? secureFileMutation.parentIdentity(of: guarded, allowedRoot: context.allowedRoot)
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: guarded.path)
            if decision == .deny { throw TransactionError.confirmationDenied }
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
            if verification.passed, let metadata = try? fileService.stat(finalTarget, allowedRoot: context.allowedRoot) {
                try? await index(metadata: metadata, ownerBundleID: nil)
            }
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
            if FileManager.default.fileExists(atPath: target.path), let metadata = try? fileService.stat(target, allowedRoot: context.allowedRoot) {
                try? await index(metadata: metadata, ownerBundleID: nil)
            }
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
            if decision == .deny { throw TransactionError.confirmationDenied }
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
            if passed { try? await resourceIndex?.remove([ResourceID(target.absoluteString)]) }
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
            if decision == .deny { throw TransactionError.confirmationDenied }
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
            if passed, let metadata = try? fileService.stat(originalTarget, allowedRoot: context.allowedRoot) {
                try? await index(metadata: metadata, ownerBundleID: nil)
            }
            return try untrustedResult(call.id, summary: "已恢复 \(record.filename)", key: "trashRecord", value: record, source: "trash.restore", verification: VerificationResult(passed: passed, checks: ["原路径存在", "恢复后的内容指纹与回收站记录一致"], failures: passed ? [] : ["恢复内容与回收站记录不一致"]))

        case "trash.purge":
            guard let raw = call.arguments["id"], let id = UUID(uuidString: raw) else { throw CocoaError(.fileNoSuchFile) }
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, explicitlyPermanent: true)
            if decision == .deny { throw TransactionError.confirmationDenied }
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
            if decision == .deny { throw TransactionError.confirmationDenied }
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
            if decision == .deny { throw TransactionError.confirmationDenied }
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

    private func makeFileSearchQuery(_ call: ToolCall, defaultMaxDepth: Int, defaultMaxResults: Int) -> FileSearchQuery {
        let extensions = Set((call.arguments["extension"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        return FileSearchQuery(
            nameContains: call.arguments["query"],
            extensions: extensions,
            modifiedAfter: call.arguments["modifiedAfter"].flatMap(parseISO8601),
            modifiedBefore: call.arguments["modifiedBefore"].flatMap(parseISO8601),
            maxDepth: min(max(Int(call.arguments["maxDepth"] ?? String(defaultMaxDepth)) ?? defaultMaxDepth, 0), 16),
            maxResults: min(max(Int(call.arguments["maxResults"] ?? String(defaultMaxResults)) ?? defaultMaxResults, 1), 2_000)
        )
    }

    private func parseISO8601(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func semanticLocalDataRelativePath(_ alias: String) -> String? {
        switch alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "preferences": return "Library/Preferences"
        case "applicationsupport", "application_support": return "Library/Application Support"
        case "documents": return "Documents"
        case "cache", "caches": return "Library/Caches"
        default: return nil
        }
    }

    private func containerResourceID(bundleID: String, relativePath: String?) -> ResourceID {
        var components = URLComponents()
        components.scheme = "container"
        components.host = bundleID
        if let relativePath {
            let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty { components.path = "/" + trimmed }
        }
        return ResourceID(components.string ?? "container://\(bundleID)")
    }

    private func revalidatedIndexedSearch(
        root: URL,
        query: FileSearchQuery,
        ownerBundleID: String?,
        allowedRoot: URL?
    ) async -> [FileEntry]? {
        guard let resourceIndex,
              let rawNeedle = query.nameContains?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawNeedle.isEmpty else { return nil }
        let rootPath = root.standardizedFileURL.path
        let indexed = await resourceIndex.search(
            nameContains: rawNeedle,
            extensions: query.extensions,
            ownerBundleID: ownerBundleID,
            pathPrefix: rootPath,
            maxResults: query.maxResults
        )
        guard !indexed.isEmpty else { return [] }

        let baseDepth = root.standardizedFileURL.pathComponents.count
        var valid: [FileEntry] = []
        var staleIDs: Set<ResourceID> = []
        for node in indexed {
            guard valid.count < query.maxResults, let rawPath = node.resolvedPath else { continue }
            let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
            let depth = candidate.pathComponents.count - baseDepth
            guard depth >= 0, depth <= query.maxDepth else { continue }
            do {
                let metadata = try fileService.stat(candidate, allowedRoot: allowedRoot)
                if let modifiedAfter = query.modifiedAfter {
                    guard let modified = metadata.modificationDate, modified >= modifiedAfter else { continue }
                }
                if let modifiedBefore = query.modifiedBefore {
                    guard let modified = metadata.modificationDate, modified <= modifiedBefore else { continue }
                }
                valid.append(FileEntry(
                    path: metadata.path,
                    name: metadata.name,
                    isDirectory: metadata.isDirectory,
                    size: metadata.size,
                    modificationDate: metadata.modificationDate
                ))
                await resourceIndex.markValidated(node.id, path: metadata.path, byteSize: metadata.size, modificationDate: metadata.modificationDate)
            } catch {
                staleIDs.insert(node.id)
            }
        }
        if !staleIDs.isEmpty { try? await resourceIndex.remove(staleIDs) }
        return valid
    }

    private func scheduleContainerIndexWarmup(rootNode: ResourceNode, rootURL: URL, ownerBundleID: String) {
        guard let resourceIndex else { return }
        let fileService = self.fileService
        Task(priority: .utility) {
            guard await resourceIndex.beginDeepIndex(rootNode.id) else { return }
            do {
                let limit = 8_000
                let entries = try fileService.search(
                    root: rootURL,
                    query: FileSearchQuery(maxDepth: 8, maxResults: limit),
                    allowedRoot: rootURL
                )
                let nodes = entries.map { entry -> ResourceNode in
                    let id = ResourceID(URL(fileURLWithPath: entry.path).absoluteString)
                    var metadata: [String: String] = [:]
                    if let date = entry.modificationDate { metadata["modifiedAt"] = ISO8601DateFormatter().string(from: date) }
                    return ResourceNode(
                        id: id,
                        kind: entry.isDirectory ? .directory : .file,
                        displayName: entry.name,
                        logicalLocation: id.rawValue,
                        resolvedPath: entry.path,
                        ownerBundleID: ownerBundleID,
                        byteSize: entry.size,
                        metadata: metadata
                    )
                }
                if !nodes.isEmpty { try await resourceIndex.add(nodes, source: "bounded_warmup") }
                try await resourceIndex.finishDeepIndex(rootNode.id, complete: entries.count < limit)
            } catch {
                try? await resourceIndex.finishDeepIndex(rootNode.id, complete: false)
            }
        }
    }

    private func index(entries: [FileEntry], ownerBundleID: String?) async throws {
        guard let resourceIndex, !entries.isEmpty else { return }
        let nodes = entries.map { entry -> ResourceNode in
            let id = ResourceID(URL(fileURLWithPath: entry.path).absoluteString)
            var metadata: [String: String] = [:]
            if let date = entry.modificationDate { metadata["modifiedAt"] = ISO8601DateFormatter().string(from: date) }
            return ResourceNode(
                id: id,
                kind: entry.isDirectory ? .directory : .file,
                displayName: entry.name,
                logicalLocation: id.rawValue,
                resolvedPath: entry.path,
                ownerBundleID: ownerBundleID,
                byteSize: entry.size,
                metadata: metadata
            )
        }
        try await resourceIndex.add(nodes)
    }

    private func index(metadata: FileMetadataSnapshot, ownerBundleID: String?) async throws {
        guard let resourceIndex else { return }
        let id = ResourceID(URL(fileURLWithPath: metadata.path).absoluteString)
        var indexMetadata: [String: String] = ["contentType": metadata.contentType ?? ""]
        if let modificationDate = metadata.modificationDate {
            indexMetadata["modifiedAt"] = ISO8601DateFormatter().string(from: modificationDate)
        }
        let node = ResourceNode(
            id: id,
            kind: metadata.isDirectory ? .directory : .file,
            displayName: metadata.name,
            logicalLocation: id.rawValue,
            resolvedPath: metadata.path,
            ownerBundleID: ownerBundleID,
            byteSize: metadata.size,
            metadata: indexMetadata
        )
        try await resourceIndex.add(node)
    }

    private func executeBoundedDataMacro(_ call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        var stages: [String] = []
        var ownerBundleID: String?
        var executionAllowedRoot = context.allowedRoot
        let target: URL
        if let bundleID = call.arguments["bundleId"], !bundleID.isEmpty {
            ownerBundleID = bundleID
            let rootNode = try await resourceResolver.resolve(containerResourceID(bundleID: bundleID, relativePath: nil))
            let resolvedRelativePath: String?
            if let semanticAlias = call.arguments["semanticAlias"]?.trimmingCharacters(in: .whitespacesAndNewlines), !semanticAlias.isEmpty {
                guard call.arguments["relativePath"] == nil else {
                    throw ToolRouterError.noExecutionRoute("data.localQuery accepts semanticAlias or relativePath, not both")
                }
                guard let knowledge = await appKnowledgeRegistry?.knowledge(for: bundleID),
                      knowledge.localDataMap?[semanticAlias] != nil,
                      let relative = Self.semanticLocalDataRelativePath(semanticAlias) else {
                    throw ToolRouterError.noExecutionRoute("semantic local-data alias is unknown or stale; run apps.inspect to refresh AppKnowledge first")
                }
                resolvedRelativePath = relative
                stages.append("lookup:semantic_alias")
            } else {
                resolvedRelativePath = call.arguments["relativePath"]
            }
            let node = try await resourceResolver.resolve(containerResourceID(bundleID: bundleID, relativePath: resolvedRelativePath))
            guard let rootPath = rootNode.resolvedPath, let resolvedPath = node.resolvedPath else { throw ToolRouterError.noExecutionRoute("container path unavailable") }
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            target = URL(fileURLWithPath: resolvedPath)
            _ = try PathGuard().validate(target: target, allowedRoot: context.allowedRoot, rejectSymlink: true)
            executionAllowedRoot = rootURL
            try? await resourceIndex?.add(rootNode)
            try? await resourceIndex?.add(node)
            stages.append(call.arguments["semanticAlias"] == nil ? "resolve:container" : "resolve:container_revalidated_alias")
        } else {
            target = try requiredURL(call, key: "path")
            stages.append("resolve:path")
        }

        var selected = target
        var metadata = try fileService.stat(selected, allowedRoot: executionAllowedRoot)
        if metadata.isDirectory {
            let requestedFormat = (call.arguments["format"] ?? "auto").lowercased()
            let extensions: Set<String>
            switch requestedFormat {
            case "plist": extensions = ["plist"]
            case "json": extensions = ["json"]
            case "sqlite": extensions = ["sqlite", "sqlite3", "db"]
            default: extensions = ["plist", "json", "sqlite", "sqlite3", "db"]
            }
            let query = FileSearchQuery(
                nameContains: call.arguments["query"],
                extensions: extensions,
                maxDepth: min(max(Int(call.arguments["maxDepth"] ?? "6") ?? 6, 0), 8),
                maxResults: 32
            )
            let candidates = try fileService.search(root: selected, query: query, allowedRoot: executionAllowedRoot).filter { !$0.isDirectory }
            try? await index(entries: candidates, ownerBundleID: ownerBundleID)
            guard candidates.count == 1, let candidate = candidates.first else {
                throw ToolRouterError.noExecutionRoute("bounded data macro requires one unique data file candidate; matched \(candidates.count)")
            }
            selected = URL(fileURLWithPath: candidate.path)
            metadata = try fileService.stat(selected, allowedRoot: executionAllowedRoot)
            stages.append("search:unique")
        }
        try? await index(metadata: metadata, ownerBundleID: ownerBundleID)
        stages.append("inspect:metadata")

        let requestedFormat = (call.arguments["format"] ?? "auto").lowercased()
        let detectedFormat: String
        if requestedFormat != "auto" {
            detectedFormat = requestedFormat
        } else {
            switch selected.pathExtension.lowercased() {
            case "plist": detectedFormat = "plist"
            case "json": detectedFormat = "json"
            case "sqlite", "sqlite3", "db": detectedFormat = "sqlite"
            default: throw ToolRouterError.noExecutionRoute("unable to infer local data format")
            }
        }

        let result: Any
        switch detectedFormat {
        case "plist":
            if (call.arguments["mode"] ?? "") == "metadata" {
                result = try plistService.metadata(path: selected, allowedRoot: executionAllowedRoot)
                stages.append("query:plist.metadata")
            } else if let keyPath = call.arguments["keyPath"] {
                result = try plistService.query(path: selected, keyPath: keyPath, allowedRoot: executionAllowedRoot)
                stages.append("query:plist")
            } else {
                result = try plistService.read(path: selected, allowedRoot: executionAllowedRoot)
                stages.append("query:plist.read")
            }
        case "json":
            if let operation = call.arguments["operation"] {
                result = try jsonService.aggregate(path: selected, keyPath: call.arguments["keyPath"] ?? "$", field: call.arguments["field"], operation: operation, allowedRoot: executionAllowedRoot)
                stages.append("aggregate:json")
            } else if let field = call.arguments["field"], let equals = call.arguments["equals"] {
                result = try jsonService.filter(path: selected, keyPath: call.arguments["keyPath"] ?? "$", field: field, equals: equals, limit: Int(call.arguments["limit"] ?? "100") ?? 100, allowedRoot: executionAllowedRoot)
                stages.append("filter:json")
            } else if let keyPath = call.arguments["keyPath"] {
                result = try jsonService.query(path: selected, keyPath: keyPath, allowedRoot: executionAllowedRoot)
                stages.append("query:json")
            } else {
                result = try jsonService.read(path: selected, allowedRoot: executionAllowedRoot)
                stages.append("query:json.read")
            }
        case "sqlite":
            let sqliteResult: NativeSQLiteQueryResult
            if let sql = call.arguments["sql"] {
                sqliteResult = try sqliteService.query(path: selected, sql: sql, parametersJSON: call.arguments["params"], rowLimit: Int(call.arguments["rowLimit"] ?? "200") ?? 200, timeoutMS: Int(call.arguments["timeoutMs"] ?? "2000") ?? 2_000, allowedRoot: executionAllowedRoot)
                stages.append("query:sqlite")
            } else if let operation = call.arguments["operation"], let table = call.arguments["table"] {
                sqliteResult = try sqliteService.aggregate(path: selected, table: table, field: call.arguments["field"], operation: operation, allowedRoot: executionAllowedRoot)
                stages.append("aggregate:sqlite")
            } else if let table = call.arguments["table"], let field = call.arguments["field"], let equals = call.arguments["equals"] {
                sqliteResult = try sqliteService.filter(path: selected, table: table, field: field, equals: equals, limit: Int(call.arguments["limit"] ?? "100") ?? 100, allowedRoot: executionAllowedRoot)
                stages.append("filter:sqlite")
            } else if let table = call.arguments["table"] {
                sqliteResult = try sqliteService.sample(path: selected, table: table, limit: Int(call.arguments["limit"] ?? "20") ?? 20, allowedRoot: executionAllowedRoot)
                stages.append("sample:sqlite")
            } else {
                sqliteResult = try sqliteService.tables(path: selected, allowedRoot: executionAllowedRoot)
                stages.append("inspect:sqlite.tables")
            }
            result = try encodableJSONObject(sqliteResult)
        default:
            throw ToolRouterError.noExecutionRoute("unsupported local data format \(detectedFormat)")
        }

        let payload: [String: Any] = [
            "path": selected.path,
            "format": detectedFormat,
            "stages": stages,
            "metadata": [
                "size": metadata.size,
                "contentType": metadata.contentType ?? "",
                "modifiedAt": metadata.modificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ],
            "result": NativeStructuredValue.jsonCompatible(result)
        ]
        return try untrustedAnyResult(call.id, summary: "本地 bounded data macro 完成：\(stages.joined(separator: "→"))", key: "macro", value: payload, source: "data.localQuery")
    }

    private func encodableJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder.pretty.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func untrustedAnyResult(_ id: UUID, summary: String, key: String, value: Any, source: String) throws -> ToolResult {
        let object = NativeStructuredValue.jsonCompatible(value)
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
        let content: String
        if encoded.count <= 512 * 1024 {
            content = String(data: encoded, encoding: .utf8) ?? "null"
        } else {
            let preview = String(decoding: encoded.prefix(256 * 1024), as: UTF8.self)
            let bounded = try JSONSerialization.data(withJSONObject: [
                "truncated": true,
                "byteCount": encoded.count,
                "preview": preview
            ], options: [.sortedKeys])
            content = String(data: bounded, encoding: .utf8) ?? "{\"truncated\":true}"
        }
        let envelope = ToolOutputEnvelope(trust: .untrustedData, source: source, content: content)
        return ToolResult(toolCallID: id, success: true, summary: summary, payload: [key: envelope.promptSafeRepresentation])
    }

    private func untrustedResult<T: Encodable>(_ id: UUID, summary: String, key: String, value: T, source: String, verification: VerificationResult? = nil) throws -> ToolResult {
        let encoded = try JSONEncoder.pretty.encode(value)
        let content = String(data: encoded, encoding: .utf8) ?? ""
        let envelope = ToolOutputEnvelope(trust: .untrustedData, source: source, content: content)
        return ToolResult(toolCallID: id, success: verification?.passed ?? true, summary: summary, payload: [key: envelope.promptSafeRepresentation], verification: verification)
    }
}
