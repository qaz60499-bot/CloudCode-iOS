import Foundation
import SwiftUI
import CloudCodeCore

@MainActor
public final class CloudCodeViewModel: ObservableObject {
    @Published public var session: AgentSession
    @Published public private(set) var streamingAssistantMessageID: UUID?
    @Published public var activityLines: [String] = []
    @Published public var capabilities = CapabilityProfile(records: [])
    @Published public var capabilityGraph = CapabilityGraph()
    @Published public var apps: [ResourceNode] = []
    @Published public var files: [FileEntry] = []
    @Published public var trash: [TrashRecord] = []
    @Published public var auditEvents: [AuditEvent] = []
    @Published public var interruptedTasks: [TaskCheckpoint] = []
    @Published public private(set) var sessionHistory: [AgentSession] = []
    @Published public var isRunning = false
    @Published public private(set) var isRefreshingCapabilities = false
    @Published public private(set) var capabilityRefreshMessage: String?
    @Published public private(set) var lastCapabilityRefreshAt: Date?
    @Published public var lastError: String?
    @Published public private(set) var inFlightOperationKeys: Set<String> = []

    @Published public private(set) var providerProfiles: [ProviderProfile]
    @Published public var selectedProviderID: String
    @Published public var selectedKeySlotID: String
    @Published public var selectedModel: String
    @Published public var permissionMode: PermissionMode
    @Published public var browsePath: String

    public let approvalCenter: ApprovalCenter

    private let appResolver: IOSAppResolver
    private let capabilityProbe: CapabilityProbe
    private let toolRegistry: ToolRegistry
    private let fileService: FileService
    private let trashService: TrashService
    private let auditStore: AuditLogStore
    private let transactionJournal: TransactionJournal
    private let transactionEngine: TransactionEngine
    private let checkpointStore: TaskCheckpointStore
    private let sessionStore: SessionStore
    private let attachmentStore: ChatAttachmentStore
    private let keyVault: KeychainAPIKeyVault
    private let agentCore: AgentCore
    private let resourceIndex: ProgressiveResourceIndex
    private let appKnowledge: AppKnowledgeRegistry
    private let customProviderFileURL: URL
    private var currentTask: Task<Void, Never>?
    private var runGeneration = RunGenerationGuard()
    private var bootstrapTask: Task<Void, Never>?
    private var capabilityRefreshTask: Task<Void, Never>?
    private var didBootstrap = false
    private static let providerKeyMutationOperationKey = "provider-key:mutation"

    public init() {
        let support = Self.supportRoot()
        let approval = ApprovalCenter()
        let resolver = IOSAppResolver()
        let probe = CapabilityProbe(appResolver: resolver)
        let resourceResolver = ResourceResolver(appResolver: resolver)
        let fileService = FileService()
        let policy = PolicyEngine()
        let audit = AuditLogStore(fileURL: support.appendingPathComponent("Audit/audit.jsonl"))
        let trash = TrashService(root: support.appendingPathComponent("Trash", isDirectory: true))
        let transactionJournal = TransactionJournal(fileURL: support.appendingPathComponent("Transactions/transactions.json"))
        let transactionEngine = TransactionEngine(
            backupRoot: support.appendingPathComponent("Backups", isDirectory: true),
            policy: policy,
            journal: transactionJournal,
            audit: audit
        )
        let structured = StructuredToolExecutor(
            capabilityProbe: probe,
            appResolver: resolver,
            resourceResolver: resourceResolver,
            fileService: fileService,
            ipaService: IPAService(),
            trashService: trash,
            transactionEngine: transactionEngine,
            policy: policy,
            audit: audit,
            approval: approval
        )
        let registry = ToolRegistry()
        let cli = IOSSystemExecutor(policy: policy, approval: approval)
        let privateApps = IOSPrivateAppExecutor(appResolver: resolver, policy: policy, approval: approval, audit: audit)
        let gui = GUIFallbackExecutor(backend: UnavailableGUIBackend())
        let executionLedger = ToolExecutionLedger(fileURL: support.appendingPathComponent("Execution/tool-results.json"))
        let router = ToolRouter(registry: registry, executors: [structured, cli, privateApps, URLSchemeExecutor(), gui], executionLedger: executionLedger)
        let keyVault = KeychainAPIKeyVault()
        let sessions = SessionStore(root: support.appendingPathComponent("Sessions", isDirectory: true))
        let attachments = ChatAttachmentStore(root: support.appendingPathComponent("Attachments", isDirectory: true))
        let checkpoints = TaskCheckpointStore(fileURL: support.appendingPathComponent("Tasks/checkpoints.json"))
        let provider = ProviderClientRouter(keyVault: keyVault)
        let agent = AgentCore(
            provider: provider,
            keyVault: keyVault,
            toolRouter: router,
            registry: registry,
            capabilityProbe: probe,
            sessionStore: sessions,
            checkpointStore: checkpoints
        )

        let defaults = UserDefaults.standard
        let initialPermissionMode = PermissionMode(rawValue: defaults.string(forKey: "permission.mode") ?? "safe") ?? .safe
        let customProviderFileURL = support.appendingPathComponent("Provider/custom-providers.json")
        let customProfiles = Self.loadCustomProviders(from: customProviderFileURL)
        let allProfiles = ProviderCatalog.desktopSnapshot + customProfiles
        let storedSelection = ProviderSelectionState(
            providerID: defaults.string(forKey: "provider.selected.id") ?? "",
            keySlotID: defaults.string(forKey: "provider.selected.keySlot") ?? "",
            model: defaults.string(forKey: "provider.selected.model") ?? ""
        )
        let selection = ProviderSelectionResolver.reconcile(storedSelection, profiles: allProfiles)
        self.providerProfiles = allProfiles
        self.selectedProviderID = selection.providerID
        self.selectedKeySlotID = selection.keySlotID
        self.selectedModel = selection.model
        self.permissionMode = initialPermissionMode
        self.browsePath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
        self.session = AgentSession(
            permissionMode: initialPermissionMode,
            providerID: selection.providerID,
            keySlotID: selection.keySlotID,
            model: selection.model
        )
        self.approvalCenter = approval
        self.appResolver = resolver
        self.capabilityProbe = probe
        self.toolRegistry = registry
        self.fileService = fileService
        self.trashService = trash
        self.auditStore = audit
        self.transactionJournal = transactionJournal
        self.transactionEngine = transactionEngine
        self.checkpointStore = checkpoints
        self.sessionStore = sessions
        self.attachmentStore = attachments
        self.keyVault = keyVault
        self.agentCore = agent
        self.resourceIndex = ProgressiveResourceIndex(fileURL: support.appendingPathComponent("Index/resource-graph.json"))
        self.appKnowledge = AppKnowledgeRegistry(fileURL: support.appendingPathComponent("Index/app-knowledge.json"))
        self.customProviderFileURL = customProviderFileURL
    }

