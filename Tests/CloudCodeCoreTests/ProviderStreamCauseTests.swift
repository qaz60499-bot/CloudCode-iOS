import Foundation
import XCTest
@testable import CloudCodeCore

final class ProviderStreamCauseTests: XCTestCase {
    func testTransportFailureAfterOutputLogsSafeNSErrorCauseAndNeverReplays() async throws {
        let attempt = try await perform(
            kind: .openAIChat,
            body: event(.openAIChat.partialOutput),
            failureCode: .networkConnectionLost
        )

        XCTAssertEqual(attempt.output, "partial")
        XCTAssertEqual(attempt.error as? ProviderError, .streamInterrupted)
        XCTAssertEqual(attempt.requestCount, 1)
        let record = try causeRecord(in: attempt.records, cause: "transport")
        XCTAssertEqual(record.metadata["errorDomain"], NSURLErrorDomain)
        XCTAssertEqual(
            record.metadata["errorCode"],
            String((URLError(.networkConnectionLost) as NSError).code)
        )
        let logs = try serializedLogs(attempt.records)
        XCTAssertFalse(logs.contains("stream-secret-api-key"))
        XCTAssertFalse(logs.contains("partial"))
    }

    func testParserFailureAfterOutputLogsSafeCauseAndNeverReplays() async throws {
        let attempt = try await perform(
            kind: .openAIChat,
            body: event(.openAIChat.partialOutput) + Data("data: {invalid-json}\n\n".utf8)
        )

        XCTAssertEqual(attempt.output, "partial")
        XCTAssertEqual(attempt.error as? ProviderError, .streamInterrupted)
        XCTAssertEqual(attempt.requestCount, 1)
        let record = try causeRecord(in: attempt.records, cause: "parser_malformed")
        XCTAssertEqual(record.metadata["errorDomain"], NSCocoaErrorDomain)
        XCTAssertNotNil(record.metadata["errorCode"])
        let logs = try serializedLogs(attempt.records)
        XCTAssertFalse(logs.contains("stream-secret-api-key"))
        XCTAssertFalse(logs.contains("invalid-json"))
        XCTAssertFalse(logs.contains("partial"))
    }

    func testMissingTerminalAfterOutputIsRecordedForEveryProviderProtocol() async throws {
        for kind in ProviderStreamTestKind.allCases {
            let attempt = try await perform(kind: kind, body: event(kind.partialOutput))

            XCTAssertEqual(attempt.output, "partial", "\(kind) must yield its partial output")
            XCTAssertEqual(attempt.error as? ProviderError, .streamInterrupted, "\(kind) must preserve the public error")
            XCTAssertEqual(attempt.requestCount, 1, "\(kind) must not replay after output")
            _ = try causeRecord(in: attempt.records, cause: "missing_terminal")
            let logs = try serializedLogs(attempt.records)
            XCTAssertFalse(logs.contains("stream-secret-api-key"))
            XCTAssertFalse(logs.contains("partial"))
        }
    }

    func testUpstreamErrorAfterOutputIsRecordedWithoutEventDetailsOrReplay() async throws {
        for kind in ProviderStreamTestKind.allCases {
            let attempt = try await perform(
                kind: kind,
                body: event(kind.partialOutput) + event(kind.upstreamError)
            )

            XCTAssertEqual(attempt.output, "partial", "\(kind) must yield its partial output")
            XCTAssertEqual(attempt.error as? ProviderError, .streamInterrupted, "\(kind) must preserve the public error")
            XCTAssertEqual(attempt.requestCount, 1, "\(kind) must not replay after output")
            _ = try causeRecord(in: attempt.records, cause: "upstream_event")
            let logs = try serializedLogs(attempt.records)
            XCTAssertFalse(logs.contains("stream-secret-api-key"))
            XCTAssertFalse(logs.contains("private-upstream-detail"))
            XCTAssertFalse(logs.contains("partial"))
        }
    }

    func testOversizedSerializedSchemaIsRejectedBeforeNetworking() async throws {
        let schema = ProviderToolSchema(
            name: "oversized_schema",
            description: String(repeating: "private-schema-marker", count: 450_000)
        )
        let attempt = try await perform(kind: .openAIChat, body: Data(), tools: [schema])

        XCTAssertEqual(
            attempt.error as? ProviderError,
            .transport("Provider request exceeds bounded payload limit")
        )
        XCTAssertEqual(attempt.requestCount, 0)
        XCTAssertFalse(attempt.records.contains(where: { $0.action == "request.attempt" }))
        let rejected = try XCTUnwrap(attempt.records.first(where: { $0.action == "request.payload-limit" }))
        XCTAssertEqual(rejected.result, "rejected")
        XCTAssertEqual(rejected.metadata["providerPayloadLimitBytes"], String(8 * 1024 * 1024))
        let actualBytes = Int(try XCTUnwrap(rejected.metadata["providerPayloadBytes"])) ?? 0
        XCTAssertGreaterThan(actualBytes, 8 * 1024 * 1024)
        let logs = try serializedLogs(attempt.records)
        XCTAssertFalse(logs.contains("private-schema-marker"))
        XCTAssertFalse(logs.contains("stream-secret-api-key"))
    }

