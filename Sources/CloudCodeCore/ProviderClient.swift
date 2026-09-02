import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol APIKeyVault: Sendable {
    func key(for reference: String) async throws -> String
}

public actor MemoryKeyVault: APIKeyVault {
    private var keys: [String: String]
    public init(keys: [String: String] = [:]) { self.keys = keys }
    public func set(_ value: String, for reference: String) { keys[reference] = value }
    public func key(for reference: String) async throws -> String {
        guard let value = keys[reference], !value.isEmpty else { throw ProviderError.missingAPIKey }
        return value
    }
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case missingAPIKey
    case invalidEndpoint
    case invalidResponse(Int)
    case malformedEvent
    case transport(String)

    public var description: String {
        switch self {
        case .missingAPIKey: return "Provider API key is missing"
        case .invalidEndpoint: return "Provider endpoint is invalid"
        case .invalidResponse(let code): return "Provider returned HTTP \(code)"
        case .malformedEvent: return "Provider returned malformed streaming data"
        case .transport(let value): return value
        }
    }
}

public enum ProviderEvent: Sendable, Equatable {
    case token(String)
    case toolCall(id: String, name: String, argumentsJSON: String)
    case finished
}

public struct ProviderToolSchema: Sendable, Equatable {
    public var name: String
    public var description: String
    public var properties: [String: String]
    public var required: [String]

    public init(name: String, description: String, properties: [String: String] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
    }

    fileprivate var jsonObject: [String: Any] {
        var propertyObject: [String: Any] = [:]
        for (name, type) in properties {
            propertyObject[name] = ["type": type]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": propertyObject,
                    "required": required,
                    "additionalProperties": false
                ]
            ]
        ]
    }
}

public protocol ProviderStreaming: Sendable {
    func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

public struct OpenAICompatibleProviderClient: ProviderStreaming, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while attempt < 2 {
                    var responseStarted = false
                    do {
                        let request = try makeRequest(configuration: configuration, apiKey: apiKey, messages: messages, tools: tools)
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw ProviderError.transport("Missing HTTP response") }
                        guard (200..<300).contains(http.statusCode) else { throw ProviderError.invalidResponse(http.statusCode) }

                        var toolCallState: [Int: ToolCallAccumulator] = [:]
                        for try await line in bytes.lines {
                            if Task.isCancelled { throw CancellationError() }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let choices = object["choices"] as? [[String: Any]],
                                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

                            if let content = delta["content"] as? String, !content.isEmpty {
                                responseStarted = true
                                continuation.yield(.token(content))
                            }

                            if let toolCalls = delta["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                                responseStarted = true
                                for raw in toolCalls {
                                    let index = raw["index"] as? Int ?? 0
                                    var accumulator = toolCallState[index] ?? ToolCallAccumulator()
                                    if let id = raw["id"] as? String { accumulator.id = id }
                                    if let function = raw["function"] as? [String: Any] {
                                        if let name = function["name"] as? String { accumulator.name += name }
                                        if let arguments = function["arguments"] as? String { accumulator.arguments += arguments }
                                    }
                                    toolCallState[index] = accumulator
                                }
                            }
                        }

                        for index in toolCallState.keys.sorted() {
                            if let call = toolCallState[index], !call.name.isEmpty {
                                continuation.yield(.toolCall(id: call.id.isEmpty ? UUID().uuidString : call.id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments))
                            }
                        }
                        continuation.yield(.finished)
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        let mayReplay = !responseStarted && attempt == 0 && isRetryableBeforeOutput(error)
                        guard mayReplay else {
                            continuation.finish(throwing: error)
                            return
                        }
                        attempt += 1
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) throws -> URLRequest {
        let url: URL
        if configuration.baseURL.path.hasSuffix("/chat/completions") {
            url = configuration.baseURL
        } else {
            url = configuration.baseURL.appendingPathComponent("chat/completions")
        }
        guard url.scheme == "https" || url.host == "localhost" else { throw ProviderError.invalidEndpoint }

        var body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "messages": messages.map(providerMessageObject)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.jsonObject)
            body["tool_choice"] = "auto"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        return request
    }

    private func isRetryableBeforeOutput(_ error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .invalidResponse(let code): return (500...599).contains(code)
            case .transport: return true
            case .missingAPIKey, .invalidEndpoint, .malformedEvent: return false
            }
        }
        if error is URLError { return true }
        return false
    }

    private func providerMessageObject(_ message: ChatMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if message.role == .tool, let toolCallID = message.providerMetadata["tool_call_id"] {
            object["tool_call_id"] = toolCallID
            if let toolName = message.providerMetadata["tool_name"] { object["name"] = toolName }
        }
        if message.role == .assistant,
           let toolCallID = message.providerMetadata["tool_call_id"],
           let toolName = message.providerMetadata["tool_name"] {
            object["content"] = NSNull()
            object["tool_calls"] = [[
                "id": toolCallID,
                "type": "function",
                "function": [
                    "name": toolName,
                    "arguments": message.providerMetadata["tool_arguments"] ?? "{}"
                ]
            ]]
        }
        return object
    }
}

private struct ToolCallAccumulator: Sendable {
    var id = ""
    var name = ""
    var arguments = ""
}
