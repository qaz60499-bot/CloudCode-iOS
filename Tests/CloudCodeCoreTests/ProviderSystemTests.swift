import Foundation
import XCTest
@testable import CloudCodeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProviderCatalogTests: XCTestCase {
    func testDesktopSnapshotContainsOnlyRequestedProviders() {
        let profiles = ProviderCatalog.desktopSnapshot
        XCTAssertEqual(profiles.count, 10)
        XCTAssertFalse(profiles.contains { $0.id.lowercased().contains("seekai") || $0.displayName.lowercased().contains("seekai") })
        XCTAssertTrue(profiles.allSatisfy(\.enabled))
        XCTAssertNotNil(profiles.first(where: { $0.id == ProviderCatalog.tabitokenID }))
    }

    func testDesktopSnapshotKeyCountsMatchCurrentEnabledRegistrySnapshot() {
        let counts = Dictionary(uniqueKeysWithValues: ProviderCatalog.desktopSnapshot.map { ($0.id, $0.keySlots.count) })
        XCTAssertEqual(counts["tabitoken"], 5)
        XCTAssertEqual(counts["https-ai-fsykk-cn"], 1)
        XCTAssertEqual(counts["ccs-7bdd07431575"], 5)
        XCTAssertEqual(counts["https-api-denxio-top"], 1)
        XCTAssertEqual(counts["https-api-justwoker-icu"], 1)
        XCTAssertEqual(counts["https-sharellm-cn"], 2)
        XCTAssertEqual(counts["https-agentrouter-org"], 1)
        XCTAssertEqual(counts["https-sirthisway-icu"], 5)
        XCTAssertEqual(counts["https-vyceai-com"], 1)
        XCTAssertEqual(counts["https-free-supxh-xin"], 1)
        XCTAssertEqual(ProviderCatalog.desktopSnapshot.reduce(0) { $0 + $1.keySlots.count }, 23)
    }

    func testTabitokenHasFourModelsFiveKeySlotsAndNativeAnthropicRouting() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.tabitokenID }))
        XCTAssertEqual(provider.baseURL.absoluteString, "https://tabitoken.com")
        XCTAssertEqual(provider.models, [
            "claude-opus-5",
            "claude-opus-5-thinking",
            "claude-opus-4-8",
            "claude-opus-4-8-thinking"
        ])
        XCTAssertEqual(provider.keySlots.count, 5)
        XCTAssertTrue(provider.keySlots.allSatisfy { $0.models == provider.models })
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-5", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.authMode, .both)
        XCTAssertTrue(provider.autoRotateKeys)
    }

    func testPerKeyModelScopeOverridesProviderCatalog() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-sharellm-cn" }))
        let key1 = provider.models(for: "slot-1")
        let key2 = provider.models(for: "slot-2")
        XCTAssertFalse(key1.isEmpty)
        XCTAssertFalse(key2.isEmpty)
        XCTAssertNotEqual(key1, key2)
        XCTAssertFalse(key1.contains("claude-opus-5"))
        XCTAssertTrue(key2.contains("claude-opus-5"))
    }

    func testProviderSwitchClearsOldKeyAndInvalidModel() throws {
        let profiles = ProviderCatalog.desktopSnapshot
        let goRouter = try XCTUnwrap(profiles.first(where: { $0.displayName == "gorouter.app" }))
        let initial = ProviderSelectionState(providerID: goRouter.id, keySlotID: "slot-5", model: "claude-opus-5")
        let free = try XCTUnwrap(profiles.first(where: { $0.displayName == "free.supxh.xin" }))
        let switched = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: free.id, keySlotID: initial.keySlotID, model: initial.model),
            profiles: profiles
        )
        XCTAssertEqual(switched.providerID, free.id)
        XCTAssertEqual(switched.keySlotID, "slot-1")
        XCTAssertEqual(switched.model, free.models.first)
        XCTAssertNotEqual(switched.model, initial.model)
    }

    func testKeySwitchReScopesModel() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-sharellm-cn" }))
        let key2OnlyModel = "claude-opus-5"
        XCTAssertTrue(provider.models(for: "slot-2").contains(key2OnlyModel))
        XCTAssertFalse(provider.models(for: "slot-1").contains(key2OnlyModel))
        let state = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: provider.id, keySlotID: "slot-1", model: key2OnlyModel),
            profiles: [provider]
        )
        XCTAssertEqual(state.keySlotID, "slot-1")
        XCTAssertEqual(state.model, provider.models(for: "slot-1").first)
    }

    func testSelectionStateRoundTripsAcrossRestart() throws {
        let original = ProviderSelectionState(providerID: "tabitoken", keySlotID: "slot-3", model: "claude-opus-4-8-thinking")
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ProviderSelectionState.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(ProviderSelectionResolver.reconcile(restored, profiles: ProviderCatalog.desktopSnapshot), original)
    }

    func testSelectionReconciliationStressAlwaysProducesValidScopedState() throws {
        let profiles = ProviderCatalog.desktopSnapshot
        XCTAssertFalse(profiles.isEmpty)
        for iteration in 0..<2_000 {
            let provider = profiles[iteration % profiles.count]
            let invalidState = ProviderSelectionState(
                providerID: provider.id,
                keySlotID: "stale-key-\(iteration % 17)",
                model: "stale-model-\(iteration % 29)"
            )
            let reconciled = ProviderSelectionResolver.reconcile(invalidState, profiles: profiles)
            let selectedProvider = try XCTUnwrap(profiles.first(where: { $0.id == reconciled.providerID }))
            XCTAssertTrue(selectedProvider.keySlots.contains(where: { $0.id == reconciled.keySlotID }))
            XCTAssertTrue(selectedProvider.models(for: reconciled.keySlotID).contains(reconciled.model))
        }
    }
}

