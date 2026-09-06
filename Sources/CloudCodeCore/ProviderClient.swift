import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderEndpointPolicy {
    public static func allowsBaseURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else { return false }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
        return !loopbackHosts.contains(host)
    }
}

public enum ProviderRedirectPolicy {
    public static func allows(original: URL, destination: URL) -> Bool {
        guard let originalScheme = original.scheme?.lowercased(),
              let destinationScheme = destination.scheme?.lowercased(),
              let originalHost = original.host?.lowercased(),
              let destinationHost = destination.host?.lowercased() else { return false }
        return originalScheme == destinationScheme
            && originalHost == destinationHost
            && effectivePort(original) == effectivePort(destination)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

private final class ProviderSameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let destination = request.url,
              ProviderRedirectPolicy.allows(original: original, destination: destination) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private final class ProviderStreamingTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var responseResolved = false
    private var lineBuffer = Data()
    private var receivedBodyData = false
    private var task: URLSessionDataTask?
    private var ownedSession: URLSession?
    private let lineStream: AsyncThrowingStream<String, Error>
    private let lineContinuation: AsyncThrowingStream<String, Error>.Continuation

    private static func makeLineStream() -> (AsyncThrowingStream<String, Error>, AsyncThrowingStream<String, Error>.Continuation) {
        var captured: AsyncThrowingStream<String, Error>.Continuation!
        let stream = AsyncThrowingStream<String, Error> { continuation in
            captured = continuation
        }
        return (stream, captured)
    }

    init(configuration: URLSessionConfiguration, request: URLRequest) {
        self.configuration = configuration
        self.request = request
        let pair = Self.makeLineStream()
        self.lineStream = pair.0
        self.lineContinuation = pair.1
        super.init()
    }

    func start() async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let dataTask = session.dataTask(with: request)
        ownedSession = session
        task = dataTask

        let response = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                responseContinuation = continuation
                lock.unlock()
                dataTask.resume()
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
        return (response, lineStream)
    }

    func hasReceivedBodyData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedBodyData
    }

    private func cancel() {
        lock.lock()
        let activeTask = task
        let session = ownedSession
        lock.unlock()
        activeTask?.cancel()
        session?.invalidateAndCancel()
    }

    private func resolveResponse(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard !responseResolved else {
            lock.unlock()
            return
        }
        responseResolved = true
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let destination = request.url,
              ProviderRedirectPolicy.allows(original: original, destination: destination) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            resolveResponse(.failure(ProviderError.transport("缺少 HTTP 响应")))
            completionHandler(.cancel)
            return
        }
        resolveResponse(.success(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        receivedBodyData = true
        lock.unlock()
        lineBuffer.append(data)
        if lineBuffer.count > 1_048_576 && !lineBuffer.contains(0x0A) {
            lineContinuation.finish(throwing: ProviderError.transport("厂商流单行超过 1 MB，已中止"))
            dataTask.cancel()
            return
        }
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            if lineData.last == 0x0D { lineData.removeLast() }
            guard let line = String(data: lineData, encoding: .utf8) else {
                lineContinuation.finish(throwing: ProviderError.malformedEvent)
                dataTask.cancel()
                return
            }
            lineContinuation.yield(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !lineBuffer.isEmpty {
            var trailing = lineBuffer
            lineBuffer.removeAll(keepingCapacity: false)
            if trailing.last == 0x0D { trailing.removeLast() }
            if let line = String(data: trailing, encoding: .utf8) {
                lineContinuation.yield(line)
            } else {
                lineContinuation.finish(throwing: ProviderError.malformedEvent)
            }
        }

        if let error {
            resolveResponse(.failure(error))
            lineContinuation.finish(throwing: error)
        } else {
            if !responseResolved {
                resolveResponse(.failure(ProviderError.transport("连接结束但未收到 HTTP 响应")))
            }
            lineContinuation.finish()
        }

        lock.lock()
        self.task = nil
        let ownedSession = self.ownedSession
        self.ownedSession = nil
        lock.unlock()
        ownedSession?.finishTasksAndInvalidate()
    }
}

public enum ProviderURLSessionFactory {
    public static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 90 * 60
        return URLSession(configuration: configuration, delegate: ProviderSameOriginRedirectDelegate(), delegateQueue: nil)
    }
}

public protocol APIKeyVault: Sendable {
    func key(for reference: String) async throws -> String
}

public actor MemoryKeyVault: APIKeyVault {
    private var keys: [String: String]
    public init(keys: [String: String] = [:]) { self.keys = keys }
    public func set(_ value: String, for reference: String) { keys[reference] = value }
    public func remove(_ reference: String) { keys.removeValue(forKey: reference) }
    public func key(for reference: String) async throws -> String {
        guard let value = keys[reference], !value.isEmpty else { throw ProviderError.missingAPIKey }
        return value
    }
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case missingAPIKey
    case invalidEndpoint
    case authenticationFailed(Int)
    case clientRejected(Int)
    case capacityExhausted(Int)
    case rateLimited
    case modelUnavailable(Int)
    case invalidResponse(Int)
    case malformedEvent
    case streamInterrupted
    case attachmentUnavailable(String)
    case attachmentTooLarge(Int64)
    case unsupportedAttachmentType(String)
    case protocolIncompatible(String)
    case transport(String)

    public var description: String {
        switch self {
        case .missingAPIKey: return "厂商 API Key 缺失"
        case .invalidEndpoint: return "厂商接口地址无效"
        case .authenticationFailed(let code): return "厂商返回认证拒绝（HTTP \(code)）。请核对当前协议、接口地址、鉴权方式和 Key；不能仅凭该状态判定 Key 本身无效。"
        case .clientRejected(let code): return "厂商网关拒绝当前客户端类型（HTTP \(code)），请求尚未证明 Key 无效；这属于客户端/网关兼容限制，不会把 Key 标记为失效。"
        case .capacityExhausted(let code): return "当前厂商 Key 的额度 / 容量不足（HTTP \(code)）；可选择同一厂商内的其他 Key"
        case .rateLimited: return "厂商触发限流，请稍后重试"
        case .modelUnavailable(let code): return "当前模型在该厂商没有可用推理通道（HTTP \(code)）；Key 未被判定失效，请切换模型或厂商后重试。"
        case .invalidResponse(let code):
            if (500...599).contains(code) {
                return "上游厂商服务暂时不可用（HTTP \(code)）；这不是设备权限或卸载链路错误"
            }
            if code == 404 || code == 405 {
                return "厂商接口路径或协议不匹配（HTTP \(code)）。这不等于厂商不可用；请核对当前模型对应的 API 协议和 endpoint。"
            }
            return "厂商返回 HTTP \(code)"
        case .malformedEvent: return "厂商返回了格式错误的流数据"
        case .streamInterrupted: return "厂商流在完成事件前中断"
        case .attachmentUnavailable(let filename): return "图片附件无法读取：\(filename)"
        case .attachmentTooLarge(let bytes): return "图片附件过大（\(bytes) 字节）；单张图片限制为 4 MB"
        case .unsupportedAttachmentType(let mimeType): return "暂不支持的图片类型：\(mimeType)"
        case .protocolIncompatible(let detail): return "当前模型的兼容协议返回错误：\(detail)"
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

    fileprivate var parametersObject: [String: Any] {
        var propertyObject: [String: Any] = [:]
        for (name, type) in properties {
            propertyObject[name] = ["type": type]
        }
        return [
            "type": "object",
            "properties": propertyObject,
            "required": required,
            "additionalProperties": false
        ]
    }

    fileprivate var openAIChatObject: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parametersObject
            ]
        ]
    }

    fileprivate var openAIResponsesObject: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": parametersObject
        ]
    }

    fileprivate var anthropicObject: [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": parametersObject
        ]
    }
}

public enum ProviderToolNameMapError: Error, Equatable, CustomStringConvertible {
    case emptyInternalName
    case invalidInternalName(String)
    case encodedNameTooLong(String)
    case invalidProviderName(String)
    case duplicateInternalName(String)
    case collision(providerName: String, firstInternalName: String, secondInternalName: String)

    public var description: String {
        switch self {
        case .emptyInternalName: return "内部工具 ID 不能为空"
        case .invalidInternalName(let name): return "内部工具 ID 含有不受支持的字符：\(name)"
        case .encodedNameTooLong(let name): return "工具 ID 编码后的厂商名称超过 64 字符：\(name)"
        case .invalidProviderName(let name): return "生成了厂商不接受的工具名称：\(name)"
        case .duplicateInternalName(let name): return "发现重复内部工具 ID：\(name)"
        case .collision(let providerName, let first, let second): return "工具名称映射冲突：\(first) / \(second) → \(providerName)"
        }
    }
}

