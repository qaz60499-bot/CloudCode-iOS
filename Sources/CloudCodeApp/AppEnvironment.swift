import Foundation
import SwiftUI
import CloudCodeCore

@MainActor
public final class CloudCodeViewModel: ObservableObject {
    @Published public var session: AgentSession
    @Published public var transcript: String = ""
    @Published public var activityLines: [String] = []
    @Published public var capabilities = CapabilityProfile(records: [])
    @Published public var capabilityGraph = CapabilityGraph()
    @Published public var apps: [ResourceNode] = []
    @Published public var files: [FileEntry] = []
    @Published public var trash: [TrashRecord] = []
    @Published public var auditEvents: [AuditEvent] = []
    @Published public var interruptedTasks: [TaskCheckpoint] = []
    @Published public var isRunning = false
    @Published public var lastError: String?
    @Published public private(set) var inFlightOperationKeys: Set<String> = []

    @Published public var providerName: String
    @Published public var providerBaseURL: String
    @Published public var providerModel: String
    @Published public var providerAPIKey: String = ""
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
    private let keyVault: KeychainAPIKeyVault
    private let agentCore: AgentCore
    private let resourceIndex: ProgressiveResourceIndex
    private let appKnowledge: AppKnowledgeRegistry
    private var currentTask: Task<Void, Never>?
    private var runGeneration = RunGenerationGuard()
    private var bootstrapTask: Task<Void, Never>?
    private var capabilityRefreshTask: Task<Void, Never>?
    private var didBootstrap = false

