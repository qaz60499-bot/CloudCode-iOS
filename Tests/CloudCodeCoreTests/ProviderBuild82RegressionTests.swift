import Foundation
import XCTest
@testable import CloudCodeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProviderBuild82RegressionTests: XCTestCase {
    func testRouteFailureAggregatorRequiresAllRoutesToRejectAuthentication() {
        let allAuth = ProviderRouteFailureAggregator.preferredFailure([
            ProviderError.authenticationFailed(401),
            ProviderError.authenticationFailed(403)
        ])
        XCTAssertEqual(allAuth as? ProviderError, .authenticationFailed(403))

        let protocolMixed = ProviderRouteFailureAggregator.preferredFailure([
            ProviderError.protocolIncompatible("adapter mismatch"),
            ProviderError.authenticationFailed(401)
        ])
        XCTAssertEqual(protocolMixed as? ProviderError, .protocolIncompatible("adapter mismatch"))

        let timeout = URLError(.timedOut)
        let transportMixed = ProviderRouteFailureAggregator.preferredFailure([
            timeout,
            ProviderError.authenticationFailed(401)
        ])
        XCTAssertEqual((transportMixed as? URLError)?.code, .timedOut)

        let clientMixed = ProviderRouteFailureAggregator.preferredFailure([
            ProviderError.clientRejected(403),
            ProviderError.authenticationFailed(401)
        ])
        XCTAssertEqual(clientMixed as? ProviderError, .clientRejected(403))
    }

    func testOutOfBandKeyReplacementUsesSafeProtocolCandidatesInsteadOfStaleExactEvidence() async throws {
        let recorder = Build82ProtocolRecorder()
        let router = ProviderClientRouter(
            keyVault: MemoryKeyVault(),
            anthropic: recorder,
            openAIChat: recorder,
            responses: recorder
        )
        let configuration = ProviderConfiguration(
            name: "Compatible",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "model-a",
            apiKeyReference: "primary",
            providerID: "compatible-provider",
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue,
            fallbackProtocolNames: [],
            protocolNamesByKeyReference: ["primary": [ProviderProtocol.anthropic.rawValue]],
            safeProtocolNamesByKeyReference: ["primary": [ProviderProtocol.openAIChat.rawValue, ProviderProtocol.anthropic.rawValue]],
            keyFingerprintsByReference: ["primary": String(repeating: "a", count: 64)],
            allowSameProviderKeyFailover: false
        )

        var output = ""
        for try await event in router.stream(configuration: configuration, apiKey: "replacement-key-content", messages: [], tools: []) {
            if case .token(let token) = event { output += token }
        }
        XCTAssertEqual(output, "ok")
        let seenProtocols = await recorder.protocolsSeen()
        XCTAssertEqual(seenProtocols, [ProviderProtocol.openAIChat.rawValue])
    }

    func testDiscoveryRejectsNonAPIHTTP200AsInferenceReadiness() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Build82NonAPI200URLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://agentrouter.org")!,
            apiKey: "test-key",
            preferredAuthMode: .bearer,
            fallbackInferenceCandidates: ["glm-5.3"],
            inferenceProtocols: [.anthropic, .openAIChat],
            allowAlternateAuthModes: false
        )

        XCTAssertTrue(result.models.isEmpty)
        XCTAssertTrue(result.protocols.isEmpty)
        XCTAssertEqual(result.authMode, .bearer)
        XCTAssertEqual(result.readiness, .needsValidation)
    }

    func testDiscoveryCapacityIsNotInferenceReady() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Build82CapacityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://capacity.example/v1")!,
            apiKey: "test-key",
            preferredAuthMode: .bearer,
            inferenceProtocols: [.anthropic],
            allowAlternateAuthModes: false
        )

        XCTAssertEqual(result.models, ["model-capacity"])
        XCTAssertTrue(result.protocols.isEmpty)
        XCTAssertEqual(result.authMode, .bearer)
        XCTAssertEqual(result.readiness, .capacity)
    }

    func testKeyFingerprintChangeRestoresBuiltInSelectableBaseline() throws {
        var provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.agentRouterID }))
        let baseline = provider.models(for: "slot-1")
        XCTAssertFalse(baseline.isEmpty)

        provider.applyLiveModelCatalog(["live-only-model"], keySlotID: "slot-1", authoritative: true)
        XCTAssertEqual(provider.models(for: "slot-1"), ["live-only-model"])

        provider.updateKeyFingerprint(String(repeating: "b", count: 64), keySlotID: "slot-1", status: .needsValidation)
        XCTAssertEqual(provider.models(for: "slot-1"), baseline)
        XCTAssertFalse(provider.models(for: "slot-1").contains("live-only-model"))
        XCTAssertEqual(provider.keySlots.first(where: { $0.id == "slot-1" })?.status, .needsValidation)
        XCTAssertTrue(provider.keySlots.first(where: { $0.id == "slot-1" })?.modelProtocols.isEmpty == true)
    }

    func testGenericRequestShapeErrorsDoNotPersistCompatibilityDrift() {
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(400)))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(422)))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(404)))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(405)))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.malformedEvent))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.protocolIncompatible("wire mismatch")))
    }

    func testContentBlockIsNotCompatibilityEnvelopeFallback() {
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryAgentRouterCompatibilityEnvelope(
            providerID: ProviderCatalog.agentRouterID,
            statusCode: 400,
            body: Data("{\"error\":\"content-blocked\"}".utf8),
            messageCount: 3,
            toolCount: 2
        ))
    }

    func testTransientOrRouteScopedFailuresDoNotDegradeProviderWideHealth() {
        XCTAssertFalse(ProviderEndpointHealthClassifier.shouldMarkDegraded(ProviderError.authenticationFailed(401)))
        XCTAssertFalse(ProviderEndpointHealthClassifier.shouldMarkDegraded(ProviderError.rateLimited))
        XCTAssertFalse(ProviderEndpointHealthClassifier.shouldMarkDegraded(ProviderError.malformedEvent))
        XCTAssertFalse(ProviderEndpointHealthClassifier.shouldMarkDegraded(ProviderError.streamInterrupted))
        XCTAssertTrue(ProviderEndpointHealthClassifier.shouldMarkDegraded(ProviderError.invalidResponse(503)))
    }
}

private actor Build82ProtocolRecorder: ProviderStreaming {
    private var seen: [String] = []

    func protocolsSeen() -> [String] { seen }

    nonisolated func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(configuration.protocolName ?? "")
                continuation.yield(.token("ok"))
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    private func record(_ protocolName: String) {
        seen.append(protocolName)
    }
}

private final class Build82NonAPI200URLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Data("<html><body>AgentRouter</body></html>".utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class Build82CapacityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isCatalog = url.path.hasSuffix("/models")
        let status = isCatalog ? 200 : 403
        let body = isCatalog
            ? Data("{\"data\":[{\"id\":\"model-capacity\"}]}".utf8)
            : Data("{\"error\":\"insufficient_user_quota\"}".utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