/// Internal Tool ID ↔ provider-safe function name mapping.
/// `.` becomes `_`, literal `_` becomes `-u-`, and literal `-` becomes `-h-`,
/// so common names stay readable (`files.read` → `files_read`) while the transform
/// is prefix-unambiguous, deterministic, reversible and collision-safe. Internal
/// IDs outside `[A-Za-z0-9._-]` fail closed.
public struct ProviderToolNameMap: Sendable, Equatable {
    public let internalToProvider: [String: String]
    public let providerToInternal: [String: String]

    public init(internalNames: [String]) throws {
        var forward: [String: String] = [:]
        var reverse: [String: String] = [:]
        for internalName in internalNames.sorted() {
            guard forward[internalName] == nil else { throw ProviderToolNameMapError.duplicateInternalName(internalName) }
            let providerName = try Self.encode(internalName)
            if let existing = reverse[providerName], existing != internalName {
                throw ProviderToolNameMapError.collision(providerName: providerName, firstInternalName: existing, secondInternalName: internalName)
            }
            guard try Self.decode(providerName) == internalName else { throw ProviderToolNameMapError.invalidProviderName(providerName) }
            forward[internalName] = providerName
            reverse[providerName] = internalName
        }
        internalToProvider = forward
        providerToInternal = reverse
    }

    public func providerName(forInternalName name: String) -> String? { internalToProvider[name] }
    public func internalName(forProviderName name: String) -> String? { providerToInternal[name] }

    public static func encode(_ internalName: String) throws -> String {
        guard !internalName.isEmpty else { throw ProviderToolNameMapError.emptyInternalName }
        var output = ""
        for byte in internalName.utf8 {
            switch byte {
            case 48...57, 65...90, 97...122:
                output.append(Character(UnicodeScalar(Int(byte))!))
            case 46:
                output += "_"
            case 95:
                output += "-u-"
            case 45:
                output += "-h-"
            default:
                throw ProviderToolNameMapError.invalidInternalName(internalName)
            }
        }
        guard output.count <= 64 else { throw ProviderToolNameMapError.encodedNameTooLong(internalName) }
        guard isProviderSafe(output) else { throw ProviderToolNameMapError.invalidProviderName(output) }
        return output
    }

    public static func decode(_ providerName: String) throws -> String {
        guard isProviderSafe(providerName), !providerName.isEmpty else { throw ProviderToolNameMapError.invalidProviderName(providerName) }
        let bytes = Array(providerName.utf8)
        var decoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 95 {
                decoded.append(46)
                index += 1
                continue
            }
            if byte == 45 {
                guard index + 2 < bytes.count, bytes[index + 2] == 45 else {
                    throw ProviderToolNameMapError.invalidProviderName(providerName)
                }
                switch bytes[index + 1] {
                case 117: decoded.append(95)
                case 104: decoded.append(45)
                default: throw ProviderToolNameMapError.invalidProviderName(providerName)
                }
                index += 3
                continue
            }
            decoded.append(byte)
            index += 1
        }
        guard let result = String(bytes: decoded, encoding: .utf8), !result.isEmpty else {
            throw ProviderToolNameMapError.invalidProviderName(providerName)
        }
        return result
    }

    public static func isProviderSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
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

private protocol ProviderRequestBuilding {
    var session: URLSession { get }
    var retryPolicy: RetryPolicy { get }
    var diagnosticLogger: DiagnosticLogStore? { get }
    func makeRequest(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) throws -> URLRequest
    func consume(lines: AsyncThrowingStream<String, Error>, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation) async throws -> Bool
}