    private static let keyReference = "primary-provider"

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
        let gui = GUIFallbackExecutor(backend: UnavailableGUIBackend())
        let executionLedger = ToolExecutionLedger(fileURL: support.appendingPathComponent("Execution/tool-results.json"))
        let router = ToolRouter(registry: registry, executors: [structured, cli, URLSchemeExecutor(), gui], executionLedger: executionLedger)
        let keyVault = KeychainAPIKeyVault()
        let sessions = SessionStore(root: support.appendingPathComponent("Sessions", isDirectory: true))
        let checkpoints = TaskCheckpointStore(fileURL: support.appendingPathComponent("Tasks/checkpoints.json"))
        let provider = OpenAICompatibleProviderClient()
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
        self.providerName = defaults.string(forKey: "provider.name") ?? "OpenAI-compatible"
        self.providerBaseURL = defaults.string(forKey: "provider.baseURL") ?? "https://api.openai.com/v1"
        self.providerModel = defaults.string(forKey: "provider.model") ?? "gpt-5.1"
        self.permissionMode = initialPermissionMode
        self.browsePath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
        self.session = AgentSession(permissionMode: initialPermissionMode)
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
        self.keyVault = keyVault
        self.agentCore = agent
        self.resourceIndex = ProgressiveResourceIndex(fileURL: support.appendingPathComponent("Index/resource-graph.json"))
        self.appKnowledge = AppKnowledgeRegistry(fileURL: support.appendingPathComponent("Index/app-knowledge.json"))
    }

    public func bootstrap() {
        guard !didBootstrap, bootstrapTask == nil else { return }
        bootstrapTask = Task {
            defer { bootstrapTask = nil }
            capabilities = await capabilityProbe.probe()
            capabilityGraph = CapabilityGraphBuilder().build(profile: capabilities, tools: await toolRegistry.all())
            apps = await appResolver.installedApps()
            await seedKnowledgeIfNeeded(apps)
            do {
                try await checkpointStore.recoverUnfinishedAfterRestart()
                let recoveredTransactions = try await transactionEngine.recoverInterruptedTransactions()
                if !recoveredTransactions.isEmpty {
                    activityLines.append("Recovered \(recoveredTransactions.count) interrupted transaction(s) to a terminal state.")
                }
                try await resourceIndex.seedLightweight(apps: apps, capabilityProfile: capabilities)
                trash = try await trashService.records()
                auditEvents = Array((try await auditStore.readAll()).suffix(200).reversed())
                interruptedTasks = await checkpointStore.interrupted()
                try refreshFiles()
                didBootstrap = true
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    @discardableResult
    public func saveProvider() -> Bool {
        if !providerAPIKey.isEmpty {
            do {
                try keyVault.set(providerAPIKey, for: Self.keyReference)
            } catch {
                lastError = "Keychain: \(error)"
                return false
            }
        }

        let defaults = UserDefaults.standard
        defaults.set(providerName, forKey: "provider.name")
        defaults.set(providerBaseURL, forKey: "provider.baseURL")
        defaults.set(providerModel, forKey: "provider.model")
        defaults.set(permissionMode.rawValue, forKey: "permission.mode")
        session.permissionMode = permissionMode
        providerAPIKey = ""
        return true
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard let baseURL = URL(string: providerBaseURL), !providerModel.isEmpty else {
            lastError = "Invalid provider URL/model"
            return
        }
        guard saveProvider() else { return }
        isRunning = true
        lastError = nil
        transcript += transcript.isEmpty ? "You: \(trimmed)\n\n" : "\nYou: \(trimmed)\n\n"
        activityLines.append("Planning request…")

        let config = ProviderConfiguration(name: providerName, baseURL: baseURL, model: providerModel, apiKeyReference: Self.keyReference)
        let allowedRoot: URL? = capabilities.isAvailable("filesystem.unrestricted") ? nil : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        currentTask?.cancel()
        let runID = runGeneration.start()
        currentTask = Task {
            let stream = await agentCore.send(text: trimmed, session: session, providerConfiguration: config, allowedRoot: allowedRoot)
            do {
                var assistantStarted = false
                for try await event in stream {
                    guard runGeneration.isCurrent(runID) else { break }
                    switch event {
                    case .status(let value):
                        activityLines.append(value)
                    case .token(let token):
                        if !assistantStarted {
                            transcript += "Assistant: "
                            assistantStarted = true
                        }
                        transcript += token
                    case .toolStarted(let name, _):
                        activityLines.append("Tool: \(name)")
                    case .toolFinished(let result):
                        activityLines.append("\(result.success ? "✓" : "✗") \(result.summary)")
                    case .approvalRequired:
                        break
                    case .error(let value):
                        lastError = value
                    case .finished:
                        transcript += "\n"
                    }
                }
                if runGeneration.isCurrent(runID),
                   let saved = try? await sessionStore.load(session.id) { session = saved }
            } catch {
                if runGeneration.isCurrent(runID) { lastError = String(describing: error) }
            }
            if runGeneration.finish(runID) {
                currentTask = nil
                isRunning = false
            }
            await reloadActivity()
            refreshFilesFromDisk()
        }
    }

    public func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        runGeneration.cancel()
        isRunning = false
        activityLines.append("Task interrupted; checkpoint retained for resume/rollback inspection.")
    }

    public func resumeTask(_ checkpoint: TaskCheckpoint) {
        guard !isRunning else { return }
        let operationKey = checkpointOperationKey(checkpoint.id)
        guard beginExclusiveOperation(operationKey) else { return }
        currentTask?.cancel()
        let runID = runGeneration.start()
        isRunning = true
        lastError = nil
        activityLines.append("Resuming checkpoint \(checkpoint.stepIndex)/\(checkpoint.totalSteps)…")

        currentTask = Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                var resumedSession = try await sessionStore.load(checkpoint.sessionID)
                resumedSession.permissionMode = permissionMode
                try await sessionStore.save(resumedSession)
                guard let request = checkpoint.payload["request"] ?? resumedSession.messages.last(where: { $0.role == .user })?.content,
                      !request.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard let baseURL = URL(string: checkpoint.payload["provider.baseURL"] ?? providerBaseURL) else {
                    throw ProviderError.invalidEndpoint
                }
                let config = ProviderConfiguration(
                    name: checkpoint.payload["provider.name"] ?? providerName,
                    baseURL: baseURL,
                    model: checkpoint.payload["provider.model"] ?? providerModel,
                    apiKeyReference: Self.keyReference
                )
                session = resumedSession
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
                   let saved = try? await sessionStore.load(checkpoint.sessionID) { session = saved }
            } catch {
                if runGeneration.isCurrent(runID) { lastError = String(describing: error) }
            }
            if runGeneration.finish(runID) {
                currentTask = nil
                isRunning = false
            }
            await reloadActivity()
            refreshFilesFromDisk()
        }
    }

    public func cancelInterruptedTask(_ checkpoint: TaskCheckpoint) {
        let key = checkpointOperationKey(checkpoint.id)
        guard beginExclusiveOperation(key) else { return }
        Task {
            defer { endExclusiveOperation(key) }
            do {
                try await checkpointStore.mark(checkpoint.id, state: "cancelled", stepName: "cancelled by user")
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
                try await checkpointStore.mark(checkpoint.id, state: "rolled_back", stepName: "latest committed transaction rolled back")
                await reloadActivity()
                refreshFilesFromDisk()
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    public func refreshCapabilities() {
        guard bootstrapTask == nil, capabilityRefreshTask == nil else { return }
        capabilityRefreshTask = Task {
            defer { capabilityRefreshTask = nil }
            capabilities = await capabilityProbe.probe()
            capabilityGraph = CapabilityGraphBuilder().build(profile: capabilities, tools: await toolRegistry.all())
            apps = await appResolver.installedApps()
            try? await resourceIndex.seedLightweight(apps: apps, capabilityProfile: capabilities)
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
            lastError = "Trash state could not be refreshed: \(error)"
        }
        do {
            auditEvents = Array((try await auditStore.readAll()).suffix(200).reversed())
        } catch {
            lastError = "Audit state could not be refreshed: \(error)"
        }
        interruptedTasks = await checkpointStore.interrupted()
    }

    public func restoreTrash(_ record: TrashRecord) {
        let key = trashOperationKey(record.id)
        guard beginExclusiveOperation(key) else { return }
        Task {
            defer { endExclusiveOperation(key) }
            do {
                _ = try await trashService.restore(record.id)
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
            let preview = ApprovalPreview(title: "Permanently delete Trash item", target: record.originalPath, originalSummary: "\(record.size) bytes", reason: "Permanent deletion cannot be rolled back", plan: ["Quarantine Trash payload", "Update journal", "Delete quarantined payload"], risk: .permanentDestructive)
            let approved: Bool
            if permissionMode == .full {
                approved = true
            } else {
                approved = await approvalCenter.requestApproval(preview)
            }
            guard approved else { return }
            do {
                try await trashService.permanentlyDelete(record.id)
                await reloadActivity()
                refreshFilesFromDisk()
            } catch { lastError = String(describing: error) }
        }
    }

    private func refreshFilesFromDisk() {
        do {
            try refreshFiles()
        } catch {
            lastError = "File view could not be refreshed: \(error)"
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

    private func consume(_ stream: AsyncThrowingStream<AgentEvent, Error>, runID: UUID) async throws {
        var assistantStarted = false
        for try await event in stream {
            guard runGeneration.isCurrent(runID) else { break }
            switch event {
            case .status(let value):
                activityLines.append(value)
            case .token(let token):
                if !assistantStarted {
                    transcript += transcript.isEmpty ? "Assistant: " : "\nAssistant: "
                    assistantStarted = true
                }
                transcript += token
            case .toolStarted(let name, _):
                activityLines.append("Tool: \(name)")
            case .toolFinished(let result):
                activityLines.append("\(result.success ? "✓" : "✗") \(result.summary)")
            case .approvalRequired:
                break
            case .error(let value):
                lastError = value
            case .finished:
                if assistantStarted { transcript += "\n" }
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
