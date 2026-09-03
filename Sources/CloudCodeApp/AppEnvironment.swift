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
        let gui = GUIFallbackExecutor(backend: UnavailableGUIBackend())
        let executionLedger = ToolExecutionLedger(fileURL: support.appendingPathComponent("Execution/tool-results.json"))
        let router = ToolRouter(registry: registry, executors: [structured, cli, URLSchemeExecutor(), gui], executionLedger: executionLedger)
        let keyVault = KeychainAPIKeyVault()
        let sessions = SessionStore(root: support.appendingPathComponent("Sessions", isDirectory: true))
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
        self.customProviderFileURL = customProviderFileURL
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
                try await importBootstrapIfPresent()
                didBootstrap = true
            } catch {
                lastError = String(describing: error)
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
        return keyVault.contains(ProviderCatalog.keyReference(providerID: provider.id, keySlotID: selectedKeySlotID))
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
            lastError = "Provider/Key/secret is missing"
            return false
        }
        let reference = ProviderCatalog.keyReference(providerID: providerID, keySlotID: keySlotID)
        guard beginExclusiveOperation(Self.providerKeyMutationOperationKey) else {
            lastError = "Another Provider Key operation is already in progress."
            return false
        }
        defer { endExclusiveOperation(Self.providerKeyMutationOperationKey) }
        if let profile = providerProfiles.first(where: { $0.id == providerID }),
           let slot = profile.keySlots.first(where: { $0.id == keySlotID }),
           !slot.fingerprint.isEmpty,
           ProviderFingerprint.sha256(secret) != slot.fingerprint {
            lastError = "The Key does not match this desktop Key slot fingerprint. The existing Key was not changed."
            return false
        }
        do {
            try keyVault.set(secret, for: reference)
            return true
        } catch {
            lastError = "Keychain: \(error)"
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
            lastError = "Select a Provider, Key and Model first."
            return false
        }
        applySelection(reconciled)
        UserDefaults.standard.set(permissionMode.rawValue, forKey: "permission.mode")
        session.permissionMode = permissionMode
        return true
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard saveProviderSelection(), let config = currentProviderConfiguration() else {
            if lastError == nil { lastError = "Invalid Provider/Key/Model selection" }
            return
        }
        guard selectedKeyIsInstalled else {
            lastError = "The selected Key is not installed in iOS Keychain. Import the private bootstrap or add this Key locally."
            return
        }
        isRunning = true
        lastError = nil
        transcript += transcript.isEmpty ? "You: \(trimmed)\n\n" : "\nYou: \(trimmed)\n\n"
        activityLines.append("Planning request with \(config.name) / \(config.model)…")

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

    public func suspendForBackground() {
        guard isRunning || currentTask != nil else { return }
        currentTask?.cancel()
        currentTask = nil
        runGeneration.cancel()
        isRunning = false
        activityLines.append("App entered background; active task was interrupted instead of being blindly replayed. Resume is available after checkpoint reconciliation.")
    }

    public func refreshAfterForeground() {
        Task {
            await reloadActivity()
            refreshFilesFromDisk()
        }
        refreshCapabilities()
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
                let config = try ProviderCheckpointConfigurationResolver.resolve(
                    payload: checkpoint.payload,
                    profiles: providerProfiles
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
            lastError = "Another Provider Key operation is already in progress."
            return
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty,
              let baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProviderEndpointPolicy.allowsBaseURL(baseURL),
              !apiKey.isEmpty else {
            endExclusiveOperation(operationKey)
            lastError = "Custom Provider requires a label, HTTPS Base URL and API Key."
            return
        }
        let providerID = "custom-\(UUID().uuidString.lowercased())"
        let slotID = "slot-1"
        let reference = ProviderCatalog.keyReference(providerID: providerID, keySlotID: slotID)
        let fingerprint = ProviderFingerprint.sha256(apiKey)
        activityLines.append("Discovering models and protocol for \(trimmedLabel)…")
        Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                let discovery = try await ProviderDiscoveryClient().discover(baseURL: baseURL, apiKey: apiKey)
                guard !discovery.models.isEmpty, let preferred = discovery.protocols.first else {
                    lastError = "Provider discovery could not verify an inference protocol."
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
                activityLines.append("Custom Provider ready: \(trimmedLabel) (\(discovery.models.count) models).")
            } catch {
                try? keyVault.remove(reference)
                providerProfiles.removeAll { $0.id == providerID }
                lastError = "Custom Provider setup failed: \(error)"
            }
        }
    }

    public func importProviderBootstrap(from url: URL) {
        let operationKey = Self.providerKeyMutationOperationKey
        guard beginExclusiveOperation(operationKey) else {
            lastError = "Another Provider Key operation is already in progress."
            return
        }
        Task {
            defer { endExclusiveOperation(operationKey) }
            do {
                let count = try await importProviderBootstrapNow(from: url, removeSource: true)
                activityLines.append("Imported \(count) Provider Key(s) into Keychain; bootstrap plaintext removed.")
            } catch {
                lastError = "Private bootstrap import failed: \(error)"
            }
        }
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
            throw ProviderError.transport("Another Provider Key operation is already in progress")
        }
        defer { endExclusiveOperation(operationKey) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = documents?.appendingPathComponent("CloudCode-Provider-Bootstrap.json"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let count = try await importProviderBootstrapNow(from: url, removeSource: true)
        activityLines.append("Private bootstrap imported automatically: \(count) Key(s).")
    }

    private func importProviderBootstrapNow(from url: URL, removeSource: Bool) async throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data = try Data(contentsOf: url, options: [.mappedIfSafe])
        defer { data.resetBytes(in: 0..<data.count) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ProviderBootstrapPayload.self, from: data)
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