private extension ProviderRequestBuilding {
    func requestStream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 1
                var requestConfiguration = configuration
                var requestMessages = messages
                var requestTools = tools
                var didDropReasoningEffortForCompatibility = false
                var didCompactContextForGatewayRecovery = false
                while attempt <= retryPolicy.maxAttempts {
                    var responseStarted = false
                    var successfulStreamEstablished = false
                    var transport: ProviderStreamingTransport?
                    var endpoint = (configuration.baseURL.host ?? "") + configuration.baseURL.path
                    do {
                        let request = try makeRequest(configuration: requestConfiguration, apiKey: apiKey, messages: requestMessages, tools: requestTools)
                        endpoint = (request.url?.host ?? configuration.baseURL.host ?? "") + (request.url?.path ?? configuration.baseURL.path)
                        try? await diagnosticLogger?.log(
                            level: .info,
                            subsystem: "provider",
                            action: "request.attempt",
                            result: "started",
                            metadata: [
                                "providerID": configuration.providerID ?? "",
                                "model": configuration.model,
                                "reasoningEffort": requestConfiguration.reasoningEffort?.rawValue ?? ModelReasoningEffort.automatic.rawValue,
                                "protocol": configuration.protocolName ?? "",
                                "authMode": configuration.authModeName ?? ProviderAuthMode.bearer.rawValue,
                                "attempt": String(attempt),
                                "maxAttempts": String(retryPolicy.maxAttempts),
                                "host": request.url?.host ?? configuration.baseURL.host ?? "",
                                "endpointPath": request.url?.path ?? configuration.baseURL.path,
                                "endpoint": endpoint,
                                "transportState": "connecting",
                                "requestBodyBytes": String(request.httpBody?.count ?? 0),
                                "messageCount": String(requestMessages.count),
                                "toolCount": String(requestTools.count),
                                "gatewayRecoveryCompacted": didCompactContextForGatewayRecovery ? "true" : "false"
                            ]
                        )
                        let attemptTransport = ProviderStreamingTransport(configuration: session.configuration, request: request)
                        transport = attemptTransport
                        let (http, lines) = try await attemptTransport.start()
                        try? await diagnosticLogger?.log(
                            level: (200..<300).contains(http.statusCode) ? .info : .warning,
                            subsystem: "provider",
                            action: "request.response",
                            result: (200..<300).contains(http.statusCode) ? "accepted" : "http_error",
                            metadata: [
                                "statusCode": String(http.statusCode),
                                "attempt": String(attempt),
                                "providerID": configuration.providerID ?? "",
                                "model": configuration.model,
                                "reasoningEffort": requestConfiguration.reasoningEffort?.rawValue ?? ModelReasoningEffort.automatic.rawValue,
                                "protocol": configuration.protocolName ?? "",
                                "host": http.url?.host ?? request.url?.host ?? "",
                                "endpointPath": http.url?.path ?? request.url?.path ?? "",
                                "contentType": http.value(forHTTPHeaderField: "Content-Type") ?? ""
                            ]
                        )
                        if !(200..<300).contains(http.statusCode) {
                            var body = Data()
                            do {
                                for try await line in lines {
                                    if body.count < 262_144 {
                                        body.append(Data(line.utf8))
                                        body.append(0x0A)
                                    }
                                }
                            } catch {
                                // HTTP status is authoritative for classification; a truncated
                                // error body must not turn a known 4xx/5xx into a transport replay.
                            }
                            let genericContextRecovery = ProviderCompatibilityClassifier.shouldRetryWithCompactContext(statusCode: http.statusCode, body: body)
                            let agentRouterEnvelopeRecovery = ProviderCompatibilityClassifier.shouldRetryAgentRouterCompatibilityEnvelope(
                                providerID: configuration.providerID,
                                statusCode: http.statusCode,
                                body: body,
                                messageCount: requestMessages.count,
                                toolCount: requestTools.count
                            )
                            if !didCompactContextForGatewayRecovery, genericContextRecovery || agentRouterEnvelopeRecovery {
                                didCompactContextForGatewayRecovery = true
                                requestMessages = HarnessContextManager.providerMessages(from: messages, policy: .gatewayRecovery)
                                if agentRouterEnvelopeRecovery {
                                    requestTools = ProviderCompatibilityClassifier.recoveryToolSchemas(from: tools, messages: messages)
                                }
                                try? await diagnosticLogger?.log(
                                    level: .warning,
                                    subsystem: "provider",
                                    action: "request.compatibility-fallback",
                                    result: agentRouterEnvelopeRecovery ? "retry_with_compact_context_and_tools" : "retry_with_compact_context",
                                    diagnostic: agentRouterEnvelopeRecovery
                                        ? "AgentRouter rejected a large multi-round tool envelope before output. Retrying once with complete recent tool-call pairs and task-family-scoped tool schemas."
                                        : "Provider gateway rejected the full request before output. Retrying once with attachment-aware bounded context while preserving the latest user request and complete tool-call pairs.",
                                    metadata: [
                                        "providerID": configuration.providerID ?? "",
                                        "model": configuration.model,
                                        "statusCode": String(http.statusCode),
                                        "protocol": configuration.protocolName ?? "",
                                        "originalMessageCount": String(messages.count),
                                        "compactMessageCount": String(requestMessages.count),
                                        "originalToolCount": String(tools.count),
                                        "compactToolCount": String(requestTools.count)
                                    ]
                                )
                                continue
                            }
                            if requestConfiguration.reasoningEffort?.providerValue != nil,
                               !didDropReasoningEffortForCompatibility,
                               ProviderCompatibilityClassifier.shouldRetryWithoutReasoningEffort(statusCode: http.statusCode, body: body) {
                                didDropReasoningEffortForCompatibility = true
                                requestConfiguration.reasoningEffort = .automatic
                                try? await diagnosticLogger?.log(
                                    level: .warning,
                                    subsystem: "provider",
                                    action: "request.compatibility-fallback",
                                    result: "retry_without_reasoning_effort",
                                    diagnostic: "中转站明确拒绝当前 effort/reasoning 字段；本次请求回退到自动档，不判定厂商不可用。",
                                    metadata: [
                                        "providerID": configuration.providerID ?? "",
                                        "model": configuration.model,
                                        "statusCode": String(http.statusCode),
                                        "protocol": configuration.protocolName ?? ""
                                    ]
                                )
                                continue
                            }
                            if let upstreamDetail = ProviderCompatibilityClassifier.safeUpstreamErrorDetail(body: body) {
                                try? await diagnosticLogger?.log(
                                    level: .warning,
                                    subsystem: "provider",
                                    action: "request.http-error-detail",
                                    result: "captured",
                                    diagnostic: upstreamDetail,
                                    metadata: [
                                        "providerID": configuration.providerID ?? "",
                                        "model": configuration.model,
                                        "statusCode": String(http.statusCode),
                                        "protocol": configuration.protocolName ?? ""
                                    ]
                                )
                            }
                            throw ProviderHTTPClassifier.error(for: http.statusCode, body: body) ?? ProviderError.invalidResponse(http.statusCode)
                        }
                        successfulStreamEstablished = true
                        responseStarted = try await consume(lines: lines, continuation: continuation)
                        continuation.yield(.finished)
                        try? await diagnosticLogger?.log(
                            level: .info,
                            subsystem: "provider",
                            action: "request.finish",
                            result: "completed",
                            metadata: ["attempt": String(attempt), "providerID": configuration.providerID ?? "", "model": configuration.model]
                        )
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        try? await diagnosticLogger?.log(
                            level: .warning,
                            subsystem: "provider",
                            action: "request.cancel",
                            result: "cancelled",
                            metadata: ["attempt": String(attempt), "providerID": configuration.providerID ?? "", "model": configuration.model]
                        )
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        let bodyDataReceived = transport?.hasReceivedBodyData() ?? false
                        let effectiveError: Error
                        if successfulStreamEstablished, bodyDataReceived, error is URLError {
                            effectiveError = ProviderError.streamInterrupted
                            responseStarted = true
                        } else {
                            effectiveError = error
                        }
                        // A malformed provider event is retried only when an HTTP 2xx body was actually received
                        // and no token/tool output was emitted. This covers compatible proxies that occasionally
                        // emit a truncated/non-terminal SSE response without turning an empty HTTP 200 into a
                        // retry storm. Once real output starts, consume(...) normalizes the failure to
                        // streamInterrupted, which remains non-replayable.
                        let malformedBodyReplay = successfulStreamEstablished
                            && bodyDataReceived
                            && (effectiveError as? ProviderError) == .malformedEvent
                        let retryableBeforeOutput = ProviderRetryClassifier.isRetryableBeforeOutput(effectiveError) || malformedBodyReplay
                        let replaySafeAfterHTTPResponse = ProviderRetryClassifier.isReplaySafeAfterHTTPResponseBeforeOutput(effectiveError) || malformedBodyReplay
                        let bodyBlocksReplay = successfulStreamEstablished && bodyDataReceived && !replaySafeAfterHTTPResponse
                        let mayReplay = !responseStarted
                            && !bodyBlocksReplay
                            && attempt < retryPolicy.maxAttempts
                            && retryableBeforeOutput
                            && (!successfulStreamEstablished || replaySafeAfterHTTPResponse)
                        guard mayReplay else {
                            try? await diagnosticLogger?.log(
                                level: .error,
                                subsystem: "provider",
                                action: "request.failure",
                                result: "failed",
                                error: effectiveError,
                                metadata: [
                                    "attempt": String(attempt),
                                    "providerID": configuration.providerID ?? "",
                                    "model": configuration.model,
                                    "endpoint": endpoint,
                                    "protocol": configuration.protocolName ?? "",
                                    "host": configuration.baseURL.host ?? "",
                                    "endpointPath": endpoint.dropFirst((configuration.baseURL.host ?? "").count).description,
                                    "responseStarted": String(responseStarted),
                                    "streamEstablished": String(successfulStreamEstablished),
                                    "transportState": successfulStreamEstablished ? "http_stream_failed" : "connect_failed",
                                    "bodyDataReceived": String(bodyDataReceived)
                                ]
                            )
                            continuation.finish(throwing: effectiveError)
                            return
                        }
                        let shift = UInt64(min(max(attempt - 1, 0), 8))
                        let multiplier = UInt64(1) << shift
                        let (delay, overflow) = retryPolicy.initialDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
                        let retryDelay = overflow ? UInt64.max / 4 : delay
                        try? await diagnosticLogger?.log(
                            level: .warning,
                            subsystem: "provider",
                            action: "request.retry",
                            result: "scheduled",
                            error: effectiveError,
                            metadata: [
                                "attempt": String(attempt),
                                "nextAttempt": String(attempt + 1),
                                "delayNanoseconds": String(retryDelay),
                                "providerID": configuration.providerID ?? "",
                                "model": configuration.model,
                                "endpoint": endpoint,
                                "protocol": configuration.protocolName ?? "",
                                "host": configuration.baseURL.host ?? "",
                                "endpointPath": endpoint.dropFirst((configuration.baseURL.host ?? "").count).description,
                                "responseStarted": String(responseStarted),
                                "streamEstablished": String(successfulStreamEstablished),
                                "transportState": successfulStreamEstablished ? "http_stream_retry" : "connect_retry",
                                "bodyDataReceived": String(bodyDataReceived)
                            ]
                        )
                        attempt += 1
                        do {
                            try await Task.sleep(nanoseconds: retryDelay)
                        } catch {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func providerPayload(from line: String) -> String? {
    let boundaryWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
    let trimmed = line.trimmingCharacters(in: boundaryWhitespace)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix(":") || trimmed.hasPrefix("event:") { return nil }
    if trimmed.hasPrefix("data:") {
        return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
    if trimmed.first == "{" || trimmed.first == "[" {
        return trimmed
    }
    return nil
}

private func providerText(from content: Any?) -> String? {
    if let text = content as? String { return text }
    guard let blocks = content as? [[String: Any]] else { return nil }
    let text = blocks.compactMap { block -> String? in
        if let value = block["text"] as? String { return value }
        if let value = block["content"] as? String { return value }
        return nil
    }.joined()
    return text.isEmpty ? nil : text
}

private func providerErrorDetail(from value: Any?) -> String? {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let object = value as? [String: Any] {
        for key in ["message", "detail", "error_description", "reason", "error"] {
            if let detail = providerErrorDetail(from: object[key]) { return detail }
        }
        if let type = object["type"] as? String, !type.isEmpty { return type }
        return nil
    }
    if let values = value as? [Any] {
        let details = values.compactMap { providerErrorDetail(from: $0) }
        return details.isEmpty ? nil : details.joined(separator: "; ")
    }
    return nil
}

public struct OpenAICompatibleProviderClient: ProviderStreaming, Sendable, ProviderRequestBuilding {
    fileprivate let session: URLSession
    fileprivate let retryPolicy: RetryPolicy
    fileprivate let diagnosticLogger: DiagnosticLogStore?

    public init(
        session: URLSession = ProviderURLSessionFactory.make(),
        retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 3, initialDelayNanoseconds: 1_500_000_000),
        diagnosticLogger: DiagnosticLogStore? = nil
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.diagnosticLogger = diagnosticLogger
    }

    public func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        requestStream(configuration: configuration, apiKey: apiKey, messages: messages, tools: tools)
    }

    fileprivate func makeRequest(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) throws -> URLRequest {
        let url = try ProviderEndpoint.endpoint(baseURL: configuration.baseURL, path: "chat/completions")
        var body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "messages": try messages.map(openAIMessageObject)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.openAIChatObject)
            body["tool_choice"] = "auto"
        }
        if let effort = configuration.reasoningEffort?.providerValue {
            body["reasoning_effort"] = effort
        }
        return try ProviderRequestFactory.jsonPOST(url: url, apiKey: apiKey, authMode: ProviderRequestFactory.authMode(configuration), body: body)
    }

    fileprivate func consume(lines: AsyncThrowingStream<String, Error>, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation) async throws -> Bool {
        var toolCallState: [Int: ToolCallAccumulator] = [:]
        var sawEvent = false
        var terminal = false
        var outputStarted = false
        do {
            for try await line in lines {
                try Task.checkCancellation()
                guard let payload = providerPayload(from: line) else { continue }
                if payload == "[DONE]" {
                    sawEvent = true
                    terminal = true
                    break
                }
                guard let data = payload.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let choice = choices.first else { continue }
                sawEvent = true

                if let delta = choice["delta"] as? [String: Any] {
                    if let content = providerText(from: delta["content"]), !content.isEmpty {
                        outputStarted = true
                        continuation.yield(.token(content))
                    }
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                        outputStarted = true
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
                } else if let message = choice["message"] as? [String: Any] {
                    if let content = providerText(from: message["content"]), !content.isEmpty {
                        outputStarted = true
                        continuation.yield(.token(content))
                    }
                    if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                        outputStarted = true
                        for (index, raw) in toolCalls.enumerated() {
                            var accumulator = toolCallState[index] ?? ToolCallAccumulator()
                            if let id = raw["id"] as? String { accumulator.id = id }
                            if let function = raw["function"] as? [String: Any] {
                                if let name = function["name"] as? String { accumulator.name = name }
                                if let arguments = function["arguments"] as? String { accumulator.arguments = arguments }
                            }
                            toolCallState[index] = accumulator
                        }
                    }
                    terminal = true
                }

                if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
                    terminal = true
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if outputStarted { throw ProviderError.streamInterrupted }
            throw error
        }
        guard sawEvent else { throw ProviderError.malformedEvent }
        guard terminal else { throw outputStarted ? ProviderError.streamInterrupted : ProviderError.malformedEvent }
        for index in toolCallState.keys.sorted() {
            if let call = toolCallState[index], !call.name.isEmpty {
                guard !call.id.isEmpty else { throw ProviderError.malformedEvent }
                continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments))
            }
        }
        return outputStarted || !toolCallState.isEmpty
    }
}

