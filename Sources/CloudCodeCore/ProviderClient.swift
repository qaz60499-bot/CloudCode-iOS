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
    case authenticationFailed(Int)
    case rateLimited
    case invalidResponse(Int)
    case malformedEvent
    case transport(String)

    public var description: String {
        switch self {
        case .missingAPIKey: return "Provider API key is missing"
        case .invalidEndpoint: return "Provider endpoint is invalid"
        case .authenticationFailed(let code): return "Provider authentication failed (HTTP \(code)); update the API key in Settings"
        case .rateLimited: return "Provider rate limit exceeded; retry later"
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
    private let retryPolicy: RetryPolicy

    public init(session: URLSession = .shared, retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 2, initialDelayNanoseconds: 1_500_000_000)) {
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 1
                while attempt <= retryPolicy.maxAttempts {
                    var responseStarted = false
                    do {
                        let request = try makeRequest(configuration: configuration, apiKey: apiKey, messages: messages, tools: tools)
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw ProviderError.transport("Missing HTTP response") }
                        if let statusError = ProviderHTTPClassifier.error(for: http.statusCode) {
                            throw statusError
                        }

                        var toolCallState: [Int: ToolCallAccumulator] = [:]
                        var sawValidStreamEvent = false
                        for try await line in bytes.lines {
                            if Task.isCancelled { throw CancellationError() }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" {
                                sawValidStreamEvent = true
                                break
                            }
                            guard let data = payload.data(using: .utf8),
                                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let choices = object["choices"] as? [[String: Any]],
                                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
                            sawValidStreamEvent = true

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

                        guard sawValidStreamEvent else { throw ProviderError.malformedEvent }

                        for index in toolCallState.keys.sorted() {
                            if let call = toolCallState[index], !call.name.isEmpty {
                                guard !call.id.isEmpty else { throw ProviderError.malformedEvent }
                                continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments))
                            }
                        }
                        continuation.yield(.finished)
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        let mayReplay = !responseStarted && attempt < retryPolicy.maxAttempts && ProviderRetryClassifier.isRetryableBeforeOutput(error)
                        guard mayReplay else {
                            continuation.finish(throwing: error)
                            return
                        }
                        let shift = UInt64(min(max(attempt - 1, 0), 8))
                        let multiplier = UInt64(1) << shift
                        let (delay, overflow) = retryPolicy.initialDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
                        attempt += 1
                        do {
                            try await Task.sleep(nanoseconds: overflow ? UInt64.max / 4 : delay)
                        } catch {
                            continuation.finish()
                            return
                        }
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

public enum ProviderHTTPClassifier {
    public static func error(for statusCode: Int) -> ProviderError? {
        switch statusCode {
        case 200..<300: return nil
        case 401, 403: return .authenticationFailed(statusCode)
        case 429: return .rateLimited
        default: return .invalidResponse(statusCode)
        }
    }
}

public enum ProviderRetryClassifier {
    public static func isRetryableBeforeOutput(_ error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .rateLimited:
                return true
            case .invalidResponse(let code):
                return (500...599).contains(code)
            case .transport:
                return false
            case .missingAPIKey, .invalidEndpoint, .authenticationFailed, .malformedEvent:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff,
             .dataNotAllowed, .cannotLoadFromNetwork:
            return true
        case .timedOut, .networkConnectionLost, .callIsActive:
            return false
        case .cancelled, .badURL, .unsupportedURL, .userAuthenticationRequired,
             .userCancelledAuthentication, .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return false
        default:
            return false
        }
    }
}

private struct ToolCallAccumulator: Sendable {
    var id = ""
    var name = ""
    var arguments = ""
}
