import Foundation
import XCTest
@testable import CloudCodeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProviderDiscoveryCatalogEvidenceTests: XCTestCase {
    func testNonemptyDirectCatalogIsSeparateFromValidatedInferenceOrder() async throws {
        let host = installPlan(
            models: .json(#"{"data":[{"id":"catalog-one"},{"id":"catalog-two"}]}"#),
            inference: .json(#"{"choices":[{}]}"#)
        )
        let session = makeSession()
        defer { session.invalidateAndCancel(); ProviderDiscoveryCatalogEvidenceURLProtocol.removePlan(for: host) }

        let result = try await discover(
            session: session,
            host: host,
            fallbackInferenceCandidates: ["manual-model"]
        )

        XCTAssertEqual(result.readiness, .ready)
        XCTAssertEqual(result.models, ["manual-model", "catalog-one", "catalog-two"])
        XCTAssertEqual(result.authoritativeModels, ["catalog-one", "catalog-two"])
    }

    func testEmptyDirectCatalogRemainsAuthoritativeWhenFallbackModelValidates() async throws {
        let host = installPlan(
            models: .json(#"{"data":[]}"#),
            inference: .json(#"{"choices":[{}]}"#)
        )
        let session = makeSession()
        defer { session.invalidateAndCancel(); ProviderDiscoveryCatalogEvidenceURLProtocol.removePlan(for: host) }

        let result = try await discover(
            session: session,
            host: host,
            fallbackInferenceCandidates: ["manual-model"]
        )

        XCTAssertEqual(result.readiness, .ready)
        XCTAssertEqual(result.models, ["manual-model"])
        XCTAssertEqual(result.authoritativeModels, [])
    }

    func testDirectCatalogEvidenceSurvivesCapacityAndInconclusiveProbeResults() async throws {
        let directCatalog = #"{"data":[{"id":"catalog-model"}]}"#
        let cases: [(EvidenceResponse, ProviderReadiness)] = [
            (.json(#"{"error":{"message":"insufficient quota"}}"#, status: 402), .capacity),
            (.json(#"{"error":{"message":"invalid request"}}"#, status: 400), .needsValidation)
        ]

        for (inferenceResponse, expectedReadiness) in cases {
            let host = installPlan(models: .json(directCatalog), inference: inferenceResponse)
            let session = makeSession()
            defer { session.invalidateAndCancel(); ProviderDiscoveryCatalogEvidenceURLProtocol.removePlan(for: host) }

            let result = try await discover(session: session, host: host)

            XCTAssertEqual(result.readiness, expectedReadiness)
            XCTAssertEqual(result.authoritativeModels, ["catalog-model"])
        }
    }

    func testPricingFallbackModelsAreNotReportedAsAuthoritative() async throws {
        let host = installPlan(
            models: .json(#"{"error":{"message":"unauthorized"}}"#, status: 401),
            pricing: .json(#"{"data":[{"id":"pricing-model"}]}"#),
            inference: .json(#"{"error":{"message":"invalid request"}}"#, status: 400)
        )
        let session = makeSession()
        defer { session.invalidateAndCancel(); ProviderDiscoveryCatalogEvidenceURLProtocol.removePlan(for: host) }

        let result = try await discover(session: session, host: host, allowPricingCatalogFallback: true)

        XCTAssertEqual(result.models, ["pricing-model"])
        XCTAssertNil(result.authoritativeModels)
    }

    func testRatioConfigFallbackModelsAreNotReportedAsAuthoritative() async throws {
        let host = installPlan(
            models: .json(#"{"error":{"message":"unauthorized"}}"#, status: 401),
            pricing: .json(#"{"error":{"message":"not found"}}"#, status: 404),
            ratio: .json(#"{"data":{"model_ratio":{"ratio-model":1.0}}}"#),
            inference: .json(#"{"error":{"message":"invalid request"}}"#, status: 400)
        )
        let session = makeSession()
        defer { session.invalidateAndCancel(); ProviderDiscoveryCatalogEvidenceURLProtocol.removePlan(for: host) }

        let result = try await discover(session: session, host: host, allowPricingCatalogFallback: true)

        XCTAssertEqual(result.models, ["ratio-model"])
        XCTAssertNil(result.authoritativeModels)
    }

    private func installPlan(
        models: EvidenceResponse,
        pricing: EvidenceResponse = .json(#"{"error":{"message":"not found"}}"#, status: 404),
        ratio: EvidenceResponse = .json(#"{"error":{"message":"not found"}}"#, status: 404),
        inference: EvidenceResponse = .json(#"{"error":{"message":"invalid request"}}"#, status: 400)
    ) -> String {
        let host = "catalog-evidence-\(UUID().uuidString.lowercased()).test"
        ProviderDiscoveryCatalogEvidenceURLProtocol.install(
            host: host,
            plan: EvidencePlan(models: models, pricing: pricing, ratio: ratio, inference: inference)
        )
        return host
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderDiscoveryCatalogEvidenceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func discover(
        session: URLSession,
        host: String,
        allowPricingCatalogFallback: Bool = false,
        fallbackInferenceCandidates: [String] = []
    ) async throws -> ProviderDiscoveryResult {
        try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://\(host)/v1")!,
            apiKey: "test-secret",
            preferredAuthMode: .bearer,
            allowPricingCatalogFallback: allowPricingCatalogFallback,
            fallbackInferenceCandidates: fallbackInferenceCandidates,
            inferenceProtocols: [.openAIChat],
            allowAlternateAuthModes: false
        )
    }
}

private struct EvidenceResponse {
    var statusCode: Int
    var body: Data

    static func json(_ text: String, status: Int = 200) -> EvidenceResponse {
        EvidenceResponse(statusCode: status, body: Data(text.utf8))
    }
}

private struct EvidencePlan {
    var models: EvidenceResponse
    var pricing: EvidenceResponse
    var ratio: EvidenceResponse
    var inference: EvidenceResponse

    func response(for request: URLRequest) -> EvidenceResponse {
        guard let method = request.httpMethod, let requestPath = request.url?.path else {
            return .json(#"{"error":{"message":"not found"}}"#, status: 404)
        }
        switch (method, requestPath) {
        case ("GET", let path) where path.hasSuffix("/models"):
            return models
        case ("GET", "/api/pricing"):
            return pricing
        case ("GET", "/api/ratio_config"):
            return ratio
        case ("POST", _):
            return inference
        default:
            return .json(#"{"error":{"message":"not found"}}"#, status: 404)
        }
    }
}

private final class ProviderDiscoveryCatalogEvidenceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var plans: [String: EvidencePlan] = [:]

    static func install(host: String, plan: EvidencePlan) {
        lock.lock()
        plans[host] = plan
        lock.unlock()
    }

    static func removePlan(for host: String) {
        lock.lock()
        plans.removeValue(forKey: host)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let plan = Self.plans[url.host ?? ""]
        Self.lock.unlock()
        guard let plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let responsePlan = plan.response(for: request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: responsePlan.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responsePlan.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