public struct AnthropicProviderClient: ProviderStreaming, Sendable, ProviderRequestBuilding {
    fileprivate let session: URLSession
    fileprivate let retryPolicy: RetryPolicy
    fileprivate let diagnosticLogger: DiagnosticLogStore?

    public init(
        session: URLSession = ProviderURLSessionFactory.make(),
        retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 3, initialDelayNanoseconds: 1_500_000_000),
        diagnosticLogger: DiagnosticLogStore? = nil
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.diagnosticLogger = diagnosticLogger
    }

    public func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        requestStream(configuration: configuration, apiKey: apiKey, messages: messages, tools: tools)
    }

    fileprivate func makeRequest(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) throws -> URLRequest {
        let url = try ProviderEndpoint.endpoint(baseURL: configuration.baseURL, path: "messages")
        let systemText = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let nonSystem = messages.filter { $0.role != .system }
        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 8192,
            "stream": true,
            "messages": try anthropicMessages(nonSystem)
        ]
        if !systemText.isEmpty { body["system"] = systemText }
        if !tools.isEmpty { body["tools"] = tools.map(\.anthropicObject) }
        if let effort = configuration.reasoningEffort?.providerValue {
            body["output_config"] = ["effort": effort]
        }
        var request = try ProviderRequestFactory.jsonPOST(url: url, apiKey: apiKey, authMode: ProviderRequestFactory.authMode(configuration), body: body)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    fileprivate func consume(lines: AsyncThrowingStream<String, Error>, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation) async throws -> Bool {
        var calls: [Int: ToolCallAccumulator] = [:]
        var sawEvent = false
        var terminal = false
        var outputStarted = false
        do {
            for try await line in lines {
                try Task.checkCancellation()
                guard let payload = providerPayload(from: line) else { continue }
                if payload == "[DONE]" {
                    sawEvent = true
                    terminal = true
                    break
                }
                guard let data = payload.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                // Some Anthropic-compatible gateways occasionally proxy a valid HTTP 200 stream
                // using OpenAI-style `choices` envelopes even though the selected endpoint is
                // /v1/messages. Treat that shape as a compatibility envelope instead of reporting
                // the vendor as down; once any token/tool output is emitted normal replay safety
                // rules still apply.
                if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
                    sawEvent = true
                    if let delta = choice["delta"] as? [String: Any] {
                        if let content = providerText(from: delta["content"]), !content.isEmpty {
                            outputStarted = true
                            continuation.yield(.token(content))
                        }
                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for raw in toolCalls {
                                let index = raw["index"] as? Int ?? 0
                                var call = calls[index] ?? ToolCallAccumulator()
                                if let id = raw["id"] as? String { call.id = id }
                                if let function = raw["function"] as? [String: Any] {
                                    if let name = function["name"] as? String { call.name += name }
                                    if let arguments = function["arguments"] as? String { call.arguments += arguments }
                                }
                                calls[index] = call
                                outputStarted = true
                            }
                        }
                    }
                    if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
                        terminal = true
                    }
                    continue
                }

                if let errorObject = object["error"] {
                    if outputStarted { throw ProviderError.streamInterrupted }
                    let detail = providerErrorDetail(from: errorObject) ?? "上游未提供可解析的错误详情"
                    throw ProviderError.protocolIncompatible(detail)
                }

                guard let type = object["type"] as? String else { continue }
                sawEvent = true
                switch type {
                case "content_block_start":
                    let index = object["index"] as? Int ?? 0
                    if let block = object["content_block"] as? [String: Any] {
                        if block["type"] as? String == "tool_use" {
                            var call = ToolCallAccumulator()
                            call.id = block["id"] as? String ?? ""
                            call.name = block["name"] as? String ?? ""
                            if let input = block["input"], JSONSerialization.isValidJSONObject(input),
                               let inputData = try? JSONSerialization.data(withJSONObject: input),
                               let inputJSON = String(data: inputData, encoding: .utf8), inputJSON != "{}" {
                                call.arguments = inputJSON
                            }
                            calls[index] = call
                            outputStarted = true
                        } else if block["type"] as? String == "text",
                                  let text = block["text"] as? String,
                                  !text.isEmpty {
                            outputStarted = true
                            continuation.yield(.token(text))
                        }
                    }
                case "content_block_delta":
                    let index = object["index"] as? Int ?? 0
                    guard let delta = object["delta"] as? [String: Any], let deltaType = delta["type"] as? String else { continue }
                    if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        outputStarted = true
                        continuation.yield(.token(text))
                    } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                        var call = calls[index] ?? ToolCallAccumulator()
                        call.arguments += partial
                        calls[index] = call
                        outputStarted = true
                    }
                case "message_delta":
                    if let delta = object["delta"] as? [String: Any],
                       let stopReason = delta["stop_reason"] as? String,
                       !stopReason.isEmpty {
                        terminal = true
                    }
                case "message_stop":
                    terminal = true
                case "message":
                    if let blocks = object["content"] as? [[String: Any]] {
                        for (index, block) in blocks.enumerated() {
                            switch block["type"] as? String {
                            case "text":
                                if let text = block["text"] as? String, !text.isEmpty {
                                    outputStarted = true
                                    continuation.yield(.token(text))
                                }
                            case "tool_use":
                                var call = ToolCallAccumulator()
                                call.id = block["id"] as? String ?? ""
                                call.name = block["name"] as? String ?? ""
                                if let input = block["input"], JSONSerialization.isValidJSONObject(input),
                                   let inputData = try? JSONSerialization.data(withJSONObject: input),
                                   let inputJSON = String(data: inputData, encoding: .utf8) {
                                    call.arguments = inputJSON
                                }
                                calls[index] = call
                                outputStarted = true
                            default:
                                break
                            }
                        }
                    } else if let text = providerText(from: object["content"]), !text.isEmpty {
                        outputStarted = true
                        continuation.yield(.token(text))
                    }
                    terminal = true
                case "error":
                    throw ProviderError.transport("Anthropic 流返回错误事件")
                default:
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if outputStarted { throw ProviderError.streamInterrupted }
            throw error
        }
        guard sawEvent else { throw ProviderError.malformedEvent }
        guard terminal else { throw outputStarted ? ProviderError.streamInterrupted : ProviderError.malformedEvent }
        for index in calls.keys.sorted() {
            guard let call = calls[index], !call.id.isEmpty, !call.name.isEmpty else { throw ProviderError.malformedEvent }
            continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments))
        }
        return outputStarted || !calls.isEmpty
    }
}

public struct OpenAIResponsesProviderClient: ProviderStreaming, Sendable, ProviderRequestBuilding {
    fileprivate let session: URLSession
    fileprivate let retryPolicy: RetryPolicy
    fileprivate let diagnosticLogger: DiagnosticLogStore?

