import Foundation
import SwiftUI
import CloudCodeCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class CloudCodeViewModel: ObservableObject {
    @Published public var session: AgentSession
    @Published private var streamingAssistantMessageIDs: [UUID: UUID] = [:]
    @Published public private(set) var runningSessionIDs: Set<UUID> = []
    @Published public var activityLines: [String] = []
    @Published public var capabilities = CapabilityProfile(records: [])
    @Published public var capabilityGraph = CapabilityGraph()
    @Published public var apps: [ResourceNode] = []
    @Published public var files: [FileEntry] = []
    @Published public var trash: [TrashRecord] = []
    @Published public var auditEvents: [AuditEvent] = []
    @Published public var interruptedTasks: [TaskCheckpoint] = []
    @Published public private(set) var sessionHistory: [AgentSession] = []
    @Published public private(set) var isRefreshingCapabilities = false
    @Published public private(set) var capabilityRefreshMessage: String?
    @Published public private(set) var lastCapabilityRefreshAt: Date?
    @Published public var lastError: String?
    @Published public private(set) var inFlightOperationKeys: Set<String> = []
    @Published public private(set) var diagnosticLogs: [DiagnosticLogRecord] = []
    @Published public private(set) var diagnosticLogBytes: Int64 = 0
    @Published public private(set) var providerEndpointHealth: [String: ProviderEndpointHealth] = [:]
    @Published public private(set) var providerFailureSessionIDs: Set<UUID> = []
    @Published public private(set) var retryableProviderFailureSessionIDs: Set<UUID> = []
    @Published public private(set) var hermesRecords: [HermesMemoryRecord] = []
    @Published public private(set) var hermesProjects: [String] = []
    @Published public private(set) var hermesTags: [String] = []
    @Published public private(set) var hermesStatusMessage: String?

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
    private let diagnosticLogStore: DiagnosticLogStore
    private let diagnosticBundleExporter: DiagnosticBundleExporter
    private let diagnosticSourceFiles: [DiagnosticBundleSource]
    private let transactionJournal: TransactionJournal
    private let transactionEngine: TransactionEngine
    private let checkpointStore: TaskCheckpointStore
    private let executionLedger: ToolExecutionLedger
    private let sessionStore: SessionStore
    private let attachmentStore: ChatAttachmentStore
    private let keyVault: KeychainAPIKeyVault
    private let steeringMailbox: AgentSteeringMailbox
    private let hermesStore: HermesMemoryStore
    private let agentCore: AgentCore
    private let resourceIndex: ProgressiveResourceIndex
    private let appKnowledge: AppKnowledgeRegistry
    private let customProviderFileURL: URL
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRunTokens: [UUID: UUID] = [:]
    private var activeConfigurations: [UUID: ProviderConfiguration] = [:]
    private var liveSessions: [UUID: AgentSession] = [:]
    private var sessionActivityLines: [UUID: [String]] = [:]
    private var sessionErrors: [UUID: String] = [:]
    private var bootstrapTask: Task<Void, Never>?
    private var capabilityRefreshTask: Task<Void, Never>?
    #if canImport(UIKit)
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var backgroundWindowTask: Task<Void, Never>?
    private var didBootstrap = false
    private static let providerKeyMutationOperationKey = "provider-key:mutation"
    private static let autoResumeTaskDefaultsKey = "task.autoResumeUnlessStopped"
    private static let backgroundContinuationWindow: TimeInterval = 90 * 60

    public init() {
        let support = Self.supportRoot()
        let approval = ApprovalCenter()
        let diagnosticLogStore = DiagnosticLogStore(directory: support.appendingPathComponent("Diagnostics/Runtime", isDirectory: true))
        let resolver = IOSAppResolver(diagnosticLogger: diagnosticLogStore)
        let probe = CapabilityProbe(appResolver: resolver, diagnosticLogger: diagnosticLogStore)
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
        let executionLedgerURL = support.appendingPathComponent("Execution/tool-results.json")
        let executionLedger = ToolExecutionLedger(fileURL: executionLedgerURL)
        let router = ToolRouter(registry: registry, executors: [structured, cli, privateApps, URLSchemeExecutor(), gui], executionLedger: executionLedger, diagnosticLogger: diagnosticLogStore)
        let keyVault = KeychainAPIKeyVault()
        let sessions = SessionStore(root: support.appendingPathComponent("Sessions", isDirectory: true))
        let attachments = ChatAttachmentStore(root: support.appendingPathComponent("Attachments", isDirectory: true))
        let checkpointURL = support.appendingPathComponent("Tasks/checkpoints.json")
        let checkpoints = TaskCheckpointStore(fileURL: checkpointURL)
        let hermesStore = HermesMemoryStore(root: support.appendingPathComponent("Hermes", isDirectory: true))
        let provider = ProviderClientRouter(
            keyVault: keyVault,
            anthropic: AnthropicProviderClient(diagnosticLogger: diagnosticLogStore),
            openAIChat: OpenAICompatibleProviderClient(diagnosticLogger: diagnosticLogStore),
            responses: OpenAIResponsesProviderClient(diagnosticLogger: diagnosticLogStore),
            diagnosticLogger: diagnosticLogStore
        )
        let steeringMailbox = AgentSteeringMailbox()
        let agent = AgentCore(
            provider: provider,
            keyVault: keyVault,
            toolRouter: router,
            registry: registry,
            capabilityProbe: probe,
            sessionStore: sessions,
            checkpointStore: checkpoints,
            steeringMailbox: steeringMailbox,
            memoryProvider: hermesStore,
            diagnosticLogger: diagnosticLogStore
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
        self.diagnosticLogStore = diagnosticLogStore
        self.diagnosticBundleExporter = DiagnosticBundleExporter(logStore: diagnosticLogStore)
        self.diagnosticSourceFiles = [
            DiagnosticBundleSource(archivePath: "index/resource-graph.json", fileURL: support.appendingPathComponent("Index/resource-graph.json"))
        ]
        self.transactionJournal = transactionJournal
        self.transactionEngine = transactionEngine
        self.checkpointStore = checkpoints
        self.executionLedger = executionLedger
        self.sessionStore = sessions
        self.attachmentStore = attachments
        self.keyVault = keyVault
        self.steeringMailbox = steeringMailbox
        self.hermesStore = hermesStore
        self.agentCore = agent
        self.resourceIndex = ProgressiveResourceIndex(fileURL: support.appendingPathComponent("Index/resource-graph.json"))
        self.appKnowledge = AppKnowledgeRegistry(fileURL: support.appendingPathComponent("Index/app-knowledge.json"))
        self.customProviderFileURL = customProviderFileURL
    }

    public func bootstrap() {
        guard !didBootstrap, bootstrapTask == nil else { return }
        bootstrapTask = Task {
            try? await diagnosticLogStore.log(
                level: .info,
                subsystem: "app",
                action: "bootstrap",
                result: "started",
                metadata: [
                    "bundleID": Bundle.main.bundleIdentifier ?? "",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                ]
            )
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
                do {
                    try await hermesStore.bootstrap()
                    await reloadHermes()
                } catch {
                    hermesStatusMessage = "Hermes 初始化失败：\(error)"
                    try? await diagnosticLogStore.log(level: .error, subsystem: "hermes", action: "bootstrap", result: "failed", error: error)
                }
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
                try? await diagnosticLogStore.log(level: .info, subsystem: "app", action: "bootstrap", result: "completed")
                await refreshDiagnosticLogs()
                resumeMostRecentInterruptedTaskIfRequested()
            } catch {
                try? await diagnosticLogStore.log(level: .error, subsystem: "app", action: "bootstrap", result: "failed", error: error)
                lastError = "初始化失败：\(error)"
            }
        }
    }

    public var isRunning: Bool {
        !runningSessionIDs.isEmpty
    }

    public var isCurrentSessionRunning: Bool {
        runningSessionIDs.contains(session.id)
    }

    public var hasCurrentProviderFailure: Bool {
        providerFailureSessionIDs.contains(session.id)
    }

    public var canRetryCurrentProviderFailure: Bool {
        retryableProviderFailureSessionIDs.contains(session.id) && !isCurrentSessionRunning
    }

    public var streamingAssistantMessageID: UUID? {
        streamingAssistantMessageIDs[session.id]
    }

    public func isSessionRunning(_ sessionID: UUID) -> Bool {
        runningSessionIDs.contains(sessionID)
    }

    public var selectedProvider: ProviderProfile? {
        providerProfiles.first(where: { $0.id == selectedProviderID && $0.enabled })
    }

    public var selectedProviderEndpointHealth: ProviderEndpointHealth? {
        providerEndpointHealth[selectedProviderID]
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

    public func retryCurrentProviderFailure() {
        let sessionID = session.id
        guard canRetryCurrentProviderFailure else { return }
        lastError = nil
        sessionErrors.removeValue(forKey: sessionID)
        retryableProviderFailureSessionIDs.remove(sessionID)
        Task {
            let candidates = await checkpointStore.interrupted().filter { $0.sessionID == sessionID }
            guard let checkpoint = candidates.max(by: { $0.updatedAt < $1.updatedAt }) else {
                providerFailureSessionIDs.remove(sessionID)
                lastError = "没有找到可重试的检查点。"
                return
            }
            resumeTask(checkpoint)
        }
    }

    public func send(
        _ text: String,
        imageData: Data? = nil,
        imageMimeType: String = "image/jpeg",
        imageFilename: String = "photo.jpg"
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageData != nil else { return }
        if let imageData, (imageData.isEmpty || imageData.count > ChatMessageAttachmentPolicy.maxImageBytes) {
            lastError = "图片大小必须小于 4 MB。"
            return
        }

        if isCurrentSessionRunning {
            submitSteering(
                trimmed,
                imageData: imageData,
                imageMimeType: imageMimeType,
                imageFilename: imageFilename
            )
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

        let sessionID = session.id
        let runToken = UUID()
        let initialSession = session
        let allowedRoot: URL? = capabilities.isAvailable("filesystem.unrestricted") ? nil : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        runningSessionIDs.insert(sessionID)
        activeRunTokens[sessionID] = runToken
        activeConfigurations[sessionID] = config
        liveSessions[sessionID] = initialSession
        streamingAssistantMessageIDs.removeValue(forKey: sessionID)
        sessionErrors.removeValue(forKey: sessionID)
        providerFailureSessionIDs.remove(sessionID)
        retryableProviderFailureSessionIDs.remove(sessionID)
        sessionActivityLines[sessionID, default: []].append("正在使用 \(config.name) / \(config.model) 规划请求…")
        syncVisibleSessionState(sessionID)
        UserDefaults.standard.set(true, forKey: Self.autoResumeTaskDefaultsKey)

        let task = Task {
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
                guard activeRunTokens[sessionID] == runToken else { return }
                liveSessions[sessionID] = requestSession
                upsertSessionHistory(requestSession)
                syncVisibleSessionState(sessionID)

                let requestText = trimmed.isEmpty && !attachments.isEmpty ? "请处理这张图片。" : trimmed
                let stream = await agentCore.send(
                    text: requestText,
                    session: requestSession,
                    providerConfiguration: config,
                    allowedRoot: allowedRoot,
                    appendUserMessage: false
                )
                for try await event in stream {
                    guard activeRunTokens[sessionID] == runToken else { break }
                    handleAgentEvent(event, sessionID: sessionID)
                }
                if activeRunTokens[sessionID] == runToken,
                   let saved = try? await sessionStore.load(sessionID) {
                    liveSessions[sessionID] = saved
                    upsertSessionHistory(saved)
                    streamingAssistantMessageIDs.removeValue(forKey: sessionID)
                    markProviderEndpointHealthy(config)
                    providerFailureSessionIDs.remove(sessionID)
                    retryableProviderFailureSessionIDs.remove(sessionID)
                    syncVisibleSessionState(sessionID)
                }
            } catch {
                if activeRunTokens[sessionID] == runToken {
                    recordProviderFailure(error, configuration: config, sessionID: sessionID)
                    sessionErrors[sessionID] = Self.userFacingRunError(error)
                    syncVisibleSessionState(sessionID)
                }
            }

            finishSessionRun(sessionID: sessionID, runToken: runToken)
            await reloadActivity()
            clearAutoResumeIntentIfNoPendingTask()
            try? await reloadSessionHistoryMergingLiveSessions()
            refreshFilesFromDisk()
        }
        activeTasks[sessionID] = task
    }

    private func submitSteering(
        _ text: String,
        imageData: Data?,
        imageMimeType: String,
        imageFilename: String
    ) {
        let sessionID = session.id
        guard runningSessionIDs.contains(sessionID) else { return }
        var attachments: [ChatAttachment] = []
        do {
            if let imageData {
                attachments = [try attachmentStore.save(
                    data: imageData,
                    filename: imageFilename,
                    mimeType: imageMimeType,
                    pixelWidth: nil,
                    pixelHeight: nil,
                    sessionID: sessionID
                )]
            }
        } catch {
            lastError = "追加图片失败：\(error)"
            return
        }

        let content = text.isEmpty && !attachments.isEmpty ? "请同时参考这张追加图片，并按我最新的要求调整。" : text
        let message = ChatMessage(role: .user, content: content, attachments: attachments)
        var visible = liveSessions[sessionID] ?? session
        visible.messages.append(message)
        visible.updatedAt = Date()
        liveSessions[sessionID] = visible
        streamingAssistantMessageIDs.removeValue(forKey: sessionID)
        sessionActivityLines[sessionID, default: []].append("已收到追加指令；将在安全边界中止旧规划或完成当前不可打断步骤后按新要求继续。")
        upsertSessionHistory(visible)
        syncVisibleSessionState(sessionID)

        Task {
            await steeringMailbox.submit(message, sessionID: sessionID)
        }
    }

    public func cancelCurrentTask() {
        let sessionID = session.id
        guard let task = activeTasks[sessionID] else { return }
        task.cancel()
        activeTasks.removeValue(forKey: sessionID)
        activeRunTokens.removeValue(forKey: sessionID)
        activeConfigurations.removeValue(forKey: sessionID)
        runningSessionIDs.remove(sessionID)
        streamingAssistantMessageIDs.removeValue(forKey: sessionID)
        Task { await steeringMailbox.clear(sessionID: sessionID) }
        sessionActivityLines[sessionID, default: []].append("任务已按你的明确命令停止；检查点已保留，但这个会话不会自动继续。")
        if runningSessionIDs.isEmpty {
            UserDefaults.standard.set(false, forKey: Self.autoResumeTaskDefaultsKey)
            endBackgroundExecutionIfNeeded()
        }
        syncVisibleSessionState(sessionID)
    }

    public func suspendForBackground() {
        guard isRunning else { return }
        Task {
            try? await diagnosticLogStore.log(level: .info, subsystem: "app", action: "background", result: "entered", metadata: ["runningSessions": String(runningSessionIDs.count)])
        }
        // 系统弹窗、App 切换或 LaunchServices 状态变化都可能让 scenePhase 短暂进入后台。
        // 立即取消会把已经被系统接受的状态变更卡在“请求已发出、结果未校验”的窗口。
        // 申请一段有界后台时间，让当前步骤优先完成结果校验；只有系统明确收回后台时间时
        // 才取消并依赖持久化检查点恢复。
        let message = "App 已进入后台；Cloud Code 将以 90 分钟为连续任务保留窗口。iOS 若更早收回后台执行时间，会安全中断并保留检查点，回到可执行状态后自动继续。"
        for sessionID in runningSessionIDs {
            sessionActivityLines[sessionID, default: []].append(message)
        }
        syncVisibleSessionState(session.id)
        beginBackgroundExecutionIfNeeded()
    }

    public func refreshAfterForeground() {
        endBackgroundExecutionIfNeeded()
        Task {
            try? await diagnosticLogStore.log(level: .info, subsystem: "app", action: "foreground", result: "entered", metadata: ["runningSessions": String(runningSessionIDs.count)])
            await reloadActivity()
            refreshFilesFromDisk()
            try? await reloadSessionHistory()
            resumeMostRecentInterruptedTaskIfRequested()
        }
        refreshCapabilities()
    }

    private func beginBackgroundExecutionIfNeeded() {
        backgroundWindowTask?.cancel()
        backgroundWindowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.backgroundContinuationWindow * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.backgroundContinuationWindowDidElapse()
        }

        #if canImport(UIKit)
        guard backgroundTaskIdentifier == .invalid else { return }
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "CloudCode.ActiveRun") { [weak self] in
            Task { @MainActor [weak self] in
                self?.backgroundExecutionDidExpire()
            }
        }
        if backgroundTaskIdentifier == .invalid {
            let message = "系统未授予额外后台执行时间；90 分钟是 Cloud Code 的恢复窗口，不代表 iOS 会允许连续后台执行 90 分钟。恢复前不会盲目重放。"
            for sessionID in runningSessionIDs {
                sessionActivityLines[sessionID, default: []].append(message)
            }
            syncVisibleSessionState(session.id)
        }
        #endif
    }

    private func backgroundExecutionDidExpire() {
        endBackgroundExecutionIfNeeded()
        interruptActiveRunForBackground(reason: "iOS 已收回后台执行时间；当前任务已安全中断并保留检查点。由于你没有明确停止，回到可执行状态后会先核对检查点并自动继续。")
    }

    private func backgroundContinuationWindowDidElapse() {
        endBackgroundExecutionIfNeeded()
        interruptActiveRunForBackground(reason: "后台连续任务已达到 90 分钟保留上限；当前任务已安全中断并保留检查点，避免无限后台占用。回到前台后可从最近检查点继续。")
    }

    private func interruptActiveRunForBackground(reason: String) {
        guard isRunning else { return }
        let sessionIDs = Array(runningSessionIDs)
        for sessionID in sessionIDs {
            activeTasks[sessionID]?.cancel()
            activeTasks.removeValue(forKey: sessionID)
            activeRunTokens.removeValue(forKey: sessionID)
            activeConfigurations.removeValue(forKey: sessionID)
            runningSessionIDs.remove(sessionID)
            streamingAssistantMessageIDs.removeValue(forKey: sessionID)
            sessionActivityLines[sessionID, default: []].append(reason)
            Task {
                try? await diagnosticLogStore.log(level: .warning, subsystem: "app", action: "background-run-interrupt", result: "interrupted", sessionID: sessionID, diagnostic: reason)
            }
        }
        if sessionIDs.contains(session.id) { syncVisibleSessionState(session.id) }
    }

    private func resumeMostRecentInterruptedTaskIfRequested() {
        guard UserDefaults.standard.bool(forKey: Self.autoResumeTaskDefaultsKey) else { return }
        let automaticCandidates = interruptedTasks.filter {
            !runningSessionIDs.contains($0.sessionID) && $0.payload["resume.mode"] != "manual_provider_failure"
        }
        guard let checkpoint = automaticCandidates.first else {
            if runningSessionIDs.isEmpty { UserDefaults.standard.set(false, forKey: Self.autoResumeTaskDefaultsKey) }
            return
        }
        sessionActivityLines[checkpoint.sessionID, default: []].append("检测到未明确停止的中断任务；正在从最近检查点自动继续。")
        resumeTask(checkpoint)
    }

    private func clearAutoResumeIntentIfNoPendingTask() {
        guard runningSessionIDs.isEmpty, interruptedTasks.isEmpty else { return }
        UserDefaults.standard.set(false, forKey: Self.autoResumeTaskDefaultsKey)
    }

    private func endBackgroundExecutionIfNeeded() {
        backgroundWindowTask?.cancel()
        backgroundWindowTask = nil
        #if canImport(UIKit)
        guard backgroundTaskIdentifier != .invalid else { return }
        let identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
        #endif
    }

    public func createNewSession() {
        let newSession = AgentSession(
            permissionMode: permissionMode,
            providerID: selectedProviderID,
            keySlotID: selectedKeySlotID,
            model: selectedModel
        )
        session = newSession
        streamingAssistantMessageIDs.removeValue(forKey: newSession.id)
        activityLines = []
        lastError = nil
        UserDefaults.standard.set(newSession.id.uuidString, forKey: "session.current.id")
        // 空白新对话保持为内存态；只有真正发送第一条消息后才写入历史，避免反复新建产生大量空记录。
    }

    public func openSession(_ candidate: AgentSession) {
        if let live = liveSessions[candidate.id], runningSessionIDs.contains(candidate.id) {
            adoptSession(live)
            syncVisibleSessionState(candidate.id)
            return
        }
        Task {
            do {
                let loaded = try await sessionStore.load(candidate.id)
                adoptSession(loaded)
                syncVisibleSessionState(candidate.id)
                try await reloadSessionHistoryMergingLiveSessions()
            } catch {
                lastError = "打开旧对话失败：\(error)"
            }
        }
    }

    public func deleteSession(_ candidate: AgentSession) {
        guard !runningSessionIDs.contains(candidate.id) else {
            lastError = "这个对话仍在运行；请先停止该对话，再删除。"
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
                    streamingAssistantMessageIDs.removeValue(forKey: candidate.id)
                    activityLines = []
                    lastError = nil
                    UserDefaults.standard.set(replacement.id.uuidString, forKey: "session.current.id")
                } else {
                    try await sessionStore.delete(candidate.id)
                    try? attachmentStore.removeAll(for: candidate.id)
                }
                try await reloadSessionHistoryMergingLiveSessions()
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
        let sessionID = checkpoint.sessionID
        guard !runningSessionIDs.contains(sessionID) else { return }
        let operationKey = checkpointOperationKey(checkpoint.id)
        guard beginExclusiveOperation(operationKey) else { return }

        let runToken = UUID()
        runningSessionIDs.insert(sessionID)
        activeRunTokens[sessionID] = runToken
        sessionErrors.removeValue(forKey: sessionID)
        retryableProviderFailureSessionIDs.remove(sessionID)
        sessionActivityLines[sessionID, default: []].append("正在继续检查点 \(checkpoint.stepIndex)/\(checkpoint.totalSteps)…")
        UserDefaults.standard.set(true, forKey: Self.autoResumeTaskDefaultsKey)
        syncVisibleSessionState(sessionID)

        let task = Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                var resumedSession = try await sessionStore.load(sessionID)
                guard let request = checkpoint.payload["request"] ?? resumedSession.messages.last(where: { $0.role == .user })?.content,
                      !request.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let config = try ProviderCheckpointConfigurationResolver.resolve(
                    payload: checkpoint.payload,
                    profiles: providerProfiles
                )
                resumedSession.providerID = config.providerID
                resumedSession.model = config.model
                resumedSession.keySlotID = keySlotID(for: config) ?? resumedSession.keySlotID
                try await sessionStore.save(resumedSession)
                guard activeRunTokens[sessionID] == runToken else { return }
                activeConfigurations[sessionID] = config
                liveSessions[sessionID] = resumedSession
                upsertSessionHistory(resumedSession)
                syncVisibleSessionState(sessionID)

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
                for try await event in stream {
                    guard activeRunTokens[sessionID] == runToken else { break }
                    handleAgentEvent(event, sessionID: sessionID)
                }
                if activeRunTokens[sessionID] == runToken,
                   let saved = try? await sessionStore.load(sessionID) {
                    liveSessions[sessionID] = saved
                    upsertSessionHistory(saved)
                    streamingAssistantMessageIDs.removeValue(forKey: sessionID)
                    markProviderEndpointHealthy(config)
                    providerFailureSessionIDs.remove(sessionID)
                    retryableProviderFailureSessionIDs.remove(sessionID)
                    syncVisibleSessionState(sessionID)
                }
            } catch {
                if activeRunTokens[sessionID] == runToken {
                    if let config = activeConfigurations[sessionID] {
                        recordProviderFailure(error, configuration: config, sessionID: sessionID)
                    }
                    sessionErrors[sessionID] = Self.userFacingRunError(error)
                    syncVisibleSessionState(sessionID)
                }
            }

            finishSessionRun(sessionID: sessionID, runToken: runToken)
            await reloadActivity()
            clearAutoResumeIntentIfNoPendingTask()
            try? await reloadSessionHistoryMergingLiveSessions()
            refreshFilesFromDisk()
        }
        activeTasks[sessionID] = task
    }

    public func cancelInterruptedTask(_ checkpoint: TaskCheckpoint) {
        let key = checkpointOperationKey(checkpoint.id)
        guard beginExclusiveOperation(key) else { return }
        Task {
            defer { endExclusiveOperation(key) }
            do {
                try await checkpointStore.mark(checkpoint.id, state: "cancelled", stepName: "用户取消")
                await reloadActivity()
                clearAutoResumeIntentIfNoPendingTask()
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
                clearAutoResumeIntentIfNoPendingTask()
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

    public func reloadHermes(query: String = "") async {
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            hermesRecords = trimmed.isEmpty
                ? try await hermesStore.recent(limit: 500)
                : try await hermesStore.search(trimmed, limit: 500)
            hermesProjects = try await hermesStore.projects()
            hermesTags = try await hermesStore.allTags()
            hermesStatusMessage = "Hermes：\(hermesRecords.count) 条有效记忆"
        } catch {
            hermesStatusMessage = "Hermes 读取失败：\(error)"
        }
    }

    public func saveHermesMemory(
        id: UUID? = nil,
        kind: HermesMemoryKind,
        title: String,
        body: String,
        project: String?,
        tags: [String],
        pinned: Bool,
        expiresAt: Date? = nil
    ) {
        Task {
            do {
                let existing: HermesMemoryRecord?
                if let id {
                    existing = try await hermesStore.record(id)
                } else {
                    existing = nil
                }
                let record = HermesMemoryRecord(
                    id: id ?? UUID(),
                    kind: kind,
                    title: title,
                    body: body,
                    project: project,
                    tags: tags,
                    pinned: pinned,
                    createdAt: existing?.createdAt ?? Date(),
                    expiresAt: expiresAt,
                    sourcePath: existing?.sourcePath
                )
                _ = try await hermesStore.upsert(record)
                await reloadHermes()
            } catch {
                lastError = Self.userFacingRunError(error)
            }
        }
    }

    public func deleteHermesMemory(_ record: HermesMemoryRecord) {
        Task {
            do {
                try await hermesStore.delete(record.id)
                await reloadHermes()
            } catch {
                lastError = Self.userFacingRunError(error)
            }
        }
    }

    public func setHermesPinned(_ record: HermesMemoryRecord, pinned: Bool) {
        Task {
            do {
                try await hermesStore.setPinned(record.id, pinned: pinned)
                await reloadHermes()
            } catch {
                lastError = Self.userFacingRunError(error)
            }
        }
    }

    public func importHermesMarkdown(from url: URL) {
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try await hermesStore.importMarkdown(at: url)
                hermesStatusMessage = "已导入 \(count) 个 Markdown 记录"
                await reloadHermes()
            } catch {
                lastError = Self.userFacingRunError(error)
            }
        }
    }

    public func hermesExportMarkdown() async -> String {
        do {
            return try await hermesStore.combinedMarkdown()
        } catch {
            lastError = Self.userFacingRunError(error)
            return ""
        }
    }

    public func prepareHermesExportFile() async -> URL? {
        do {
            let directory = Self.supportRoot().appendingPathComponent("Hermes/Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Hermes-Export.md")
            try await hermesStore.exportCombinedMarkdown(to: url)
            return url
        } catch {
            lastError = Self.userFacingRunError(error)
            return nil
        }
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
        await refreshDiagnosticLogs()
    }

    public func refreshDiagnosticLogs() async {
        do {
            diagnosticLogs = Array((try await diagnosticLogStore.readAll(limit: 12_000)).reversed())
            diagnosticLogBytes = try await diagnosticLogStore.totalBytes()
        } catch {
            lastError = "诊断日志读取失败：\(error)"
        }
    }

    public func filteredDiagnosticLogs(
        query: String,
        sessionID: UUID?,
        toolCallID: UUID?,
        level: DiagnosticLogLevel?
    ) -> [DiagnosticLogRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return diagnosticLogs.filter { record in
            if let sessionID, record.sessionID != sessionID { return false }
            if let toolCallID, record.toolCallID != toolCallID { return false }
            if let level, record.level != level { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [
                record.subsystem,
                record.action,
                record.result,
                record.errorDomain ?? "",
                record.diagnostic ?? "",
                record.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            ].joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    public func diagnosticTextForAll(limit: Int = 1_500) async -> String {
        (try? await diagnosticLogStore.text(limit: limit)) ?? ""
    }

    public func diagnosticTextForMostRecentTask(limit: Int = 1_500) async -> String {
        do {
            let recent = try await diagnosticLogStore.readAll(limit: max(limit * 4, 4_000))
            let taskSessionID = recent.reversed().compactMap(\.sessionID).first ?? session.id
            return try await diagnosticLogStore.text(sessionID: taskSessionID, limit: limit)
        } catch {
            return ""
        }
    }

    public func exportDiagnosticBundle() async throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let capabilitiesData = try encoder.encode(capabilities)
        let runtime: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "activeSessionIDs": runningSessionIDs.map(\.uuidString).sorted(),
            "currentSessionID": session.id.uuidString,
            "providerID": selectedProviderID,
            "model": selectedModel,
            "permissionMode": permissionMode.rawValue,
            "localOnly": true
        ]
        let runtimeData = try JSONSerialization.data(withJSONObject: runtime, options: [.prettyPrinted, .sortedKeys])
        let auditData = try await auditStore.exportSnapshotData()
        let toolResultsData = try await executionLedger.exportSnapshotData()
        let checkpointData = try await checkpointStore.exportSnapshotData()
        let transactionData = try await transactionJournal.exportSnapshotData()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeDiagnostics", isDirectory: true)
        let url = try await diagnosticBundleExporter.export(
            destinationDirectory: destination,
            sources: diagnosticSourceFiles,
            generatedFiles: [
                "runtime/runtime.json": runtimeData,
                "capabilities/capabilities.json": capabilitiesData,
                "audit/audit.jsonl": auditData,
                "tool-results/tool-results.json": toolResultsData,
                "checkpoints/checkpoints.json": checkpointData,
                "transactions/transactions.json": transactionData
            ]
        )
        try? await diagnosticLogStore.log(
            level: .info,
            subsystem: "diagnostics",
            action: "export",
            result: "completed",
            metadata: ["filename": url.lastPathComponent]
        )
        return url
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
            try? await diagnosticLogStore.log(level: .info, subsystem: "provider-discovery", action: "discover", result: "started", metadata: ["label": trimmedLabel, "host": baseURL.host ?? ""])
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
                try? await diagnosticLogStore.log(level: .info, subsystem: "provider-discovery", action: "discover", result: "completed", metadata: ["label": trimmedLabel, "models": String(discovery.models.count)])
            } catch {
                try? keyVault.remove(reference)
                providerProfiles.removeAll { $0.id == providerID }
                try? await diagnosticLogStore.log(level: .error, subsystem: "provider-discovery", action: "discover", result: "failed", error: error, metadata: ["label": trimmedLabel])
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
        try await reloadSessionHistoryMergingLiveSessions()
    }

    private func reloadSessionHistoryMergingLiveSessions() async throws {
        let stored = try await sessionStore.all()
        var merged = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        for sessionID in runningSessionIDs {
            if let live = liveSessions[sessionID] {
                merged[sessionID] = live
            }
        }
        sessionHistory = merged.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func upsertSessionHistory(_ value: AgentSession) {
        if let index = sessionHistory.firstIndex(where: { $0.id == value.id }) {
            sessionHistory[index] = value
        } else {
            sessionHistory.append(value)
        }
        sessionHistory.sort { $0.updatedAt > $1.updatedAt }
    }

    private func adoptSession(_ loaded: AgentSession) {
        let visible = liveSessions[loaded.id] ?? loaded
        session = visible
        if !runningSessionIDs.contains(visible.id) {
            streamingAssistantMessageIDs.removeValue(forKey: visible.id)
        }
        permissionMode = visible.permissionMode
        let desired = ProviderSelectionState(
            providerID: visible.providerID ?? selectedProviderID,
            keySlotID: visible.keySlotID ?? selectedKeySlotID,
            model: visible.model ?? selectedModel
        )
        let reconciled = ProviderSelectionResolver.reconcile(desired, profiles: providerProfiles)
        applySelection(reconciled)
        session.providerID = reconciled.providerID
        session.keySlotID = reconciled.keySlotID
        session.model = reconciled.model
        activityLines = sessionActivityLines[visible.id] ?? []
        lastError = sessionErrors[visible.id]
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

    private static func userFacingRunError(_ error: Error) -> String {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .streamInterrupted:
                return "厂商输出连接已中断。检查点已保留，Cloud Code 不会自动重放已经开始的输出。可到“任务”中继续，或切换厂商。"
            case .malformedEvent:
                return "厂商返回的数据格式异常。详细信息已写入诊断日志；可以重试当前厂商或切换厂商。"
            case .transport:
                return "厂商传输异常。详细信息已写入诊断日志；可以检查网络后重试。"
            default:
                return providerError.description
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .cannotParseResponse:
                return "厂商连接返回了无法解析的响应（-1017）。已完成有界自动重试并释放运行状态；可以重试当前厂商或切换厂商。"
            case .timedOut:
                return "厂商请求超时。运行状态已释放，可以立即重试。"
            case .networkConnectionLost:
                return "厂商连接中断。运行状态已释放，可以立即重试。"
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "当前无法连接厂商接口。请检查网络后重试，或切换厂商。"
            default:
                return "厂商网络请求失败（\(nsError.code)）。详细信息已写入诊断日志。"
            }
        }
        return "任务失败。详细信息已写入诊断日志（\(nsError.domain) \(nsError.code)）。"
    }

    private static func isSafeProviderRetry(_ error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .rateLimited:
                return true
            case .invalidResponse(let code):
                return (500...599).contains(code)
            default:
                return false
            }
        }
        return ProviderRetryClassifier.isRetryableBeforeOutput(error)
    }

    private func providerEndpointHealthKey(_ configuration: ProviderConfiguration) -> String {
        configuration.providerID ?? configuration.baseURL.host ?? configuration.baseURL.absoluteString
    }

    private func markProviderEndpointHealthy(_ configuration: ProviderConfiguration) {
        providerEndpointHealth[providerEndpointHealthKey(configuration)] = ProviderEndpointHealth(state: .healthy)
    }

    private func recordProviderFailure(_ error: Error, configuration: ProviderConfiguration, sessionID: UUID) {
        providerFailureSessionIDs.insert(sessionID)
        if Self.isSafeProviderRetry(error) {
            retryableProviderFailureSessionIDs.insert(sessionID)
        } else {
            retryableProviderFailureSessionIDs.remove(sessionID)
        }
        if ProviderEndpointHealthClassifier.shouldMarkDegraded(error) {
            let nsError = error as NSError
            providerEndpointHealth[providerEndpointHealthKey(configuration)] = ProviderEndpointHealth(
                state: .degraded,
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )
        }
        Task {
            try? await diagnosticLogStore.log(
                level: .error,
                subsystem: "app.provider",
                action: "run.failure",
                result: "failed",
                sessionID: sessionID,
                error: error,
                metadata: [
                    "providerID": configuration.providerID ?? "",
                    "model": configuration.model,
                    "endpoint": (configuration.baseURL.host ?? "") + configuration.baseURL.path,
                    "retryAllowed": Self.isSafeProviderRetry(error) ? "true" : "false"
                ]
            )
        }
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

    private func handleAgentEvent(_ event: AgentEvent, sessionID: UUID) {
        var live = liveSessions[sessionID] ?? sessionHistory.first(where: { $0.id == sessionID }) ?? AgentSession(id: sessionID)
        switch event {
        case .status(let value):
            sessionActivityLines[sessionID, default: []].append(value)
        case .token(let token):
            if let messageID = streamingAssistantMessageIDs[sessionID],
               let assistantIndex = live.messages.firstIndex(where: { $0.id == messageID }) {
                live.messages[assistantIndex].content += token
                live.updatedAt = Date()
            } else {
                let message = ChatMessage(role: .assistant, content: token)
                live.messages.append(message)
                live.updatedAt = Date()
                streamingAssistantMessageIDs[sessionID] = message.id
            }
            liveSessions[sessionID] = live
            upsertSessionHistory(live)
        case .toolStarted(let name, _):
            streamingAssistantMessageIDs.removeValue(forKey: sessionID)
            sessionActivityLines[sessionID, default: []].append("工具：\(name)")
        case .toolFinished(let result):
            streamingAssistantMessageIDs.removeValue(forKey: sessionID)
            sessionActivityLines[sessionID, default: []].append("\(result.success ? "✓" : "✗") \(result.summary)")
        case .approvalRequired:
            break
        case .error(let value):
            sessionErrors[sessionID] = value
        case .finished:
            streamingAssistantMessageIDs.removeValue(forKey: sessionID)
        }
        syncVisibleSessionState(sessionID)
    }

    private func finishSessionRun(sessionID: UUID, runToken: UUID) {
        guard activeRunTokens[sessionID] == runToken else { return }
        activeTasks.removeValue(forKey: sessionID)
        activeRunTokens.removeValue(forKey: sessionID)
        activeConfigurations.removeValue(forKey: sessionID)
        runningSessionIDs.remove(sessionID)
        streamingAssistantMessageIDs.removeValue(forKey: sessionID)
        if runningSessionIDs.isEmpty {
            endBackgroundExecutionIfNeeded()
        }
        syncVisibleSessionState(sessionID)
    }

    private func syncVisibleSessionState(_ sessionID: UUID) {
        guard session.id == sessionID else { return }
        if let live = liveSessions[sessionID] {
            session = live
        }
        activityLines = sessionActivityLines[sessionID] ?? []
        lastError = sessionErrors[sessionID]
    }

    private static func supportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support")
        let root = base.appendingPathComponent("CloudCode", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