final class ProviderRouterTests: XCTestCase {
    func testRouterSelectsAnthropic() async throws {
        let vault = MemoryKeyVault()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: FixedProvider(token: "anthropic"),
            openAIChat: FixedProvider(token: "chat"),
            responses: FixedProvider(token: "responses")
        )
        let text = try await collectText(router.stream(
            configuration: config(protocolName: .anthropic),
            apiKey: "primary",
            messages: [],
            tools: []
        ))
        XCTAssertEqual(text, "anthropic")
    }

    func testRouterSelectsOpenAIChat() async throws {
        let vault = MemoryKeyVault()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: FixedProvider(token: "anthropic"),
            openAIChat: FixedProvider(token: "chat"),
            responses: FixedProvider(token: "responses")
        )
        let text = try await collectText(router.stream(
            configuration: config(protocolName: .openAIChat),
            apiKey: "primary",
            messages: [],
            tools: []
        ))
        XCTAssertEqual(text, "chat")
    }

    func testRouterSelectsOpenAIResponses() async throws {
        let vault = MemoryKeyVault()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: FixedProvider(token: "anthropic"),
            openAIChat: FixedProvider(token: "chat"),
            responses: FixedProvider(token: "responses")
        )
        let text = try await collectText(router.stream(
            configuration: config(protocolName: .openAIResponses),
            apiKey: "primary",
            messages: [],
            tools: []
        ))
        XCTAssertEqual(text, "responses")
    }

    func testSameProviderAuthenticationFailureRotatesToNextKey() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: KeyOutcomeProvider(),
            openAIChat: KeyOutcomeProvider(),
            responses: KeyOutcomeProvider()
        )
        var configuration = config(protocolName: .anthropic)
        configuration.apiKeyReference = "primary"
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true
        let text = try await collectText(router.stream(configuration: configuration, apiKey: "bad-auth", messages: [], tools: []))
        XCTAssertEqual(text, "good")
    }

    func testSameRequestKeepsSuccessfulFallbackForLaterToolRound() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let recorder = RecordingKeyOutcomeProvider()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: recorder,
            openAIChat: recorder,
            responses: recorder
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true

        let firstText = try await collectText(router.stream(configuration: configuration, apiKey: "bad-auth", messages: [], tools: []))
        let secondText = try await collectText(router.stream(configuration: configuration, apiKey: "bad-auth", messages: [], tools: []))
        let seenKeys = await recorder.keysSeen()
        XCTAssertEqual(firstText, "good")
        XCTAssertEqual(secondText, "good")
        XCTAssertEqual(seenKeys, ["bad-auth", "good", "good"])
    }

    func testSameProviderCapacityFailureRotatesToNextKey() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: KeyOutcomeProvider(),
            openAIChat: KeyOutcomeProvider(),
            responses: KeyOutcomeProvider()
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true
        let text = try await collectText(router.stream(configuration: configuration, apiKey: "no-quota", messages: [], tools: []))
        XCTAssertEqual(text, "good")
    }

    func test429DoesNotRotateKey() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: KeyOutcomeProvider(),
            openAIChat: KeyOutcomeProvider(),
            responses: KeyOutcomeProvider()
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true
        do {
            _ = try await collectText(router.stream(configuration: configuration, apiKey: "rate-limit", messages: [], tools: []))
            XCTFail("429 must stay on the selected Provider/Key channel")
        } catch {
            XCTAssertEqual(error as? ProviderError, .rateLimited)
        }
    }

    func test5xxDoesNotRotateKey() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: KeyOutcomeProvider(),
            openAIChat: KeyOutcomeProvider(),
            responses: KeyOutcomeProvider()
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true
        do {
            _ = try await collectText(router.stream(configuration: configuration, apiKey: "server-error", messages: [], tools: []))
            XCTFail("5xx is provider/network evidence, not bad-Key evidence")
        } catch {
            XCTAssertEqual(error as? ProviderError, .invalidResponse(503))
        }
    }

    func testRotationDisabledNeverUsesFallback() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: KeyOutcomeProvider(),
            openAIChat: KeyOutcomeProvider(),
            responses: KeyOutcomeProvider()
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = false
        do {
            _ = try await collectText(router.stream(configuration: configuration, apiKey: "bad-auth", messages: [], tools: []))
            XCTFail("Disabled failover must not switch Keys")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationFailed(401))
        }
    }

    func testOutputThenFailureDoesNotRotate() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: PartialThenFailureProvider(),
            openAIChat: PartialThenFailureProvider(),
            responses: PartialThenFailureProvider()
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true
        var text = ""
        do {
            for try await event in router.stream(configuration: configuration, apiKey: "partial", messages: [], tools: []) {
                if case .token(let token) = event { text += token }
            }
            XCTFail("Partial stream must surface interruption")
        } catch {
            XCTAssertEqual(error as? ProviderError, .streamInterrupted)
        }
        XCTAssertEqual(text, "partial")
    }

    func testConcurrentSameProviderFailoverIsStable() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: KeyOutcomeProvider(),
            openAIChat: KeyOutcomeProvider(),
            responses: KeyOutcomeProvider()
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true

        let outputs = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    try await collectText(router.stream(
                        configuration: configuration,
                        apiKey: "bad-auth",
                        messages: [],
                        tools: []
                    ))
                }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outputs.count, 64)
        XCTAssertTrue(outputs.allSatisfy { $0 == "good" })
    }

    func testSuccessfulFallbackPreferenceDoesNotLeakAcrossConfigurations() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        let recorder = RecordingKeyOutcomeProvider()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: recorder,
            openAIChat: recorder,
            responses: recorder
        )
        var first = config(protocolName: .anthropic)
        first.fallbackAPIKeyReferences = ["fallback"]
        first.allowSameProviderKeyFailover = true
        var second = config(protocolName: .anthropic)
        second.fallbackAPIKeyReferences = ["fallback"]
        second.allowSameProviderKeyFailover = true

        XCTAssertNotEqual(first.id, second.id)
        let firstOutput = try await collectText(router.stream(configuration: first, apiKey: "bad-auth", messages: [], tools: []))
        let secondOutput = try await collectText(router.stream(configuration: second, apiKey: "bad-auth", messages: [], tools: []))
        let seen = await recorder.keysSeen()
        XCTAssertEqual(firstOutput, "good")
        XCTAssertEqual(secondOutput, "good")
        XCTAssertEqual(seen, ["bad-auth", "good", "bad-auth", "good"])
    }

    private func config(protocolName: ProviderProtocol) -> ProviderConfiguration {
        ProviderConfiguration(
            name: "Test",
            baseURL: URL(string: "https://example.com")!,
            model: "model",
            apiKeyReference: "primary",
            providerID: "test",
            protocolName: protocolName.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue,
            fallbackAPIKeyReferences: [],
            allowSameProviderKeyFailover: false
        )
    }
}

