import Foundation

public enum AgentEvent: Sendable, Equatable {
    case status(String)
    case token(String)
    case toolStarted(name: String, id: UUID)
    case toolFinished(ToolResult)
    case approvalRequired(ApprovalPreview)
    case error(String)
    case finished
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var initialDelayNanoseconds: UInt64

    public init(maxAttempts: Int = 3, initialDelayNanoseconds: UInt64 = 500_000_000) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelayNanoseconds = initialDelayNanoseconds
    }
}

public actor SessionStore {
    private let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public func save(_ session: AgentSession) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(session.id.uuidString).appendingPathExtension("json")
        try JSONEncoder.pretty.encode(session).write(to: url, options: .atomic)
    }

    public func load(_ id: UUID) throws -> AgentSession {
        let url = root.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentSession.self, from: data)
    }

    public func all() throws -> [AgentSession] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(AgentSession.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

public actor TaskCheckpointStore {
    private let fileURL: URL
    private var checkpoints: [UUID: TaskCheckpoint] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([UUID: TaskCheckpoint].self, from: data) {
                checkpoints = decoded
            }
        }
    }

    public func upsert(_ checkpoint: TaskCheckpoint) throws {
        checkpoints[checkpoint.id] = checkpoint
        try persist()
    }

    public func interrupted() -> [TaskCheckpoint] {
        checkpoints.values.filter { !["completed", "cancelled", "rolled_back"].contains($0.state) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(_ id: UUID) throws {
        checkpoints.removeValue(forKey: id)
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(checkpoints).write(to: fileURL, options: .atomic)
    }
}

public actor ProgressiveResourceIndex {
    private var graph: ResourceGraph
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let value = try? decoder.decode(ResourceGraph.self, from: data) {
            graph = value
        } else {
            graph = ResourceGraph()
        }
    }

    public func snapshot() -> ResourceGraph { graph }

    public func seedLightweight(apps: [ResourceNode], capabilityProfile: CapabilityProfile) throws {
        for app in apps { graph.upsert(app) }
        graph.indexedAt = Date()
        try persist()
    }

    public func add(_ node: ResourceNode, deep: Bool = false) throws {
        graph.upsert(node)
        if deep { graph.deepIndexedResourceIDs.insert(node.id) }
        graph.indexedAt = Date()
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(graph).write(to: fileURL, options: .atomic)
    }
}