    func testGatewayRecoveryRejectsLatestUserAboveBudgetWithoutSecondRequest() async throws {
        let latestUser = String(repeating: "x", count: 49_500) + "PRIVATE_LATEST_USER_MARKER"
        let attempt = try await perform(
            kind: .openAIChat,
            body: Data("temporary gateway overload".utf8),
            statusCode: 503,
            messages: [ChatMessage(role: .user, content: latestUser)]
        )

        XCTAssertEqual(
            attempt.error as? ProviderError,
            .transport("Gateway recovery context exceeds bounded payload limit")
        )
        XCTAssertEqual(attempt.requestCount, 1)
        let requestAttempts = attempt.records.filter { $0.action == "request.attempt" }
        XCTAssertEqual(requestAttempts.count, 1)
        let firstRequestBytes = Int(requestAttempts.first?.metadata["requestBodyBytes"] ?? "0") ?? 0
        XCTAssertGreaterThan(firstRequestBytes, 48_000)
        XCTAssertLessThanOrEqual(firstRequestBytes, 80_000)
        let rejectedContext = try XCTUnwrap(attempt.records.first(where: { $0.action == "request.context-limit" }))
        XCTAssertEqual(rejectedContext.result, "rejected")
        let estimatedCharacters = Int(rejectedContext.metadata["providerContextEstimatedCharacters"] ?? "0") ?? 0
        XCTAssertGreaterThan(estimatedCharacters, 48_000)
        let logs = try serializedLogs(attempt.records)
        XCTAssertFalse(logs.contains("PRIVATE_LATEST_USER_MARKER"))
        XCTAssertFalse(logs.contains("stream-secret-api-key"))
    }

    private func perform(
        kind: ProviderStreamTestKind,
        body: Data,
        statusCode: Int = 200,
        failureCode: URLError.Code? = nil,
        tools: [ProviderToolSchema] = [],
        messages: [ChatMessage] = [ChatMessage(role: .user, content: "prompt")]
    ) async throws -> ProviderStreamAttempt {
        ProviderStreamCauseURLProtocol.install(body: body, statusCode: statusCode, failureCode: failureCode)
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderStreamCauseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let logger = DiagnosticLogStore(directory: logDirectory)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderStreamCauseURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = kind.makeClient(session: session, logger: logger)
        let configuration = ProviderConfiguration(
            name: "Provider stream cause test",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "test-model",
            apiKeyReference: "test-key",
            providerID: "provider-stream-test",
            protocolName: kind.protocolName
        )

        var output = ""
        var failure: Error?
        do {
            for try await event in client.stream(
                configuration: configuration,
                apiKey: "stream-secret-api-key",
                messages: messages,
                tools: tools
            ) {
                if case .token(let token) = event { output += token }
            }
        } catch {
            failure = error
        }

        let records = try await logger.readAll()
        return ProviderStreamAttempt(
            output: output,
            error: failure,
            requestCount: ProviderStreamCauseURLProtocol.requestCount(),
            records: records
        )
    }

    private func event(_ payload: String) -> Data {
        Data("data: \(payload)\n\n".utf8)
    }

    private func causeRecord(in records: [DiagnosticLogRecord], cause: String) throws -> DiagnosticLogRecord {
        let record = try XCTUnwrap(records.first(where: { $0.action == "request.stream-cause" }))
        XCTAssertEqual(record.result, cause)
        XCTAssertEqual(record.metadata["cause"], cause)
        XCTAssertNil(record.diagnostic)
        return record
    }

    private func serializedLogs(_ records: [DiagnosticLogRecord]) throws -> String {
        String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    }
}

private struct ProviderStreamAttempt {
    let output: String
    let error: Error?
    let requestCount: Int
    let records: [DiagnosticLogRecord]
}

private enum ProviderStreamTestKind: CaseIterable {
    case openAIChat
    case anthropic
    case responses

    var protocolName: String {
        switch self {
        case .openAIChat: return ProviderProtocol.openAIChat.rawValue
        case .anthropic: return ProviderProtocol.anthropic.rawValue
        case .responses: return ProviderProtocol.openAIResponses.rawValue
        }
    }

    var partialOutput: String {
        switch self {
        case .openAIChat:
            return #"{"choices":[{"delta":{"content":"partial"}}]}"#
        case .anthropic:
            return #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#
        case .responses:
            return #"{"type":"response.output_text.delta","delta":"partial"}"#
        }
    }

    var upstreamError: String {
        switch self {
        case .openAIChat:
            return #"{"error":{"message":"private-upstream-detail"}}"#
        case .anthropic:
            return #"{"type":"error","error":{"message":"private-upstream-detail"}}"#
        case .responses:
            return #"{"type":"error","error":{"message":"private-upstream-detail"}}"#
        }
    }

    func makeClient(session: URLSession, logger: DiagnosticLogStore) -> any ProviderStreaming {
        let retryPolicy = RetryPolicy(maxAttempts: 3, initialDelayNanoseconds: 0)
        switch self {
        case .openAIChat:
            return OpenAICompatibleProviderClient(session: session, retryPolicy: retryPolicy, diagnosticLogger: logger)
        case .anthropic:
            return AnthropicProviderClient(session: session, retryPolicy: retryPolicy, diagnosticLogger: logger)
        case .responses:
            return OpenAIResponsesProviderClient(session: session, retryPolicy: retryPolicy, diagnosticLogger: logger)
        }
    }
}

private final class ProviderStreamCauseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseBody = Data()
    private static var responseStatusCode = 200
    private static var streamFailureCode: URLError.Code?
    private static var capturedRequestCount = 0

    static func install(body: Data, statusCode: Int = 200, failureCode: URLError.Code? = nil) {
        lock.lock()
        responseBody = body
        responseStatusCode = statusCode
        streamFailureCode = failureCode
        capturedRequestCount = 0
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let body = Self.responseBody
        let statusCode = Self.responseStatusCode
        let failureCode = Self.streamFailureCode
        Self.capturedRequestCount += 1
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        if let failureCode {
            client?.urlProtocol(self, didFailWithError: URLError(failureCode))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