    public func bootstrap() {
        guard !didBootstrap, bootstrapTask == nil else { return }
        bootstrapTask = Task {
            defer {
                bootstrapTask = nil
                isRefreshingCapabilities = false
            }
            isRefreshingCapabilities = true
            capabilityRefreshMessage = "正在检测设备能力…"
            await appResolver.forceRefresh()
            capabilities = await capabilityProbe.probe()
            lastCapabilityRefreshAt = capabilities.generatedAt
            capabilityRefreshMessage = Self.capabilitySummary(capabilities)
            capabilityGraph = CapabilityGraphBuilder().build(profile: capabilities, tools: await toolRegistry.all())
            apps = await appResolver.installedApps()
            await seedKnowledgeIfNeeded(apps)
            do {
                try await checkpointStore.recoverUnfinishedAfterRestart()
                let recoveredTransactions = try await transactionEngine.recoverInterruptedTransactions()
                if !recoveredTransactions.isEmpty {
                    activityLines.append("已恢复 \(recoveredTransactions.count) 个中断事务到最终状态。")
                }
                try await resourceIndex.seedLightweight(apps: apps, capabilityProfile: capabilities)
                trash = try await trashService.records()
                auditEvents = Array((try await auditStore.readAll()).suffix(200).reversed())
                interruptedTasks = await checkpointStore.interrupted()
                try await restoreSessionState()
                try refreshFiles()
                if capabilities.status("data.keychain_scope") == .available {
                    do {
                        try await importBootstrapIfPresent()
                    } catch {
                        let message = Self.userFacingProviderBootstrapError(error)
                        activityLines.append("预配置 Key 自动导入未完成：\(message)")
                    }
                } else if bundledPrivateBootstrapAvailable {
                    activityLines.append("检测到私有 Key 版 IPA，但当前设备的 Keychain 实际探测未通过，因此已跳过自动导入，避免反复弹出失败提示。")
                }
                didBootstrap = true
            } catch {
                lastError = "初始化失败：\(error)"
            }
        }
    }

    public var selectedProvider: ProviderProfile? {
        providerProfiles.first(where: { $0.id == selectedProviderID && $0.enabled })
    }

    public var availableKeySlots: [ProviderKeySlot] {
        selectedProvider?.keySlots ?? []
    }

    public var availableModels: [String] {
        selectedProvider?.models(for: selectedKeySlotID) ?? []
    }

    public var selectedProtocol: ProviderProtocol? {
        selectedProvider?.protocolFor(model: selectedModel, keySlotID: selectedKeySlotID)
    }

    public var isProviderKeyMutationInFlight: Bool {
        inFlightOperationKeys.contains(Self.providerKeyMutationOperationKey)
    }

    public var selectedKeyIsInstalled: Bool {
        guard let provider = selectedProvider, !selectedKeySlotID.isEmpty else { return false }
        return isKeyInstalled(providerID: provider.id, keySlotID: selectedKeySlotID)
    }

    public var totalCatalogKeyCount: Int {
        providerProfiles.filter(\.enabled).reduce(0) { $0 + $1.keySlots.count }
    }

    public var configuredCatalogKeyCount: Int {
        providerProfiles.filter(\.enabled).reduce(0) { count, provider in
            count + provider.keySlots.filter { isKeyInstalled(providerID: provider.id, keySlotID: $0.id) }.count
        }
    }

    public var bundledPrivateBootstrapAvailable: Bool {
        Bundle.main.url(forResource: "CloudCode-Provider-Bootstrap", withExtension: "json") != nil
    }

    public func isKeyInstalled(providerID: String, keySlotID: String) -> Bool {
        guard !providerID.isEmpty, !keySlotID.isEmpty else { return false }
        return keyVault.contains(ProviderCatalog.keyReference(providerID: providerID, keySlotID: keySlotID))
    }