final class ProviderDiscoveryTests: XCTestCase {
    override func tearDown() {
        ProviderDiscoveryURLProtocol.reset()
        super.tearDown()
    }

    func testDiscoveryFindsInferenceAuthModeInsteadOfTrustingModelsEndpointAlone() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderDiscoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://custom.example")!,
            apiKey: "test-secret"
        )
        XCTAssertEqual(result.models, ["model-a"])
        XCTAssertEqual(result.authMode, .both)
        XCTAssertEqual(result.protocols, [.anthropic])
        XCTAssertEqual(result.readiness, .ready)
    }
}

final class ProviderProtocolClientTests: XCTestCase {
    override func tearDown() {
        ProviderTestURLProtocol.reset()
        super.tearDown()
    }

    func testAnthropicStreamingTextToolAndTabitokenDualAuth() async throws {
        let body = Data("""
        data: {"type":"message_start","message":{"id":"m1"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"files.read","input":{}}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"/tmp/a\\"}"}}

        data: {"type":"message_stop"}

        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
        let client = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(
            name: "Tabitoken",
            baseURL: URL(string: "https://tabitoken.com")!,
            model: "claude-opus-5",
            apiKeyReference: "tabi",
            providerID: "tabitoken",
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.both.rawValue
        )
        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: configuration, apiKey: "test-secret", messages: [ChatMessage(role: .user, content: "hi")], tools: [ProviderToolSchema(name: "files.read", description: "read", properties: ["path": "string"])]) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("hello")))
        XCTAssertTrue(events.contains(.toolCall(id: "tool-1", name: "files.read", argumentsJSON: "{\"path\":\"/tmp/a\"}")))
        XCTAssertEqual(events.last, .finished)
        let request = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://tabitoken.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testResponsesStreamingTextAndToolCall() async throws {
        let body = Data("""
        data: {"type":"response.output_text.delta","delta":"ok"}

        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"item-1","call_id":"call-1","name":"files.read","arguments":""}}