    public init(
        session: URLSession = ProviderURLSessionFactory.make(),
        retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 3, initialDelayNanoseconds: 1_500_000_000),
        diagnosticLogger: DiagnosticLogStore? = nil
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.diagnosticLogger = diagnosticLogger
    }

    public func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        requestStream(configuration: configuration, apiKey: apiKey, messages: messages, tools: tools)
    }

    fileprivate func makeRequest(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) throws -> URLRequest {
        let url = try ProviderEndpoint.endpoint(baseURL: configuration.baseURL, path: "responses")
        var body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "input": try responsesInput(messages)
        ]
        if !tools.isEmpty { body["tools"] = tools.map(\.openAIResponsesObject) }
        if let effort = configuration.reasoningEffort?.providerValue {
            body["reasoning"] = ["effort": effort]
        }
        return try ProviderRequestFactory.jsonPOST(url: url, apiKey: apiKey, authMode: ProviderRequestFactory.authMode(configuration), body: body)
    }

    fileprivate func consume(lines: AsyncThrowingStream<String, Error>, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation) async throws -> Bool {
        var calls: [String: ToolCallAccumulator] = [:]
        var sawEvent = false
        var terminal = false
        var outputStarted = false
        do {
            for try await line in lines {
            try Task.checkCancellation()
            guard let payload = providerPayload(from: line) else { continue }
            if payload == "[DONE]" { terminal = true; sawEvent = true; break }
            guard let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = (object["type"] as? String) ?? (object["object"] as? String) else { continue }
            sawEvent = true
            switch type {
            case "response.output_text.delta":
                if let delta = object["delta"] as? String, !delta.isEmpty {
                    outputStarted = true
                    continuation.yield(.token(delta))
                }
            case "response.output_item.added":
                if let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" {
                    let itemID = item["id"] as? String ?? UUID().uuidString
                    var call = ToolCallAccumulator()
                    call.id = item["call_id"] as? String ?? itemID
                    call.name = item["name"] as? String ?? ""
                    call.arguments = item["arguments"] as? String ?? ""
                    calls[itemID] = call
                    outputStarted = true
                }
            case "response.function_call_arguments.delta":
                let itemID = object["item_id"] as? String ?? object["output_item_id"] as? String ?? ""
                guard !itemID.isEmpty else { continue }
                var call = calls[itemID] ?? ToolCallAccumulator()
                if let delta = object["delta"] as? String { call.arguments += delta }
                calls[itemID] = call
                outputStarted = true
            case "response.function_call_arguments.done":
                let itemID = object["item_id"] as? String ?? object["output_item_id"] as? String ?? ""
                if !itemID.isEmpty, let arguments = object["arguments"] as? String {
                    var call = calls[itemID] ?? ToolCallAccumulator()
                    call.arguments = arguments
                    calls[itemID] = call
                }
            case "response.completed":
                terminal = true
            case "response":
                if let output = object["output"] as? [[String: Any]] {
                    for item in output {
                        switch item["type"] as? String {
                        case "message":
                            if let content = item["content"] as? [[String: Any]] {
                                for block in content where block["type"] as? String == "output_text" {
                                    if let text = block["text"] as? String, !text.isEmpty {
                                        outputStarted = true
                                        continuation.yield(.token(text))
                                    }
                                }
                            }
                        case "function_call":
                            let itemID = item["id"] as? String ?? UUID().uuidString
                            var call = ToolCallAccumulator()
                            call.id = item["call_id"] as? String ?? itemID
                            call.name = item["name"] as? String ?? ""
                            call.arguments = item["arguments"] as? String ?? "{}"
                            calls[itemID] = call
                            outputStarted = true
                        default:
                            break
                        }
                    }
                }
                terminal = true
            case "response.failed", "error":
                let detail = providerErrorDetail(from: object["response"] ?? object["error"] ?? object)
                    ?? "上游未提供可解析的 Responses 错误详情"
                if outputStarted {
                    throw ProviderError.streamInterrupted
                }
                throw ProviderError.protocolIncompatible(detail)
            default:
                break
            }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if outputStarted { throw ProviderError.streamInterrupted }
            throw error
        }
        guard sawEvent else { throw ProviderError.malformedEvent }
        guard terminal else { throw outputStarted ? ProviderError.streamInterrupted : ProviderError.malformedEvent }
        for key in calls.keys.sorted() {
            guard let call = calls[key], !call.id.isEmpty, !call.name.isEmpty else { throw ProviderError.malformedEvent }
            continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments))
        }
        return outputStarted || !calls.isEmpty
    }
}

public actor ProviderRequestKeyState {
    private struct Entry: Sendable {
        var reference: String
        var protocolName: String?
        var touchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 60 * 60) {
        self.ttl = max(60, ttl)
    }

    public func preferredReference(configurationID: UUID, allowedReferences: [String], fallback: String) -> String {
        preferredReference(routingKey: "configuration:\(configurationID.uuidString)", allowedReferences: allowedReferences, fallback: fallback)
    }

    public func preferredReference(routingKey: String, allowedReferences: [String], fallback: String) -> String {
        prune()
        guard let entry = entries[routingKey], allowedReferences.contains(entry.reference) else { return fallback }
        entries[routingKey]?.touchedAt = Date()
        return entry.reference
    }

    public func preferredProtocol(configurationID: UUID, reference: String, allowedProtocols: [String], fallback: String) -> String {
        preferredProtocol(routingKey: "configuration:\(configurationID.uuidString)", reference: reference, allowedProtocols: allowedProtocols, fallback: fallback)
    }

    public func preferredProtocol(routingKey: String, reference: String, allowedProtocols: [String], fallback: String) -> String {
        prune()
        guard let entry = entries[routingKey],
              entry.reference == reference,
              let protocolName = entry.protocolName,
              allowedProtocols.contains(protocolName) else { return fallback }
        entries[routingKey]?.touchedAt = Date()
        return protocolName
    }

    public func markSuccessful(configurationID: UUID, reference: String, protocolName: String? = nil) {
        markSuccessful(routingKey: "configuration:\(configurationID.uuidString)", reference: reference, protocolName: protocolName)
    }

    public func markSuccessful(routingKey: String, reference: String, protocolName: String? = nil) {
        prune()
        entries[routingKey] = Entry(reference: reference, protocolName: protocolName, touchedAt: Date())
    }

    private func prune(now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.touchedAt) <= ttl }
    }
}

public struct DeferredProviderClient: ProviderStreaming, Sendable {
    private let factory: @Sendable () -> any ProviderStreaming

    public init(factory: @escaping @Sendable () -> any ProviderStreaming) {
        self.factory = factory
    }

    public func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        // Network/session objects are intentionally materialized only when an
        // actual Provider request begins. This keeps CFNetwork/XPC work out of the
        // iOS app's first-frame path, including privileged TrollStore builds.
        factory().stream(configuration: configuration, apiKey: apiKey, messages: messages, tools: tools)
    }
}

public struct ProviderClientRouter: ProviderStreaming, Sendable {
    private let keyVault: APIKeyVault
    private let anthropic: ProviderStreaming
    private let openAIChat: ProviderStreaming
    private let responses: ProviderStreaming
    private let requestKeyState: ProviderRequestKeyState
    private let diagnosticLogger: DiagnosticLogStore?

    public init(
        keyVault: APIKeyVault,
        anthropic: ProviderStreaming = DeferredProviderClient { AnthropicProviderClient() },
        openAIChat: ProviderStreaming = DeferredProviderClient { OpenAICompatibleProviderClient() },
        responses: ProviderStreaming = DeferredProviderClient { OpenAIResponsesProviderClient() },
        requestKeyState: ProviderRequestKeyState = ProviderRequestKeyState(),
        diagnosticLogger: DiagnosticLogStore? = nil
    ) {
        self.keyVault = keyVault
        self.anthropic = anthropic
        self.openAIChat = openAIChat
        self.responses = responses
        self.requestKeyState = requestKeyState
        self.diagnosticLogger = diagnosticLogger
    }

    public func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let fallbackReferences = (configuration.fallbackAPIKeyReferences ?? []).filter { $0 != configuration.apiKeyReference }
                let allowedReferences = [configuration.apiKeyReference] + fallbackReferences
                let routingStateKey = [
                    configuration.providerID ?? configuration.baseURL.absoluteString,
                    configuration.model.lowercased()
                ].joined(separator: "|")
                let preferredReference = await requestKeyState.preferredReference(
                    routingKey: routingStateKey,
                    allowedReferences: allowedReferences,
                    fallback: configuration.apiKeyReference
                )
                let orderedReferences: [String]
                if configuration.allowSameProviderKeyFailover == true,
                   let preferredIndex = allowedReferences.firstIndex(of: preferredReference) {
                    orderedReferences = (0..<allowedReferences.count).map { offset in
                        allowedReferences[(preferredIndex + offset) % allowedReferences.count]
                    }
                } else {
                    orderedReferences = [configuration.apiKeyReference]
                }

                var keyCandidates: [(String, String)] = []
                for reference in orderedReferences {
                    if reference == configuration.apiKeyReference {
                        keyCandidates.append((reference, apiKey))
                    } else if let key = try? await keyVault.key(for: reference) {
                        keyCandidates.append((reference, key))
                    }
                }