    public func selectProvider(_ providerID: String) {
        let state = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: providerID, keySlotID: "", model: ""),
            profiles: providerProfiles
        )
        applySelection(state)
    }

    public func selectKey(_ keySlotID: String) {
        let state = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: selectedProviderID, keySlotID: keySlotID, model: selectedModel),
            profiles: providerProfiles
        )
        applySelection(state)
    }

    public func selectModel(_ model: String) {
        guard let provider = selectedProvider else { return }
        let allowed = provider.models(for: selectedKeySlotID)
        guard allowed.contains(model) || provider.customModelAllowed else { return }
        selectedModel = model
        persistProviderSelection()
    }

    @discardableResult
    public func setKey(_ secret: String, providerID: String? = nil, keySlotID: String? = nil) -> Bool {
        let providerID = providerID ?? selectedProviderID
        let keySlotID = keySlotID ?? selectedKeySlotID
        guard !providerID.isEmpty, !keySlotID.isEmpty, !secret.isEmpty else {
            lastError = "厂商、Key 槽位或 Key 内容缺失。"
            return false
        }
        let reference = ProviderCatalog.keyReference(providerID: providerID, keySlotID: keySlotID)
        guard beginExclusiveOperation(Self.providerKeyMutationOperationKey) else {
            lastError = "另一个厂商 Key 操作正在进行中。"
            return false
        }
        defer { endExclusiveOperation(Self.providerKeyMutationOperationKey) }
        if let profile = providerProfiles.first(where: { $0.id == providerID }),
           let slot = profile.keySlots.first(where: { $0.id == keySlotID }),
           !slot.fingerprint.isEmpty,
           ProviderFingerprint.sha256(secret) != slot.fingerprint {
            lastError = "该 Key 与当前槽位的指纹不匹配，原有 Key 未被修改。"
            return false
        }
        do {
            try keyVault.set(secret, for: reference)
            return true
        } catch {
            lastError = "Keychain 错误：\(error)"
            return false
        }
    }

    @discardableResult
    public func saveProviderSelection() -> Bool {
        let reconciled = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: selectedProviderID, keySlotID: selectedKeySlotID, model: selectedModel),
            profiles: providerProfiles
        )
        guard !reconciled.providerID.isEmpty, !reconciled.keySlotID.isEmpty, !reconciled.model.isEmpty else {
            lastError = "请先选择厂商、Key 和模型。"
            return false
        }
        applySelection(reconciled)
        UserDefaults.standard.set(permissionMode.rawValue, forKey: "permission.mode")
        session.permissionMode = permissionMode
        session.providerID = selectedProviderID
        session.keySlotID = selectedKeySlotID
        session.model = selectedModel
        return true
    }

    public func send(
        _ text: String,
        imageData: Data? = nil,
        imageMimeType: String = "image/jpeg",
        imageFilename: String = "photo.jpg"
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || imageData != nil), !isRunning else { return }
        if let imageData, (imageData.isEmpty || imageData.count > ChatMessageAttachmentPolicy.maxImageBytes) {
            lastError = "图片大小必须小于 4 MB。"
            return
        }
        guard saveProviderSelection(), let config = currentProviderConfiguration() else {
            if lastError == nil { lastError = "厂商 / Key / 模型选择无效。" }
            return
        }
        guard selectedKeyIsInstalled else {
            lastError = "当前选择的 Key 尚未写入 iOS Keychain。请导入私有 Key 配置，或手动保存该 Key。"
            return
        }

        isRunning = true
        lastError = nil
        streamingAssistantMessageID = nil
        activityLines.append("正在使用 \(config.name) / \(config.model) 规划请求…")
        let allowedRoot: URL? = capabilities.isAvailable("filesystem.unrestricted") ? nil : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        currentTask?.cancel()
        let runID = runGeneration.start()
        let initialSession = session
        currentTask = Task {
            do {
                var requestSession = initialSession
                var attachments: [ChatAttachment] = []
                if let imageData {
                    let attachment = try attachmentStore.save(
                        data: imageData,
                        filename: imageFilename,
                        mimeType: imageMimeType,
                        pixelWidth: nil,
                        pixelHeight: nil,
                        sessionID: requestSession.id
                    )
                    attachments = [attachment]
                }

                requestSession.messages.append(ChatMessage(role: .user, content: trimmed, attachments: attachments))
                if requestSession.title == "新对话" || requestSession.title == "New Session" {
                    requestSession.title = Self.sessionTitle(from: trimmed.isEmpty ? "图片" : trimmed)
                }
                requestSession.updatedAt = Date()
                guard runGeneration.isCurrent(runID) else { return }
                session = requestSession

                let requestText = trimmed.isEmpty && !attachments.isEmpty ? "请处理这张图片。" : trimmed
                let stream = await agentCore.send(
                    text: requestText,
                    session: requestSession,
                    providerConfiguration: config,
                    allowedRoot: allowedRoot,
                    appendUserMessage: false
                )
                for try await event in stream {
                    guard runGeneration.isCurrent(runID) else { break }
                    switch event {
                    case .status(let value):
                        activityLines.append(value)
                    case .token(let token):
                        if let messageID = streamingAssistantMessageID,
                           let assistantIndex = session.messages.firstIndex(where: { $0.id == messageID }) {
                            session.messages[assistantIndex].content += token
                            session.updatedAt = Date()
                        } else {
                            let message = ChatMessage(role: .assistant, content: token)
                            session.messages.append(message)
                            streamingAssistantMessageID = message.id
                        }
                    case .toolStarted(let name, _):
                        activityLines.append("工具：\(name)")
                    case .toolFinished(let result):
                        activityLines.append("\(result.success ? "✓" : "✗") \(result.summary)")
                    case .approvalRequired:
                        break
                    case .error(let value):
                        lastError = value
                    case .finished:
                        break
                    }
                }
                if runGeneration.isCurrent(runID),
                   let saved = try? await sessionStore.load(requestSession.id) {
                    session = saved
                    streamingAssistantMessageID = nil
                    UserDefaults.standard.set(saved.id.uuidString, forKey: "session.current.id")
                }
            } catch {
                if runGeneration.isCurrent(runID) { lastError = String(describing: error) }
            }
            if runGeneration.finish(runID) {
                currentTask = nil
                isRunning = false
            }
            await reloadActivity()
            try? await reloadSessionHistory()
            refreshFilesFromDisk()
        }
    }

    public func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        runGeneration.cancel()
        isRunning = false
        activityLines.append("任务已中断；检查点已保留，可继续、回滚或检查最终状态。")
    }

    public func suspendForBackground() {
        guard isRunning || currentTask != nil else { return }
        currentTask?.cancel()
        currentTask = nil
        runGeneration.cancel()
        isRunning = false
        activityLines.append("App 已进入后台；当前任务已安全中断，不会盲目重放。完成检查点核对后可继续。")
    }

    public func refreshAfterForeground() {
        Task {
            await reloadActivity()
            refreshFilesFromDisk()
            try? await reloadSessionHistory()
        }
        refreshCapabilities()
    }

    public func createNewSession() {
        guard !isRunning else {
            lastError = "当前任务仍在运行，请先停止或等待完成后再新建对话。"
            return
        }
        let newSession = AgentSession(
            permissionMode: permissionMode,
            providerID: selectedProviderID,
            keySlotID: selectedKeySlotID,
            model: selectedModel
        )
        session = newSession
        streamingAssistantMessageID = nil
        activityLines = []
        UserDefaults.standard.set(newSession.id.uuidString, forKey: "session.current.id")
        // 空白新对话保持为内存态；只有真正发送第一条消息后才写入历史，避免反复新建产生大量空记录。
    }

    public func openSession(_ candidate: AgentSession) {
        guard !isRunning else {
            lastError = "当前任务仍在运行，请先停止或等待完成后再切换对话。"
            return
        }
        Task {
            do {
                let loaded = try await sessionStore.load(candidate.id)
                adoptSession(loaded)
                activityLines = []
                try await reloadSessionHistory()
            } catch {
                lastError = "打开旧对话失败：\(error)"
            }
        }
    }

    public func deleteSession(_ candidate: AgentSession) {
        guard !isRunning else {
            lastError = "当前任务仍在运行，请先停止或等待完成后再删除对话。"
            return
        }
        guard !sessionHasUnfinishedTask(candidate.id) else {
            lastError = "包含未完成任务的对话受到保护，请先完成、回滚或取消该任务。"
            return
        }
        let operationKey = sessionOperationKey(candidate.id)
        guard beginExclusiveOperation(operationKey) else { return }
        Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                if candidate.id == session.id {
                    let replacement = AgentSession(
                        permissionMode: permissionMode,
                        providerID: selectedProviderID,
                        keySlotID: selectedKeySlotID,
                        model: selectedModel
                    )
                    try await sessionStore.delete(candidate.id)
                    try? attachmentStore.removeAll(for: candidate.id)
                    session = replacement
                    streamingAssistantMessageID = nil
                    activityLines = []
                    UserDefaults.standard.set(replacement.id.uuidString, forKey: "session.current.id")
                } else {
                    try await sessionStore.delete(candidate.id)
                    try? attachmentStore.removeAll(for: candidate.id)
                }
                try await reloadSessionHistory()
            } catch {
                lastError = "删除对话失败：\(error)"
            }
        }
    }

    public func sessions(matching query: String) -> [AgentSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessionHistory }
        return sessionHistory.filter { item in
            if item.title.localizedCaseInsensitiveContains(trimmed) { return true }
            return item.messages.contains { message in
                (message.role == .user || message.role == .assistant)
                    && message.content.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    public func sessionHasUnfinishedTask(_ sessionID: UUID) -> Bool {
        interruptedTasks.contains { $0.sessionID == sessionID }
    }

    public func resumeTask(_ checkpoint: TaskCheckpoint) {
        guard !isRunning else { return }
        let operationKey = checkpointOperationKey(checkpoint.id)
        guard beginExclusiveOperation(operationKey) else { return }
        currentTask?.cancel()
        let runID = runGeneration.start()
        isRunning = true
        lastError = nil
        activityLines.append("正在继续检查点 \(checkpoint.stepIndex)/\(checkpoint.totalSteps)…")

        currentTask = Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                var resumedSession = try await sessionStore.load(checkpoint.sessionID)
                guard let request = checkpoint.payload["request"] ?? resumedSession.messages.last(where: { $0.role == .user })?.content,
                      !request.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let config = try ProviderCheckpointConfigurationResolver.resolve(
                    payload: checkpoint.payload,
                    profiles: providerProfiles
                )
                resumedSession.permissionMode = permissionMode
                resumedSession.providerID = config.providerID
                resumedSession.model = config.model
                resumedSession.keySlotID = keySlotID(for: config) ?? resumedSession.keySlotID
                try await sessionStore.save(resumedSession)
                adoptSession(resumedSession)
                let allowedRoot: URL? = capabilities.isAvailable("filesystem.unrestricted") ? nil : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                let source = InputSource(rawValue: checkpoint.payload["inputSource"] ?? "text") ?? .text
                let stream = await agentCore.send(
                    text: request,
                    inputSource: source,
                    session: resumedSession,
                    providerConfiguration: config,
                    allowedRoot: allowedRoot,
                    appendUserMessage: false,
                    resumeCheckpoint: checkpoint
                )
                try await consume(stream, runID: runID)
                if runGeneration.isCurrent(runID),
                   let saved = try? await sessionStore.load(checkpoint.sessionID) {
                    adoptSession(saved)
                }
            } catch {
                if runGeneration.isCurrent(runID) { lastError = String(describing: error) }
            }
            if runGeneration.finish(runID) {
                currentTask = nil
                isRunning = false
            }
            await reloadActivity()
            try? await reloadSessionHistory()
            refreshFilesFromDisk()
        }
    }

    public func cancelInterruptedTask(_ checkpoint: TaskCheckpoint) {
        let key = checkpointOperationKey(checkpoint.id)
        guard beginExclusiveOperation(key) else { return }
        Task {
            defer { endExclusiveOperation(key) }
            do {
                try await checkpointStore.mark(checkpoint.id, state: "cancelled", stepName: "用户取消")
                await reloadActivity()
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    public func rollbackTask(_ checkpoint: TaskCheckpoint) {
        let key = checkpointOperationKey(checkpoint.id)
        guard beginExclusiveOperation(key) else { return }
        Task {
            defer { endExclusiveOperation(key) }
            do {
                try await transactionJournal.assertHealthy()
                let transactions = await transactionJournal.all()
                let candidate = transactions.first(where: {
                    $0.sessionID == checkpoint.sessionID && $0.backupPath != nil && $0.state == .committed
                })
                guard let transaction = candidate else { throw TransactionError.noBackup }
                _ = try await transactionEngine.rollback(transactionID: transaction.id)
                try await checkpointStore.mark(checkpoint.id, state: "rolled_back", stepName: "最近一次已提交事务已回滚")
                await reloadActivity()
                refreshFilesFromDisk()
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    public func refreshCapabilities() {
        if bootstrapTask != nil {
            capabilityRefreshMessage = "初始化中的设备能力检测尚未完成。"
            return
        }
        guard capabilityRefreshTask == nil else { return }
        isRefreshingCapabilities = true
        capabilityRefreshMessage = "正在检测设备能力…"
        let previous = capabilities
        capabilityRefreshTask = Task {
            defer {
                capabilityRefreshTask = nil
                isRefreshingCapabilities = false
            }
            await appResolver.forceRefresh()
            guard !Task.isCancelled else {
                capabilityRefreshMessage = "设备能力检测已取消。"
                return
            }
            let refreshed = await capabilityProbe.probe()
            guard !Task.isCancelled else {
                capabilityRefreshMessage = "设备能力检测已取消。"
                return
            }
            capabilities = refreshed
            lastCapabilityRefreshAt = refreshed.generatedAt
            capabilityGraph = CapabilityGraphBuilder().build(profile: refreshed, tools: await toolRegistry.all())
            apps = await appResolver.installedApps()
            do {
                try await resourceIndex.seedLightweight(apps: apps, capabilityProfile: refreshed)
            } catch {
                lastError = "设备能力检测完成，但资源索引刷新失败：\(error)"
            }
            let changed = Self.changedCapabilityCount(from: previous, to: refreshed)
            capabilityRefreshMessage = Self.capabilitySummary(refreshed) + (changed > 0 ? " · \(changed) 项状态变化" : " · 状态无变化")
        }
    }

    public func refreshFiles() throws {
        let root = URL(fileURLWithPath: browsePath, isDirectory: true)
        let allowed = capabilities.isAvailable("filesystem.unrestricted") ? nil : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        files = try fileService.list(directory: root, allowedRoot: allowed)
    }

    public func reloadActivity() async {
        do {
            trash = try await trashService.records()
        } catch {
            lastError = "回收站状态刷新失败：\(error)"
        }
        do {
            auditEvents = Array((try await auditStore.readAll()).suffix(200).reversed())
        } catch {
            lastError = "审计记录刷新失败：\(error)"
        }
        interruptedTasks = await checkpointStore.interrupted()
    }

    public func restoreTrash(_ record: TrashRecord) {
        let key = trashOperationKey(record.id)
        guard beginExclusiveOperation(key) else { return }
        Task {
            defer { endExclusiveOperation(key) }
            do {
                let restored = try await trashService.restore(record.id)
                guard await trashService.verifyRestored(restored) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                await reloadActivity()
                refreshFilesFromDisk()
            } catch { lastError = String(describing: error) }
        }
    }

    public func purgeTrash(_ record: TrashRecord) {
        let key = trashOperationKey(record.id)
        guard beginExclusiveOperation(key) else { return }
        Task {
            defer { endExclusiveOperation(key) }
            let preview = ApprovalPreview(title: "永久删除回收站项目", target: record.originalPath, originalSummary: "\(record.size) 字节", reason: "永久删除后无法回滚", plan: ["隔离回收站内容", "更新日志", "删除隔离内容"], risk: .permanentDestructive)
            let approved: Bool
            if permissionMode == .full {
                approved = true
            } else {
                approved = await approvalCenter.requestApproval(preview)
            }
            guard approved else { return }
            do {
                try await trashService.permanentlyDelete(record.id)
                let remaining = try await trashService.records()
                guard !remaining.contains(where: { $0.id == record.id }),
                      !FileManager.default.fileExists(atPath: record.trashPath) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                await reloadActivity()
                refreshFilesFromDisk()
            } catch { lastError = String(describing: error) }
        }
    }

    public func addCustomProvider(label: String, baseURLText: String, apiKey: String) {
        let operationKey = Self.providerKeyMutationOperationKey
        guard beginExclusiveOperation(operationKey) else {
            lastError = "另一个厂商 Key 操作正在进行中。"
            return
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty,
              let baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProviderEndpointPolicy.allowsBaseURL(baseURL),
              !apiKey.isEmpty else {
            endExclusiveOperation(operationKey)
            lastError = "自定义厂商需要名称、安全 HTTPS Base URL 和 API Key。"
            return
        }
        let providerID = "custom-\(UUID().uuidString.lowercased())"
        let slotID = "slot-1"
        let reference = ProviderCatalog.keyReference(providerID: providerID, keySlotID: slotID)
        let fingerprint = ProviderFingerprint.sha256(apiKey)
        activityLines.append("正在发现 \(trimmedLabel) 的模型和协议…")
        Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                let discovery = try await ProviderDiscoveryClient().discover(baseURL: baseURL, apiKey: apiKey)
                guard !discovery.models.isEmpty, let preferred = discovery.protocols.first else {
                    lastError = "厂商发现流程未能验证可用的推理协议。"
                    return
                }
                let slot = ProviderKeySlot(
                    id: slotID,
                    label: "Key 1",
                    fingerprint: fingerprint,
                    status: .verified,
                    models: discovery.models,
                    protocols: discovery.protocols
                )
                let profile = ProviderProfile(
                    id: providerID,
                    displayName: trimmedLabel,
                    baseURL: baseURL,
                    protocols: discovery.protocols,
                    preferredProtocol: preferred,
                    authMode: discovery.authMode,
                    models: discovery.models,
                    keySlots: [slot],
                    readiness: discovery.readiness,
                    source: .custom,
                    customModelAllowed: true
                )
                try keyVault.set(apiKey, for: reference)
                let stored = try await keyVault.key(for: reference)
                guard stored == apiKey else { throw ProviderKeyProvisioningError.verificationFailed(reference) }

                providerProfiles.append(profile)
                do {
                    try persistCustomProviders()
                } catch {
                    providerProfiles.removeAll { $0.id == providerID }
                    throw error
                }
                selectProvider(providerID)
                activityLines.append("自定义厂商已就绪：\(trimmedLabel)（\(discovery.models.count) 个模型）。")
            } catch {
                try? keyVault.remove(reference)
                providerProfiles.removeAll { $0.id == providerID }
                lastError = "自定义厂商配置失败：\(error)"
            }
        }
    }

    public func importProviderBootstrap(from url: URL) {
        let operationKey = Self.providerKeyMutationOperationKey
        guard beginExclusiveOperation(operationKey) else {
            lastError = "另一个厂商 Key 操作正在进行中。"
            return
        }
        Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                let count = try await importProviderBootstrapNow(from: url, removeSource: true)
                activityLines.append("已将 \(count) 个厂商 Key 导入 Keychain，并删除明文配置源。")
            } catch {
                lastError = "私有 Key 配置导入失败：\(Self.userFacingProviderBootstrapError(error))"
            }
        }
    }

    public func importBundledProviderBootstrap() {
        guard let url = Bundle.main.url(forResource: "CloudCode-Provider-Bootstrap", withExtension: "json") else {
            lastError = "当前安装包不包含预配置 Key。请使用私有 Key 版 IPA，或选择“从文件导入”。"
            return
        }
        let operationKey = Self.providerKeyMutationOperationKey
        guard beginExclusiveOperation(operationKey) else {
            lastError = "另一个厂商 Key 操作正在进行中。"
            return
        }
        Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                let count = try await importProviderBootstrapNow(from: url, removeSource: false)
                activityLines.append("已一键导入预配置 Key：\(count) 个 Key 已写入 iOS Keychain。")
            } catch {
                lastError = "预配置 Key 导入失败：\(Self.userFacingProviderBootstrapError(error))"
            }
        }
    }

    private func keySlotID(for configuration: ProviderConfiguration) -> String? {
        guard let providerID = configuration.providerID,
              let provider = providerProfiles.first(where: { $0.id == providerID }) else { return nil }
        return provider.keySlots.first(where: {
            ProviderCatalog.keyReference(providerID: provider.id, keySlotID: $0.id) == configuration.apiKeyReference
        })?.id
    }

    private func currentProviderConfiguration() -> ProviderConfiguration? {
        guard let provider = selectedProvider,
              let slot = provider.keySlots.first(where: { $0.id == selectedKeySlotID }),
              !selectedModel.isEmpty else { return nil }
        let protocolName = provider.protocolFor(model: selectedModel, keySlotID: slot.id)
        let references = provider.orderedKeyReferences(selectedKeySlotID: slot.id)
        guard let primary = references.first else { return nil }
        return ProviderConfiguration(
            name: provider.displayName,
            baseURL: provider.baseURL,
            model: selectedModel,
            apiKeyReference: primary,
            providerID: provider.id,
            protocolName: protocolName.rawValue,
            authModeName: provider.authMode.rawValue,
            fallbackAPIKeyReferences: provider.autoRotateKeys ? Array(references.dropFirst()) : [],
            allowSameProviderKeyFailover: provider.autoRotateKeys
        )
    }

    private func applySelection(_ state: ProviderSelectionState) {
        selectedProviderID = state.providerID
        selectedKeySlotID = state.keySlotID
        selectedModel = state.model
        persistProviderSelection()
    }

    private func persistProviderSelection() {
        let defaults = UserDefaults.standard
        defaults.set(selectedProviderID, forKey: "provider.selected.id")
        defaults.set(selectedKeySlotID, forKey: "provider.selected.keySlot")
        defaults.set(selectedModel, forKey: "provider.selected.model")
    }

    private func persistCustomProviders() throws {
        let profiles = providerProfiles.filter { $0.source == .custom }
        try FileManager.default.createDirectory(at: customProviderFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: customProviderFileURL, options: .atomic)
    }

    private static func loadCustomProviders(from url: URL) -> [ProviderProfile] {
        guard let data = try? Data(contentsOf: url),
              let profiles = try? JSONDecoder().decode([ProviderProfile].self, from: data) else { return [] }
        return profiles.filter { $0.enabled && $0.source == .custom }
    }

    private func importBootstrapIfPresent() async throws {
        let operationKey = Self.providerKeyMutationOperationKey
        guard beginExclusiveOperation(operationKey) else {
            throw ProviderError.transport("另一个厂商 Key 操作正在进行中")
        }
        defer { endExclusiveOperation(operationKey) }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let url = documents?.appendingPathComponent("CloudCode-Provider-Bootstrap.json"),
           FileManager.default.fileExists(atPath: url.path) {
            let count = try await importProviderBootstrapNow(from: url, removeSource: true)
            activityLines.append("已自动导入私有 Key 配置：\(count) 个 Key。")
            return
        }

        let bundledCatalogFullyConfigured = ProviderCatalog.desktopSnapshot.allSatisfy { provider in
            provider.keySlots.allSatisfy { slot in
                isKeyInstalled(providerID: provider.id, keySlotID: slot.id)
            }
        }
        guard !bundledCatalogFullyConfigured,
              let bundled = Bundle.main.url(forResource: "CloudCode-Provider-Bootstrap", withExtension: "json") else { return }
        let count = try await importProviderBootstrapNow(from: bundled, removeSource: false)
        activityLines.append("检测到私有 Key 版 IPA，已自动配置 \(count) 个 Key 到 iOS Keychain。")
    }

    private func importProviderBootstrapNow(from url: URL, removeSource: Bool) async throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data = try Data(contentsOf: url, options: [.mappedIfSafe])
        defer { data.resetBytes(in: 0..<data.count) }
        let payload = try ProviderBootstrapPayload.decodeBootstrap(from: data)
        guard payload.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }

        var pending: [(reference: String, secret: String)] = []
        var plannedReferences = Set<String>()
        for providerKeys in payload.providers {
            guard let profile = providerProfiles.first(where: { $0.id == providerKeys.providerID && $0.enabled }) else { continue }
            for key in providerKeys.keys {
                guard let slot = profile.keySlots.first(where: { $0.id == key.slotID }), !key.secret.isEmpty else { continue }
                let fingerprint = ProviderFingerprint.sha256(key.secret)
                if !slot.fingerprint.isEmpty, slot.fingerprint != fingerprint { throw CocoaError(.fileReadCorruptFile) }
                if let declared = key.fingerprint, !declared.isEmpty, declared != fingerprint { throw CocoaError(.fileReadCorruptFile) }
                let reference = ProviderCatalog.keyReference(providerID: profile.id, keySlotID: slot.id)
                guard plannedReferences.insert(reference).inserted else { throw CocoaError(.fileReadCorruptFile) }
                pending.append((reference, key.secret))
            }
        }
        guard !pending.isEmpty else { throw ProviderError.missingAPIKey }

        let mutations = pending.map { ProviderKeyMutation(reference: $0.reference, secret: $0.secret) }
        let importedCount = try await ProviderKeyProvisioner.apply(
            mutations,
            vault: keyVault,
            finalizer: {
                if removeSource {
                    try FileManager.default.removeItem(at: url)
                }
            }
        )
        return importedCount
    }

    private func restoreSessionState() async throws {
        let all = try await sessionStore.all()
        sessionHistory = all
        let currentID = UserDefaults.standard.string(forKey: "session.current.id").flatMap(UUID.init(uuidString:))
        if let currentID, let current = all.first(where: { $0.id == currentID }) {
            adoptSession(current)
            return
        }
        if let mostRecent = all.first {
            adoptSession(mostRecent)
            return
        }
        session.providerID = selectedProviderID
        session.keySlotID = selectedKeySlotID
        session.model = selectedModel
        UserDefaults.standard.set(session.id.uuidString, forKey: "session.current.id")
        sessionHistory = []
    }

    private func reloadSessionHistory() async throws {
        sessionHistory = try await sessionStore.all()
    }

    private func adoptSession(_ loaded: AgentSession) {
        session = loaded
        streamingAssistantMessageID = nil
        permissionMode = loaded.permissionMode
        let desired = ProviderSelectionState(
            providerID: loaded.providerID ?? selectedProviderID,
            keySlotID: loaded.keySlotID ?? selectedKeySlotID,
            model: loaded.model ?? selectedModel
        )
        let reconciled = ProviderSelectionResolver.reconcile(desired, profiles: providerProfiles)
        applySelection(reconciled)
        session.providerID = reconciled.providerID
        session.keySlotID = reconciled.keySlotID
        session.model = reconciled.model
        UserDefaults.standard.set(session.id.uuidString, forKey: "session.current.id")
    }

    private static func sessionTitle(from text: String) -> String {
        let compact = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !compact.isEmpty else { return "图片消息" }
        let limit = 32
        return compact.count <= limit ? compact : String(compact.prefix(limit)) + "…"
    }

    private static func capabilitySummary(_ profile: CapabilityProfile) -> String {
        let available = profile.records.filter { $0.status == .available }.count
        let unavailable = profile.records.filter { $0.status == .unavailable }.count
        let validation = profile.records.filter { $0.status == .deviceValidationRequired }.count
        let unknown = profile.records.filter { $0.status == .unknown }.count
        var summary = "检测完成：\(available) 可用 / \(unavailable) 不可用 / \(validation) 需要真机验证"
        if unknown > 0 { summary += " / \(unknown) 未知" }
        return summary
    }

    private static func changedCapabilityCount(from old: CapabilityProfile, to new: CapabilityProfile) -> Int {
        let oldStatuses = Dictionary(uniqueKeysWithValues: old.records.map { ($0.id, $0.status) })
        return new.records.reduce(into: 0) { count, record in
            if oldStatuses[record.id] != record.status { count += 1 }
        }
    }

    private static func userFacingProviderBootstrapError(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .dataCorrupted:
                return "Key 配置文件格式损坏或包含无法识别的数据。"
            case .keyNotFound:
                return "Key 配置文件缺少必要字段。"
            case .typeMismatch, .valueNotFound:
                return "Key 配置文件字段类型不正确。"
            @unknown default:
                return "Key 配置文件无法解析。"
            }
        }
        if error is CocoaError {
            return "Key 配置文件校验失败，请确认文件来自当前版本。"
        }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain && nsError.code == Int(errSecMissingEntitlement) {
            return "当前安装签名缺少 Keychain 身份/访问组授权（-34018）。请安装已修复签名的版本；这不是 Key 内容错误。"
        }
        if nsError.domain == NSOSStatusErrorDomain && nsError.code == Int(errSecInteractionNotAllowed) {
            return "Keychain 当前受系统保护不可访问；请保持设备解锁后重试。"
        }
        if let providerError = error as? ProviderError {
            return String(describing: providerError)
        }
        return String(describing: error)
    }

    private func refreshFilesFromDisk() {
        do {
            try refreshFiles()
        } catch {
            lastError = "文件视图刷新失败：\(error)"
        }
    }

    private func seedKnowledgeIfNeeded(_ installedApps: [ResourceNode]) async {
        let common = installedApps.filter { node in
            let name = node.displayName.lowercased()
            return name.contains("documents") || name == "files" || name.contains("slides")
        }
        for app in common {
            guard let bundleID = app.ownerBundleID else { continue }
            let knowledge = AppKnowledge(appName: app.displayName, bundleID: bundleID, preferredRoutes: [.structuredTool, .urlScheme, .guiFallback], successRate: 0.5, estimatedCost: 0.5, appVersion: app.metadata["version"])
            try? await appKnowledge.upsert(knowledge)
        }
    }

    public func isTrashOperationInFlight(_ id: UUID) -> Bool {
        inFlightOperationKeys.contains(trashOperationKey(id))
    }

    public func isCheckpointOperationInFlight(_ id: UUID) -> Bool {
        inFlightOperationKeys.contains(checkpointOperationKey(id))
    }

    private func beginExclusiveOperation(_ key: String) -> Bool {
        inFlightOperationKeys.insert(key).inserted
    }

    private func endExclusiveOperation(_ key: String) {
        inFlightOperationKeys.remove(key)
    }

    private func trashOperationKey(_ id: UUID) -> String { "trash:\(id.uuidString)" }
    private func checkpointOperationKey(_ id: UUID) -> String { "checkpoint:\(id.uuidString)" }
    private func sessionOperationKey(_ id: UUID) -> String { "session:\(id.uuidString)" }

    private func consume(_ stream: AsyncThrowingStream<AgentEvent, Error>, runID: UUID) async throws {
        var assistantStarted = false
        for try await event in stream {
            guard runGeneration.isCurrent(runID) else { break }
            switch event {
            case .status(let value):
                activityLines.append(value)
            case .token(let token):
                if let messageID = streamingAssistantMessageID,
                   let assistantIndex = session.messages.firstIndex(where: { $0.id == messageID }) {
                    session.messages[assistantIndex].content += token
                    session.updatedAt = Date()
                } else {
                    let message = ChatMessage(role: .assistant, content: token)
                    session.messages.append(message)
                    streamingAssistantMessageID = message.id
                }
            case .toolStarted(let name, _):
                activityLines.append("工具：\(name)")
            case .toolFinished(let result):
                activityLines.append("\(result.success ? "✓" : "✗") \(result.summary)")
            case .approvalRequired:
                break
            case .error(let value):
                lastError = value
            case .finished:
                break
            }
        }
    }

    private static func supportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support")
        let root = base.appendingPathComponent("CloudCode", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