        data: {"type":"response.function_call_arguments.delta","item_id":"item-1","delta":"{\\"path\\":\\"/x\\"}"}

        data: {"type":"response.completed"}

        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
        let client = OpenAIResponsesProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(
            name: "Responses",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "gpt-test",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIResponses.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue
        )
        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("ok")))
        XCTAssertTrue(events.contains(.toolCall(id: "call-1", name: "files.read", argumentsJSON: "{\"path\":\"/x\"}")))
        XCTAssertEqual(ProviderTestURLProtocol.lastRequest()?.url?.absoluteString, "https://example.com/v1/responses")
    }

    func testHTTP403QuotaIsCapacityNotCredentialFailure() {
        let body = Data("{\"error\":\"insufficient_user_quota\"}".utf8)
        XCTAssertEqual(ProviderHTTPClassifier.error(for: 403, body: body), .capacityExhausted(403))
    }

    func testHTTP403InvalidKeyIsCredentialFailure() {
        let body = Data("{\"error\":\"invalid api key\"}".utf8)
        XCTAssertEqual(ProviderHTTPClassifier.error(for: 403, body: body), .authenticationFailed(403))
    }

    func testHTTP429NeverBecomesCredentialFailure() {
        let body = Data("{\"error\":\"quota exhausted\"}".utf8)
        XCTAssertEqual(ProviderHTTPClassifier.error(for: 429, body: body), .rateLimited)
    }

    func testAmbiguous403DoesNotBecomeCredentialFailureOrTriggerKeyRotation() {
        let error = ProviderHTTPClassifier.error(for: 403, body: Data())
        XCTAssertEqual(error, .invalidResponse(403))
        XCTAssertFalse(ProviderKeyRotationClassifier.shouldRotate(try! XCTUnwrap(error)))
    }

    func testProviderEndpointPolicyRejectsLoopbackAndAmbiguousURLs() {
        XCTAssertTrue(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://api.example.com")!))
        XCTAssertTrue(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://api.example.com/v1")!))
        XCTAssertFalse(ProviderEndpointPolicy.allowsBaseURL(URL(string: "http://api.example.com")!))
        XCTAssertFalse(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://localhost:8443")!))
        XCTAssertFalse(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://127.0.0.1")!))
        XCTAssertFalse(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://[::1]")!))
        XCTAssertFalse(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://user:pass@api.example.com")!))
        XCTAssertFalse(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://api.example.com?v=1")!))
        XCTAssertFalse(ProviderEndpointPolicy.allowsBaseURL(URL(string: "https://api.example.com#fragment")!))
    }

    func testProviderRedirectPolicyAllowsOnlySameOrigin() {
        let original = URL(string: "https://api.example.com/v1/messages")!
        XCTAssertTrue(ProviderRedirectPolicy.allows(
            original: original,
            destination: URL(string: "https://api.example.com/v2/messages")!
        ))
        XCTAssertTrue(ProviderRedirectPolicy.allows(
            original: original,
            destination: URL(string: "https://api.example.com:443/redirected")!
        ))
        XCTAssertFalse(ProviderRedirectPolicy.allows(
            original: original,
            destination: URL(string: "https://evil.example.net/steal")!
        ))
        XCTAssertFalse(ProviderRedirectPolicy.allows(
            original: original,
            destination: URL(string: "http://api.example.com/v1/messages")!
        ))
        XCTAssertFalse(ProviderRedirectPolicy.allows(
            original: original,
            destination: URL(string: "https://api.example.com:8443/v1/messages")!
        ))
    }

    private func testSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class ProviderKeychainTests: XCTestCase {
    func testMultiProviderMultiKeyOverwriteMissingAndRestartPersistence() async throws {
        let service = "CloudCodeIOS.Tests.\(UUID().uuidString)"
        let vault = KeychainAPIKeyVault(service: service)
        let a1 = "provider-a-key-1-\(UUID().uuidString)"
        let a2 = "provider-a-key-2-\(UUID().uuidString)"
        let b1 = "provider-b-key-1-\(UUID().uuidString)"
        defer {
            try? vault.remove("a1")
            try? vault.remove("a2")
            try? vault.remove("b1")
        }
        try vault.set(a1, for: "a1")
        try vault.set(a2, for: "a2")
        try vault.set(b1, for: "b1")
        let loadedA1 = try await vault.key(for: "a1")
        let loadedA2 = try await vault.key(for: "a2")
        let loadedB1 = try await vault.key(for: "b1")
        XCTAssertEqual(loadedA1, a1)
        XCTAssertEqual(loadedA2, a2)
        XCTAssertEqual(loadedB1, b1)

        let replacement = "replacement-\(UUID().uuidString)"
        try vault.set(replacement, for: "a1")
        let loadedReplacement = try await vault.key(for: "a1")
        XCTAssertEqual(loadedReplacement, replacement)

        let restartedVault = KeychainAPIKeyVault(service: service)
        let restartedReplacement = try await restartedVault.key(for: "a1")
        XCTAssertEqual(restartedReplacement, replacement)
        XCTAssertTrue(restartedVault.contains("a2"))

        try restartedVault.remove("a2")
        do {
            _ = try await restartedVault.key(for: "a2")
            XCTFail("Removed Key must be missing")
        } catch {
            XCTAssertEqual(error as? ProviderError, .missingAPIKey)
        }
    }

    func testKeyValueDoesNotNeedUserDefaultsPersistence() async throws {
        let service = "CloudCodeIOS.Tests.\(UUID().uuidString)"
        let vault = KeychainAPIKeyVault(service: service)
        let secret = "defaults-guard-\(UUID().uuidString)"
        defer { try? vault.remove("key") }
        try vault.set(secret, for: "key")
        let loadedSecret = try await vault.key(for: "key")
        XCTAssertEqual(loadedSecret, secret)
        let serializedDefaults = UserDefaults.standard.dictionaryRepresentation().values.map(String.init(describing:)).joined(separator: "\n")
        XCTAssertFalse(serializedDefaults.contains(secret))
    }

    func testRepeatedKeychainOverwriteReadAndDeleteRemainsConsistent() async throws {
        let service = "CloudCodeIOS.Tests.\(UUID().uuidString)"
        let vault = KeychainAPIKeyVault(service: service)
        defer { try? vault.remove("stress") }
        for iteration in 0..<40 {
            let value = "stress-value-\(iteration)-\(UUID().uuidString)"
            try vault.set(value, for: "stress")
            let loaded = try await vault.key(for: "stress")
            XCTAssertEqual(loaded, value)
            XCTAssertTrue(vault.contains("stress"))
        }
        try vault.remove("stress")
        XCTAssertFalse(vault.contains("stress"))
        do {
            _ = try await vault.key(for: "stress")
            XCTFail("Deleted stress Key must not remain readable")
        } catch {
            XCTAssertEqual(error as? ProviderError, .missingAPIKey)
        }
    }

    func testProvisioningSuccessCommitsAllKeys() async throws {
        let vault = FaultInjectingMutableVault(keys: ["a": "old-a"])
        let count = try await ProviderKeyProvisioner.apply([
            ProviderKeyMutation(reference: "a", secret: "new-a"),
            ProviderKeyMutation(reference: "b", secret: "new-b")
        ], vault: vault)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(vault.snapshot(), ["a": "new-a", "b": "new-b"])
    }

    func testProvisioningWriteFailureRestoresPreviousKeysAndRemovesNewKeys() async throws {
        let vault = FaultInjectingMutableVault(keys: ["a": "old-a"], failOnSetReference: "b")
        do {
            _ = try await ProviderKeyProvisioner.apply([
                ProviderKeyMutation(reference: "a", secret: "new-a"),
                ProviderKeyMutation(reference: "b", secret: "new-b")
            ], vault: vault)
            XCTFail("Injected write failure must fail provisioning")
        } catch {
            XCTAssertEqual(error as? ProviderError, .transport("injected write failure"))
        }
        XCTAssertEqual(vault.snapshot(), ["a": "old-a"])
    }

    func testProvisioningFinalizerFailureRollsBackCommittedKeychainWrites() async throws {
        let vault = FaultInjectingMutableVault(keys: ["a": "old-a"])
        do {
            _ = try await ProviderKeyProvisioner.apply([
                ProviderKeyMutation(reference: "a", secret: "new-a"),
                ProviderKeyMutation(reference: "b", secret: "new-b")
            ], vault: vault, finalizer: {
                throw ProviderError.transport("plaintext cleanup failed")
            })
            XCTFail("Finalizer failure must roll Keychain back")
        } catch {
            XCTAssertEqual(error as? ProviderError, .transport("plaintext cleanup failed"))
        }
        XCTAssertEqual(vault.snapshot(), ["a": "old-a"])
    }

    func testProvisioningDuplicateReferenceFailsBeforeAnyMutation() async throws {
        let vault = FaultInjectingMutableVault(keys: ["a": "old-a"])
        do {
            _ = try await ProviderKeyProvisioner.apply([
                ProviderKeyMutation(reference: "a", secret: "first"),
                ProviderKeyMutation(reference: "a", secret: "second")
            ], vault: vault)
            XCTFail("Duplicate reference must fail closed")
        } catch {
            XCTAssertEqual(error as? ProviderKeyProvisioningError, .duplicateReference("a"))
        }
        XCTAssertEqual(vault.snapshot(), ["a": "old-a"])
        XCTAssertEqual(vault.writeCount(), 0)
    }

    func testProvisioningVerificationFailureRollsBackAllKeys() async throws {
        let vault = FaultInjectingMutableVault(keys: ["a": "old-a"], corruptReadReferenceAfterWrite: "b")
        do {
            _ = try await ProviderKeyProvisioner.apply([
                ProviderKeyMutation(reference: "a", secret: "new-a"),
                ProviderKeyMutation(reference: "b", secret: "new-b")
            ], vault: vault)
            XCTFail("Read-back mismatch must fail provisioning")
        } catch {
            XCTAssertEqual(error as? ProviderKeyProvisioningError, .verificationFailed("b"))
        }
        XCTAssertEqual(vault.snapshot(), ["a": "old-a"])
    }

    func testProvisioningDoesNotTreatKeychainReadFailureAsMissingKey() async throws {
        let vault = FaultInjectingMutableVault(keys: ["a": "old-a"], failOnReadReference: "a")
        do {
            _ = try await ProviderKeyProvisioner.apply([
                ProviderKeyMutation(reference: "a", secret: "new-a")
            ], vault: vault)
            XCTFail("Read failure must abort before mutation")
        } catch {
            XCTAssertEqual(error as? ProviderError, .transport("injected read failure"))
        }
        XCTAssertEqual(vault.snapshot(), ["a": "old-a"])
        XCTAssertEqual(vault.writeCount(), 0)
    }
}


private final class FaultInjectingMutableVault: MutableAPIKeyVault, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CloudCodeIOS.Tests.FaultInjectingMutableVault")
    private var keys: [String: String]
    private let failOnSetReference: String?
    private let failOnReadReference: String?
    private let corruptReadReferenceAfterWrite: String?
    private var writes = 0

    init(
        keys: [String: String] = [:],
        failOnSetReference: String? = nil,
        failOnReadReference: String? = nil,
        corruptReadReferenceAfterWrite: String? = nil
    ) {
        self.keys = keys
        self.failOnSetReference = failOnSetReference
        self.failOnReadReference = failOnReadReference
        self.corruptReadReferenceAfterWrite = corruptReadReferenceAfterWrite
    }

    func set(_ value: String, for reference: String) throws {
        try queue.sync {
            if reference == failOnSetReference { throw ProviderError.transport("injected write failure") }
            writes += 1
            keys[reference] = value
        }
    }

    func remove(_ reference: String) throws {
        queue.sync {
            keys.removeValue(forKey: reference)
        }
    }

    func key(for reference: String) async throws -> String {
        try queue.sync {
            if reference == failOnReadReference { throw ProviderError.transport("injected read failure") }
            guard let value = keys[reference] else { throw ProviderError.missingAPIKey }
            if reference == corruptReadReferenceAfterWrite, writes > 0 { return "injected-corrupt-read" }
            return value
        }
    }

    func snapshot() -> [String: String] { queue.sync { keys } }
    func writeCount() -> Int { queue.sync { writes } }
}

private struct FixedProvider: ProviderStreaming {
    let token: String
    func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token(token))
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}

private struct KeyOutcomeProvider: ProviderStreaming {
    func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            switch apiKey {
            case "bad-auth": continuation.finish(throwing: ProviderError.authenticationFailed(401))
            case "no-quota": continuation.finish(throwing: ProviderError.capacityExhausted(403))
            case "rate-limit": continuation.finish(throwing: ProviderError.rateLimited)
            case "server-error": continuation.finish(throwing: ProviderError.invalidResponse(503))
            default:
                continuation.yield(.token("good"))
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }
}

private actor RecordingKeyOutcomeProvider: ProviderStreaming {
    private var seen: [String] = []

    func keysSeen() -> [String] { seen }

    nonisolated func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(apiKey)
                if apiKey == "bad-auth" {
                    continuation.finish(throwing: ProviderError.authenticationFailed(401))
                } else {
                    continuation.yield(.token("good"))
                    continuation.yield(.finished)
                    continuation.finish()
                }
            }
        }
    }

    private func record(_ apiKey: String) {
        seen.append(apiKey)
    }
}

private struct PartialThenFailureProvider: ProviderStreaming {
    func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token("partial"))
            continuation.finish(throwing: ProviderError.streamInterrupted)
        }
    }
}