                var defaultProtocolCandidates: [ProviderProtocol] = []
                let rawProtocolNames = [configuration.protocolName ?? ""] + (configuration.fallbackProtocolNames ?? [])
                for raw in rawProtocolNames {
                    guard let value = ProviderProtocol(rawValue: raw), !defaultProtocolCandidates.contains(value) else { continue }
                    defaultProtocolCandidates.append(value)
                }
                if defaultProtocolCandidates.isEmpty { defaultProtocolCandidates = [.openAIChat] }

                var lastError: Error = ProviderError.missingAPIKey
                keyLoop: for (keyIndex, keyCandidate) in keyCandidates.enumerated() {
                    var keyProtocolCandidates: [ProviderProtocol] = []
                    for raw in configuration.protocolNamesByKeyReference?[keyCandidate.0] ?? [] {
                        guard let value = ProviderProtocol(rawValue: raw), !keyProtocolCandidates.contains(value) else { continue }
                        keyProtocolCandidates.append(value)
                    }
                    if keyProtocolCandidates.isEmpty { keyProtocolCandidates = defaultProtocolCandidates }
                    let protocolNames = keyProtocolCandidates.map(\.rawValue)
                    let preferredProtocolName = await requestKeyState.preferredProtocol(
                        routingKey: routingStateKey,
                        reference: keyCandidate.0,
                        allowedProtocols: protocolNames,
                        fallback: keyProtocolCandidates[0].rawValue
                    )
                    let orderedProtocols: [ProviderProtocol]
                    if let preferredProtocolIndex = keyProtocolCandidates.firstIndex(where: { $0.rawValue == preferredProtocolName }) {
                        orderedProtocols = (0..<keyProtocolCandidates.count).map { offset in
                            keyProtocolCandidates[(preferredProtocolIndex + offset) % keyProtocolCandidates.count]
                        }
                    } else {
                        orderedProtocols = keyProtocolCandidates
                    }
                    for (protocolIndex, protocolCandidate) in orderedProtocols.enumerated() {
                        var attemptConfiguration = configuration
                        attemptConfiguration.protocolName = protocolCandidate.rawValue
                        let client = clientFor(attemptConfiguration)
                        var emittedOutput = false
                        var emittedToken = false
                        var emittedToolCall = false
                        try? await diagnosticLogger?.log(
                            level: .info,
                            subsystem: "provider",
                            action: "route-candidate.attempt",
                            result: "started",
                            metadata: [
                                "providerID": configuration.providerID ?? "",
                                "protocol": protocolCandidate.rawValue,
                                "keyReference": keyCandidate.0,
                                "keyCandidateIndex": String(keyIndex),
                                "protocolCandidateIndex": String(protocolIndex),
                                "fallbackKey": keyIndex == 0 ? "false" : "true",
                                "fallbackProtocol": protocolIndex == 0 ? "false" : "true"
                            ]
                        )
                        do {
                            let stream = client.stream(configuration: attemptConfiguration, apiKey: keyCandidate.1, messages: messages, tools: tools)
                            for try await event in stream {
                                try Task.checkCancellation()
                                switch event {
                                case .token:
                                    emittedOutput = true
                                    emittedToken = true
                                case .toolCall:
                                    emittedOutput = true
                                    emittedToolCall = true
                                case .finished:
                                    break
                                }
                                continuation.yield(event)
                            }
                            await requestKeyState.markSuccessful(
                                routingKey: routingStateKey,
                                reference: keyCandidate.0,
                                protocolName: protocolCandidate.rawValue
                            )
                            try? await diagnosticLogger?.log(
                                level: .info,
                                subsystem: "provider",
                                action: "route-candidate.attempt",
                                result: "completed",
                                metadata: [
                                    "providerID": configuration.providerID ?? "",
                                    "protocol": protocolCandidate.rawValue,
                                    "keyReference": keyCandidate.0,
                                    "fallbackKey": keyIndex == 0 ? "false" : "true",
                                    "fallbackProtocol": protocolIndex == 0 ? "false" : "true",
                                    "emittedToken": String(emittedToken),
                                    "emittedToolCall": String(emittedToolCall)
                                ]
                            )
                            continuation.finish()
                            return
                        } catch is CancellationError {
                            continuation.finish(throwing: CancellationError())
                            return
                        } catch {
                            lastError = error
                            let hasAnotherProtocol = protocolIndex + 1 < orderedProtocols.count
                            let hasAnotherKey = keyIndex + 1 < keyCandidates.count
                            let mayFallbackProtocol = !emittedOutput && hasAnotherProtocol && ProviderProtocolFallbackClassifier.shouldFallback(error)
                            let mayRotateKey = !emittedOutput && hasAnotherKey && configuration.allowSameProviderKeyFailover == true && ProviderKeyRotationClassifier.shouldRotate(error)
                            try? await diagnosticLogger?.log(
                                level: .error,
                                subsystem: "provider",
                                action: "route-candidate.failure",
                                result: "failed",
                                error: error,
                                metadata: [
                                    "providerID": configuration.providerID ?? "",
                                    "protocol": protocolCandidate.rawValue,
                                    "keyReference": keyCandidate.0,
                                    "keyCandidateIndex": String(keyIndex),
                                    "protocolCandidateIndex": String(protocolIndex),
                                    "fallbackKey": keyIndex == 0 ? "false" : "true",
                                    "fallbackProtocol": protocolIndex == 0 ? "false" : "true",
                                    "emittedToken": String(emittedToken),
                                    "emittedToolCall": String(emittedToolCall),
                                    "protocolFallbackAllowed": String(mayFallbackProtocol),
                                    "keyRotationAllowed": String(mayRotateKey)
                                ]
                            )
                            if mayFallbackProtocol {
                                try? await diagnosticLogger?.log(
                                    level: .warning,
                                    subsystem: "provider",
                                    action: "protocol.rotate",
                                    result: "rotating",
                                    error: error,
                                    metadata: [
                                        "providerID": configuration.providerID ?? "",
                                        "keyReference": keyCandidate.0,
                                        "fromProtocol": protocolCandidate.rawValue,
                                        "nextProtocol": orderedProtocols[protocolIndex + 1].rawValue
                                    ]
                                )
                                continue
                            }
                            if mayRotateKey {
                                try? await diagnosticLogger?.log(
                                    level: .warning,
                                    subsystem: "provider",
                                    action: "key-slot.rotate",
                                    result: "rotating",
                                    error: error,
                                    metadata: [
                                        "providerID": configuration.providerID ?? "",
                                        "protocol": protocolCandidate.rawValue,
                                        "fromKeyReference": keyCandidate.0,
                                        "nextCandidateIndex": String(keyIndex + 1),
                                        "emittedToken": String(emittedToken),
                                        "emittedToolCall": String(emittedToolCall)
                                    ]
                                )
                                continue keyLoop
                            }
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func clientFor(_ configuration: ProviderConfiguration) -> ProviderStreaming {
        switch ProviderProtocol(rawValue: configuration.protocolName ?? "") {
        case .anthropic: return anthropic
        case .openAIResponses: return responses
        case .openAIChat, .none: return openAIChat
        }
    }
}

public enum ProviderCompatibilityClassifier {
    public static func shouldRetryWithCompactContext(statusCode: Int, body: Data) -> Bool {
        let text = String(data: body.prefix(262_144), encoding: .utf8)?.lowercased() ?? ""
        if ProviderFailureEvidence.isCapacity(text) || ProviderFailureEvidence.isCredential(text) || ProviderFailureEvidence.isModelUnavailable(text) {
            return false
        }
        let contextMarkers = [
            "context length", "context_length", "context window", "too many tokens", "request too large",
            "payload too large", "prompt is too long", "maximum context", "max context"
        ]
        if statusCode == 400 || statusCode == 413 || statusCode == 422 {
            return contextMarkers.contains { text.contains($0) }
        }
        // Several Anthropic-compatible gateways surface request overload/context rejection as a
        // generic 502/503/504. A single replay with a much smaller attachment-aware context is safe
        // because no provider output has been emitted yet; normal retry rules resume afterwards.
        return statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    public static func shouldRetryAgentRouterCompatibilityEnvelope(
        providerID: String?,
        statusCode: Int,
        body: Data,
        messageCount: Int,
        toolCount: Int
    ) -> Bool {
        guard providerID == ProviderCatalog.agentRouterID, statusCode == 400 || statusCode == 422 else { return false }
        let text = String(data: body.prefix(262_144), encoding: .utf8)?.lowercased() ?? ""
        if ProviderFailureEvidence.isCapacity(text) || ProviderFailureEvidence.isCredential(text) || ProviderFailureEvidence.isModelUnavailable(text) {
            return false
        }
        // AgentRouter can accept the same model/protocol for small requests yet reject a later
        // multi-round tool envelope with a generic 400. One bounded retry is safe before output:
        // compact complete tool-call pairs and scope the advertised tool list to the active task
        // family instead of resending the full device toolbox.
        return messageCount >= 48 || toolCount >= 40 || text.contains("content-blocked") || text.contains("content blocked")
    }

    public static func recoveryToolSchemas(from tools: [ProviderToolSchema], messages: [ChatMessage]) -> [ProviderToolSchema] {
        guard let recentTool = messages.reversed().compactMap({ $0.providerMetadata["tool_name"] }).first else { return tools }
        let families: [String]
        if recentTool.hasPrefix("apps.") || recentTool.hasPrefix("gui.") || recentTool.hasPrefix("interaction.") {
            families = ["apps.", "gui.", "interaction.", "capability."]
        } else if recentTool.hasPrefix("files.") || recentTool.hasPrefix("container.") || recentTool.hasPrefix("data.")
                    || recentTool.hasPrefix("json.") || recentTool.hasPrefix("plist.") || recentTool.hasPrefix("sqlite.") || recentTool.hasPrefix("storage.") {
            families = ["files.", "container.", "data.", "json.", "plist.", "sqlite.", "storage.", "capability."]
        } else if recentTool.hasPrefix("ipa.") {
            families = ["ipa.", "files.", "capability."]
        } else {
            return tools
        }

        let filtered = tools.filter { schema in
            guard let internalName = try? ProviderToolNameMap.decode(schema.name) else { return false }
            return families.contains { internalName.hasPrefix($0) }
        }
        return filtered.count >= 4 ? filtered : tools
    }

    public static func safeUpstreamErrorDetail(body: Data) -> String? {
        let raw = String(data: body.prefix(262_144), encoding: .utf8) ?? ""
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            var candidate = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("data:") {
                candidate = String(candidate.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !candidate.isEmpty, candidate != "[DONE]", let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let detail: String?
            if let dictionary = object as? [String: Any] {
                detail = providerErrorDetail(from: dictionary["error"] ?? dictionary["message"] ?? dictionary["detail"])
                    ?? providerErrorDetail(from: dictionary)
            } else {
                detail = providerErrorDetail(from: object)
            }
            if let detail {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(512)) }
            }
        }
        return nil
    }

    public static func shouldRetryWithoutReasoningEffort(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 400 || statusCode == 422 else { return false }
        let text = String(data: body.prefix(262_144), encoding: .utf8)?.lowercased() ?? ""
        guard !text.isEmpty else { return false }
        let mentionsEffortField = text.contains("reasoning_effort")
            || text.contains("output_config")
            || text.contains("reasoning.effort")
            || (text.contains("effort") && text.contains("reasoning"))
        let indicatesUnsupportedField = text.contains("unknown")
            || text.contains("unsupported")
            || text.contains("unrecognized")
            || text.contains("not allowed")
            || text.contains("extra field")
            || text.contains("invalid field")
            || text.contains("invalid parameter")
        return mentionsEffortField && indicatesUnsupportedField
    }
}

public enum ProviderHTTPClassifier {
    public static func error(for statusCode: Int, body: Data = Data()) -> ProviderError? {
        switch statusCode {
        case 200..<300:
            return nil
        case 429:
            return .rateLimited
        default:
            break
        }

        let text = String(data: body.prefix(262_144), encoding: .utf8)?.lowercased() ?? ""
        if ProviderFailureEvidence.isCapacity(text) {
            return .capacityExhausted(statusCode)
        }
        if ProviderFailureEvidence.isModelUnavailable(text) {
            return .modelUnavailable(statusCode)
        }
        if ProviderFailureEvidence.isClientRejected(text) {
            return .clientRejected(statusCode)
        }
        if statusCode == 401 {
            return .authenticationFailed(statusCode)
        }
        if statusCode == 403, ProviderFailureEvidence.isCredential(text) {
            return .authenticationFailed(statusCode)
        }
        return .invalidResponse(statusCode)
    }
}

public enum ProviderProtocolFallbackClassifier {
    /// Protocol failover is only allowed before any provider output. It is reserved for
    /// errors that can plausibly be route/protocol specific; credential/quota/rate-limit
    /// failures stay on the current protocol decision and move only through the Key pool.
    public static func shouldFallback(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else { return false }
        switch providerError {
        case .modelUnavailable, .malformedEvent, .protocolIncompatible:
            return true
        case .clientRejected:
            return false
        case .invalidResponse(let code):
            return code == 404 || code == 405 || (500...599).contains(code)
        case .missingAPIKey, .invalidEndpoint, .authenticationFailed, .capacityExhausted,
             .rateLimited, .streamInterrupted, .attachmentUnavailable, .attachmentTooLarge,
             .unsupportedAttachmentType, .transport:
            return false
        }
    }
}

public enum ProviderKeyRotationClassifier {
    /// Key failover is only consulted before any token/tool output was emitted.
    /// It covers credential/capacity failures and transient upstream failures after the
    /// per-key retry budget has already been exhausted. Once output exists the router never
    /// rotates or replays the request.
    public static func shouldRotate(_ error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .authenticationFailed, .capacityExhausted:
                return true
            case .clientRejected:
                return false
            case .invalidResponse(let code):
                return (500...599).contains(code)
            case .modelUnavailable:
                // Channel availability is frequently Key/account scoped on compatible gateways.
                // Before any output, another Key owned by the same Provider is a safe bounded route.
                return true
            case .missingAPIKey, .invalidEndpoint, .rateLimited, .malformedEvent, .streamInterrupted,
                 .attachmentUnavailable, .attachmentTooLarge, .unsupportedAttachmentType,
                 .protocolIncompatible, .transport:
                return false
            }
        }
        return ProviderRetryClassifier.isRetryableBeforeOutput(error)
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
            case .capacityExhausted, .modelUnavailable, .clientRejected, .protocolIncompatible,
                 .transport, .streamInterrupted:
                return false
            case .missingAPIKey, .invalidEndpoint, .authenticationFailed, .malformedEvent,
                 .attachmentUnavailable, .attachmentTooLarge, .unsupportedAttachmentType:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff,
             .dataNotAllowed, .cannotLoadFromNetwork, .cannotParseResponse:
            return true
        case .timedOut, .networkConnectionLost, .callIsActive:
            // Safe only before the stream has emitted any text or tool-call material.
            // Once output starts, consume(...) normalizes transport loss to
            // streamInterrupted, which is intentionally never replayed.
            return true
        case .cancelled, .badURL, .unsupportedURL, .userAuthenticationRequired,
             .userCancelledAuthentication, .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return false
        default:
            return false
        }
    }