public actor AgentCore {
    private let provider: ProviderStreaming
    private let keyVault: APIKeyVault
    private let toolRouter: ToolRouter
    private let registry: ToolRegistry
    private let capabilityProbe: CapabilityProbing
    private let sessionStore: SessionStore
    private let checkpointStore: TaskCheckpointStore
    private let maxToolRounds: Int

    public init(
        provider: ProviderStreaming,
        keyVault: APIKeyVault,
        toolRouter: ToolRouter,
        registry: ToolRegistry,
        capabilityProbe: CapabilityProbing,
        sessionStore: SessionStore,
        checkpointStore: TaskCheckpointStore,
        maxToolRounds: Int = 8
    ) {
        self.provider = provider
        self.keyVault = keyVault
        self.toolRouter = toolRouter
        self.registry = registry
        self.capabilityProbe = capabilityProbe
        self.sessionStore = sessionStore
        self.checkpointStore = checkpointStore
        self.maxToolRounds = max(1, maxToolRounds)
    }

    public func send(
        text: String,
        inputSource: InputSource = .text,
        session initialSession: AgentSession,
        providerConfiguration: ProviderConfiguration,
        allowedRoot: URL? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var session = initialSession
                var checkpoint = TaskCheckpoint(sessionID: session.id, taskName: "Agent request", stepIndex: 0, stepName: "capability probe", totalSteps: maxToolRounds + 2, state: "running", payload: ["inputSource": inputSource.rawValue])
                do {
                    session.messages.append(ChatMessage(role: .user, content: text))
                    session.updatedAt = Date()
                    try await sessionStore.save(session)
                    try await checkpointStore.upsert(checkpoint)

                    continuation.yield(.status("Probing device capabilities…"))
                    var capabilities = await capabilityProbe.probe()
                    let key = try await keyVault.key(for: providerConfiguration.apiKeyReference)
                    let schemas = await makeToolSchemas()

                    for round in 0..<maxToolRounds {
                        checkpoint.stepIndex = round + 1
                        checkpoint.stepName = "agent round \(round + 1)"
                        checkpoint.updatedAt = Date()
                        try await checkpointStore.upsert(checkpoint)

                        continuation.yield(.status(round == 0 ? "Planning with Tool-first routing…" : "Continuing after tool result…"))
                        var assistantText = ""
                        var providerToolCalls: [(String, String, String)] = []

                        let stream = provider.stream(
                            configuration: providerConfiguration,
                            apiKey: key,
                            messages: session.messages,
                            tools: schemas
                        )

                        for try await event in stream {
                            switch event {
                            case .token(let token):
                                assistantText += token
                                continuation.yield(.token(token))
                            case .toolCall(let id, let name, let argumentsJSON):
                                providerToolCalls.append((id, name, argumentsJSON))
                            case .finished:
                                break
                            }
                        }

                        if providerToolCalls.isEmpty {
                            if !assistantText.isEmpty {
                                session.messages.append(ChatMessage(role: .assistant, content: assistantText))
                            }
                            session.updatedAt = Date()
                            try await sessionStore.save(session)
                            checkpoint.stepIndex = maxToolRounds + 1
                            checkpoint.stepName = "completed"
                            checkpoint.state = "completed"
                            checkpoint.updatedAt = Date()
                            try await checkpointStore.upsert(checkpoint)
                            continuation.yield(.finished)
                            continuation.finish()
                            return
                        }

                        for (providerCallID, name, argumentsJSON) in providerToolCalls {
                            session.messages.append(ChatMessage(
                                role: .assistant,
                                content: "",
                                providerMetadata: [
                                    "tool_call_id": providerCallID,
                                    "tool_name": name,
                                    "tool_arguments": argumentsJSON
                                ]
                            ))

                            let arguments = Self.stringDictionary(fromJSON: argumentsJSON)
                            let call = ToolCall(name: name, arguments: arguments, sessionID: session.id)
                            continuation.yield(.toolStarted(name: name, id: call.id))

                            let context = ToolExecutionContext(permissionMode: session.permissionMode, capabilityProfile: capabilities, allowedRoot: allowedRoot)
                            do {
                                let result = try await toolRouter.execute(call, context: context)
                                continuation.yield(.toolFinished(result))
                                let data = try JSONEncoder.pretty.encode(result)
                                let content = String(data: data, encoding: .utf8) ?? result.summary
                                session.messages.append(ChatMessage(role: .tool, content: content, providerMetadata: ["tool_call_id": providerCallID, "tool_name": name]))
                                if name == "capability.probe" { capabilities = await capabilityProbe.probe() }
                            } catch {
                                let failure = ToolResult(toolCallID: call.id, success: false, summary: String(describing: error), payload: ["error": String(describing: error)])
                                continuation.yield(.toolFinished(failure))
                                session.messages.append(ChatMessage(role: .tool, content: "Tool failed: \(error)", providerMetadata: ["tool_call_id": providerCallID, "tool_name": name]))
                            }
                            session.updatedAt = Date()
                            try await sessionStore.save(session)
                        }
                    }

                    throw ProviderError.transport("Agent exceeded the maximum of \(maxToolRounds) tool rounds")
                } catch is CancellationError {
                    checkpoint.state = "interrupted"
                    checkpoint.stepName = "cancelled by lifecycle"
                    checkpoint.updatedAt = Date()
                    try? await checkpointStore.upsert(checkpoint)
                    continuation.finish()
                } catch {
                    checkpoint.state = "interrupted"
                    checkpoint.stepName = "failed"
                    checkpoint.payload["error"] = String(describing: error)
                    checkpoint.updatedAt = Date()
                    try? await checkpointStore.upsert(checkpoint)
                    continuation.yield(.error(String(describing: error)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeToolSchemas() async -> [ProviderToolSchema] {
        let descriptors = await registry.all()
        return descriptors.map { descriptor in
            let properties: [String: String]
            switch descriptor.name {
            case "apps.inspect", "container.resolve", "apps.terminate", "apps.uninstall", "gui.openApp":
                properties = ["bundleId": "string"]
            case "files.list", "files.read", "storage.analyze", "ipa.inspect":
                properties = ["path": "string"]
            case "ipa.extract":
                properties = ["path": "string", "destination": "string"]
            case "files.search", "ipa.locate":
                properties = ["path": "string", "query": "string", "extension": "string"]
            case "files.modify", "files.create":
                properties = ["path": "string", "content": "string", "reason": "string"]
            case "files.delete":
                properties = ["path": "string", "reason": "string", "logicalResourceId": "string"]
            case "trash.restore", "trash.purge":
                properties = ["id": "string"]
            case "advanced.shell":
                properties = ["command": "string"]
            case "gui.tap":
                properties = ["x": "number", "y": "number"]
            case "gui.type":
                properties = ["text": "string"]
            case "gui.scroll":
                properties = ["dx": "number", "dy": "number"]
            case "gui.swipe":
                properties = ["fromX": "number", "fromY": "number", "toX": "number", "toY": "number", "duration": "number"]
            case "gui.verify":
                properties = ["assertion": "string"]
            default:
                properties = [:]
            }
            return ProviderToolSchema(name: descriptor.name, description: descriptor.summary, properties: properties, required: [])
        }
    }

    private static func stringDictionary(fromJSON json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var output: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String { output[key] = string }
            else if let number = value as? NSNumber { output[key] = number.stringValue }
            else if let nestedData = try? JSONSerialization.data(withJSONObject: value), let string = String(data: nestedData, encoding: .utf8) { output[key] = string }
        }
        return output
    }
}