private func collectText(_ stream: AsyncThrowingStream<ProviderEvent, Error>) async throws -> String {
    var text = ""
    for try await event in stream {
        if case .token(let token) = event { text += token }
    }
    return text
}

private final class ProviderDiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requestCountValue = 0

    static func reset() {
        lock.lock()
        requestCountValue = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCountValue += 1
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        let hasBearer = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret"
        let hasXAPIKey = request.value(forHTTPHeaderField: "x-api-key") == "test-secret"
        let status: Int
        let body: Data
        if path.hasSuffix("/v1/models") {
            status = 200
            body = Data("{\"data\":[{\"id\":\"model-a\"}]}".utf8)
        } else if path.hasSuffix("/v1/messages"), hasBearer, hasXAPIKey {
            status = 200
            body = Data("{\"content\":[{\"type\":\"text\",\"text\":\"OK\"}]}".utf8)
        } else {
            status = 401
            body = Data("{\"error\":\"authentication failed\"}".utf8)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProviderTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseStatus = 200
    private static var responseBody = Data()
    private static var responseHeaders: [String: String] = [:]
    private static var capturedRequest: URLRequest?

    static func install(status: Int, body: Data, headers: [String: String] = [:]) {
        lock.lock()
        responseStatus = status
        responseBody = body
        responseHeaders = headers
        capturedRequest = nil
        lock.unlock()
    }

    static func reset() {
        install(status: 200, body: Data(), headers: [:])
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequest = request
        let status = Self.responseStatus
        let body = Self.responseBody
        let headers = Self.responseHeaders
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