    public static func isReplaySafeAfterHTTPResponseBeforeOutput(_ error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            return providerError == .malformedEvent
        }
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .cannotParseResponse
    }
}

private enum ProviderFailureEvidence {
    static func isCredential(_ text: String) -> Bool {
        let markers = [
            "invalid key", "key invalid", "invalid api key", "api key invalid", "key expired",
            "expired key", "api key expired", "authentication failed", "unauthorized api key",
            "无效密钥", "密钥失效", "密钥过期"
        ]
        return markers.contains { text.contains($0) }
    }

    static func isClientRejected(_ text: String) -> Bool {
        let markers = [
            "unauthorized_client_error", "unauthorized client detected", "unauthorized_client",
            "client not allowed", "forbidden client", "not a recognized client"
        ]
        return markers.contains { text.contains($0) }
    }

    static func isCapacity(_ text: String) -> Bool {
        let markers = [
            "insufficient_user_quota", "insufficient quota", "quota exhausted", "insufficient balance",
            "balance insufficient", "pre-charge failed", "预扣费额度失败", "用户剩余额度", "余额不足",
            "余额已用尽", "额度不足", "额度已用尽"
        ]
        return markers.contains { text.contains($0) }
    }

    static func isModelUnavailable(_ text: String) -> Bool {
        let markers = [
            "model_not_found", "model not found", "no available channel for model",
            "no available channel", "no available distributor", "模型无可用渠道", "模型不存在",
            "无可用渠道（distributor）", "无可用渠道(distributor)"
        ]
        return markers.contains { text.contains($0) }
    }
}

enum ProviderEndpoint {
    private static let knownEndpointSuffixes: [[String]] = [
        ["messages"],
        ["chat", "completions"],
        ["responses"]
    ]

    static func endpoint(baseURL: URL, path: String) throws -> URL {
        guard ProviderEndpointPolicy.allowsBaseURL(baseURL) else { throw ProviderError.invalidEndpoint }
        var baseComponents = baseURL.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let requestedComponents = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !requestedComponents.isEmpty else { throw ProviderError.invalidEndpoint }

        if baseComponents.suffix(requestedComponents.count).elementsEqual(requestedComponents) {
            return baseURL
        }
        for suffix in knownEndpointSuffixes where baseComponents.suffix(suffix.count).elementsEqual(suffix) {
            baseComponents.removeLast(suffix.count)
            break
        }
        if baseComponents.last != "v1" {
            baseComponents.append("v1")
        }
        baseComponents.append(contentsOf: requestedComponents)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidEndpoint
        }
        components.path = "/" + baseComponents.joined(separator: "/")
        guard let url = components.url else { throw ProviderError.invalidEndpoint }
        return url
    }
}

enum ProviderCompatibilityHeaders {
    private static let agentRouterHosts = Set(["agentrouter.org", "co.agentrouter.org"])

    static func apply(to request: inout URLRequest) {
        guard let host = request.url?.host?.lowercased(), agentRouterHosts.contains(host) else { return }
        // AgentRouter validates a coding-Agent client identity before it reaches API-key
        // authentication. Keep this provider-specific and aligned with the desktop runtime;
        // ordinary OpenAI/Anthropic-compatible gateways must not receive these headers.
        request.setValue("claude-cli/1.0.120 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("claude-code-20250219", forHTTPHeaderField: "anthropic-beta")
        request.setValue("js", forHTTPHeaderField: "x-stainless-lang")
        request.setValue("0.60.0", forHTTPHeaderField: "x-stainless-package-version")
        request.setValue("node", forHTTPHeaderField: "x-stainless-runtime")
        request.setValue("v22.0.0", forHTTPHeaderField: "x-stainless-runtime-version")
        request.setValue("Windows", forHTTPHeaderField: "x-stainless-os")
        request.setValue("x64", forHTTPHeaderField: "x-stainless-arch")
    }
}

private enum ProviderRequestFactory {
    static func authMode(_ configuration: ProviderConfiguration) -> ProviderAuthMode {
        ProviderAuthMode(rawValue: configuration.authModeName ?? "") ?? .bearer
    }

    static func jsonPOST(url: URL, apiKey: String, authMode: ProviderAuthMode, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        ProviderCompatibilityHeaders.apply(to: &request)
        switch authMode {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xAPIKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .both:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        return request
    }
}

private func providerVisibleToolName(_ message: ChatMessage) -> String? {
    if let explicit = message.providerMetadata["provider_tool_name"], ProviderToolNameMap.isProviderSafe(explicit) {
        return explicit
    }
    guard let internalName = message.providerMetadata["tool_name"] else { return nil }
    return try? ProviderToolNameMap.encode(internalName)
}

private struct ProviderImageAttachment {
    let base64: String
    let mimeType: String

    var dataURL: String { "data:\(mimeType);base64,\(base64)" }
}

private func providerImageAttachments(_ message: ChatMessage) throws -> [ProviderImageAttachment] {
    guard message.role == .user, !message.attachments.isEmpty else { return [] }
    guard message.attachments.count <= 8 else {
        throw ProviderError.transport("单条消息最多向厂商发送 8 张当前观察图片")
    }
    let supportRoot = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true))
        .appendingPathComponent("CloudCode", isDirectory: true)
        .appendingPathComponent("Attachments", isDirectory: true)
        .standardizedFileURL
    var totalBytes: Int64 = 0
    return try message.attachments.map { attachment in
        guard attachment.byteSize > 0, attachment.byteSize <= Int64(ChatMessageAttachmentPolicy.maxImageBytes) else {
            throw ProviderError.attachmentTooLarge(attachment.byteSize)
        }
        totalBytes += attachment.byteSize
        guard totalBytes <= Int64(ChatMessageAttachmentPolicy.maxImageBytes * 8) else {
            throw ProviderError.attachmentTooLarge(totalBytes)
        }
        let mimeType = attachment.mimeType.lowercased()
        guard ["image/jpeg", "image/png", "image/webp", "image/gif"].contains(mimeType) else {
            throw ProviderError.unsupportedAttachmentType(attachment.mimeType)
        }
        let candidate = URL(fileURLWithPath: attachment.path).standardizedFileURL
        guard candidate.path.hasPrefix(supportRoot.path + "/") else {
            throw ProviderError.attachmentUnavailable(attachment.filename)
        }
        guard let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]),
              !data.isEmpty,
              data.count <= ChatMessageAttachmentPolicy.maxImageBytes else {
            throw ProviderError.attachmentUnavailable(attachment.filename)
        }
        return ProviderImageAttachment(base64: data.base64EncodedString(), mimeType: mimeType)
    }
}

private func openAIImageContent(_ message: ChatMessage, attachments: [ProviderImageAttachment]) -> [[String: Any]] {
    var content: [[String: Any]] = []
    if !message.content.isEmpty {
        content.append(["type": "text", "text": message.content])
    }
    content.append(contentsOf: attachments.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] })
    return content
}

private func anthropicImageContent(_ message: ChatMessage, attachments: [ProviderImageAttachment]) -> [[String: Any]] {
    var content: [[String: Any]] = []
    if !message.content.isEmpty {
        content.append(["type": "text", "text": message.content])
    }
    content.append(contentsOf: attachments.map { attachment in
        [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": attachment.mimeType,
                "data": attachment.base64
            ]
        ]
    })
    return content
}

private func responsesImageContent(_ message: ChatMessage, attachments: [ProviderImageAttachment]) -> [[String: Any]] {
    var content: [[String: Any]] = []
    if !message.content.isEmpty {
        content.append(["type": "input_text", "text": message.content])
    }
    content.append(contentsOf: attachments.map { ["type": "input_image", "image_url": $0.dataURL] })
    return content
}

private func openAIMessageObject(_ message: ChatMessage) throws -> [String: Any] {
    var object: [String: Any] = ["role": message.role.rawValue]
    let attachments = try providerImageAttachments(message)
    if !attachments.isEmpty {
        object["content"] = openAIImageContent(message, attachments: attachments)
    } else {
        object["content"] = message.content
    }
    if message.role == .tool, let toolCallID = message.providerMetadata["tool_call_id"] {
        object["tool_call_id"] = toolCallID
        if let toolName = providerVisibleToolName(message) { object["name"] = toolName }
    }
    if message.role == .assistant,
       let toolCallID = message.providerMetadata["tool_call_id"],
       let toolName = providerVisibleToolName(message) {
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

private func anthropicMessages(_ messages: [ChatMessage]) throws -> [[String: Any]] {
    var result: [[String: Any]] = []

    func append(role: String, blocks: [[String: Any]]) {
        guard !blocks.isEmpty else { return }
        if let lastIndex = result.indices.last,
           result[lastIndex]["role"] as? String == role,
           var existing = result[lastIndex]["content"] as? [[String: Any]] {
            existing.append(contentsOf: blocks)
            result[lastIndex]["content"] = existing
            return
        }
        result.append(["role": role, "content": blocks])
    }

    for message in messages {
        if message.role == .tool, let callID = message.providerMetadata["tool_call_id"] {
            append(role: "user", blocks: [[
                "type": "tool_result",
                "tool_use_id": callID,
                "content": message.content
            ]])
            continue
        }
        if message.role == .assistant,
           let callID = message.providerMetadata["tool_call_id"],
           let name = providerVisibleToolName(message) {
            let arguments = message.providerMetadata["tool_arguments"] ?? "{}"
            let input: [String: Any]
            if let data = arguments.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dictionary = object as? [String: Any] {
                input = dictionary
            } else {
                // Anthropic tool_use.input must be an object. Persisted history can contain a
                // provider-produced scalar/array argument payload after a rejected tool call; never
                // replay that invalid shape into the next /messages request.
                input = [:]
            }
            append(role: "assistant", blocks: [[
                "type": "tool_use",
                "id": callID,
                "name": name,
                "input": input
            ]])
            continue
        }
        let role = message.role == .assistant ? "assistant" : "user"
        let attachments = try providerImageAttachments(message)
        if !attachments.isEmpty {
            append(role: role, blocks: anthropicImageContent(message, attachments: attachments))
        } else if !message.content.isEmpty {
            append(role: role, blocks: [["type": "text", "text": message.content]])
        }
    }
    return result
}

private func responsesInput(_ messages: [ChatMessage]) throws -> [[String: Any]] {
    try messages.map { message in
        if message.role == .tool, let callID = message.providerMetadata["tool_call_id"] {
            return ["type": "function_call_output", "call_id": callID, "output": message.content]
        }
        if message.role == .assistant,
           let callID = message.providerMetadata["tool_call_id"],
           let name = providerVisibleToolName(message) {
            return [
                "type": "function_call",
                "call_id": callID,
                "name": name,
                "arguments": message.providerMetadata["tool_arguments"] ?? "{}"
            ]
        }
        let attachments = try providerImageAttachments(message)
        if !attachments.isEmpty {
            return ["role": message.role.rawValue, "content": responsesImageContent(message, attachments: attachments)]
        }
        return ["role": message.role.rawValue, "content": message.content]
    }
}

private struct ToolCallAccumulator: Sendable {
    var id = ""
    var name = ""
    var arguments = ""
}
