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

    func testBootstrapStableFingerprintIgnoresGeneratedAtButTracksKeyMaterial() {
        let original = ProviderBootstrapPayload(
            generatedAt: Date(timeIntervalSince1970: 100),
            providers: [
                .init(providerID: "provider-a", keys: [
                    .init(slotID: "slot-1", label: "Key 1", secret: "secret-a")
                ])
            ]
        )
        let rebuilt = ProviderBootstrapPayload(
            generatedAt: Date(timeIntervalSince1970: 999),
            providers: [
                .init(providerID: "provider-a", keys: [
                    .init(slotID: "slot-1", label: "Renamed Key", secret: "secret-a", fingerprint: "cosmetic-metadata")
                ])
            ]
        )
        let rotated = ProviderBootstrapPayload(
            generatedAt: rebuilt.generatedAt,
            providers: [
                .init(providerID: "provider-a", keys: [
                    .init(slotID: "slot-1", label: "Key 1", secret: "secret-b")
                ])
            ]
        )

        XCTAssertEqual(original.stableContentFingerprint, rebuilt.stableContentFingerprint)
        XCTAssertNotEqual(original.stableContentFingerprint, rotated.stableContentFingerprint)
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

    func testJustwokerUsesDualAuthForRotatedKeyCompatibility() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-api-justwoker-icu" }))
        XCTAssertEqual(provider.authMode, .both)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-5", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-5-thinking", keySlotID: "slot-1"), .anthropic)
    }

    func testAgentRouterUsesCurrentOriginAndExplicitPerModelProtocols() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-agentrouter-org" }))
        XCTAssertEqual(provider.baseURL.absoluteString, "https://co.agentrouter.org")
        XCTAssertEqual(provider.authMode, .bearer)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-4-8", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-5", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.protocolFor(model: "deepseek-v4-flash", keySlotID: "slot-1"), .openAIChat)
        XCTAssertEqual(provider.protocolFor(model: "gpt-5.6-sol", keySlotID: "slot-1"), .openAIChat)
        XCTAssertFalse(provider.protocols.contains(.openAIResponses))
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

    func testSelectedKeyIsAlwaysThePrimaryReferenceBeforeSameProviderRotation() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.tabitokenID }))
        for slot in provider.keySlots {
            let references = provider.orderedKeyReferences(selectedKeySlotID: slot.id)
            XCTAssertEqual(references.first, ProviderCatalog.keyReference(providerID: provider.id, keySlotID: slot.id))
            XCTAssertTrue(references.allSatisfy { $0.hasPrefix("provider.\(provider.id).key.") })
        }
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

    func testCheckpointConfigurationRebindsToCatalogAndRejectsEndpointOrCrossProviderKeyTampering() throws {
        let profiles = ProviderCatalog.desktopSnapshot
        let provider = try XCTUnwrap(profiles.first(where: { $0.id == ProviderCatalog.tabitokenID }))
        let primary = ProviderCatalog.keyReference(providerID: provider.id, keySlotID: "slot-1")
        let fallback = ProviderCatalog.keyReference(providerID: provider.id, keySlotID: "slot-2")
        let payload: [String: String] = [
            "provider.id": provider.id,
            "provider.baseURL": provider.baseURL.absoluteString,
            "provider.model": "claude-opus-5",
            "provider.keyReference": primary,
            "provider.fallbackKeyReferences": fallback,
            "provider.sameProviderFailover": "true"
        ]

        let resolved = try ProviderCheckpointConfigurationResolver.resolve(payload: payload, profiles: profiles)
        XCTAssertEqual(resolved.providerID, provider.id)
        XCTAssertEqual(resolved.baseURL, provider.baseURL)
        XCTAssertEqual(resolved.apiKeyReference, primary)
        XCTAssertEqual(resolved.fallbackAPIKeyReferences, [fallback])
        XCTAssertEqual(resolved.protocolName, ProviderProtocol.anthropic.rawValue)
        XCTAssertEqual(resolved.authModeName, ProviderAuthMode.both.rawValue)

        var endpointTampered = payload
        endpointTampered["provider.baseURL"] = "https://attacker.example"
        XCTAssertThrowsError(try ProviderCheckpointConfigurationResolver.resolve(payload: endpointTampered, profiles: profiles)) { error in
            XCTAssertEqual(error as? ProviderCheckpointConfigurationError, .endpointMismatch)
        }

        let agentRouter = try XCTUnwrap(profiles.first(where: { $0.id == "https-agentrouter-org" }))
        let agentRouterReference = ProviderCatalog.keyReference(providerID: agentRouter.id, keySlotID: "slot-1")
        let migratedAgentRouter = try ProviderCheckpointConfigurationResolver.resolve(payload: [
            "provider.id": agentRouter.id,
            "provider.baseURL": "https://agentrouter.org",
            "provider.model": "deepseek-v4-flash",
            "provider.keyReference": agentRouterReference,
            "provider.sameProviderFailover": "false"
        ], profiles: profiles)
        XCTAssertEqual(migratedAgentRouter.baseURL.absoluteString, "https://co.agentrouter.org")
        XCTAssertEqual(migratedAgentRouter.protocolName, ProviderProtocol.openAIChat.rawValue)

        let otherProvider = try XCTUnwrap(profiles.first(where: { $0.id != provider.id }))
        var crossProvider = payload
        crossProvider["provider.fallbackKeyReferences"] = ProviderCatalog.keyReference(providerID: otherProvider.id, keySlotID: otherProvider.keySlots[0].id)
        XCTAssertThrowsError(try ProviderCheckpointConfigurationResolver.resolve(payload: crossProvider, profiles: profiles)) { error in
            guard let typed = error as? ProviderCheckpointConfigurationError,
                  case .crossProviderFallback = typed else {
                return XCTFail("Expected cross-provider fallback rejection, got \(error)")
            }
        }
    }

    func testBootstrapDecoderAcceptsFractionalISO8601GeneratedAt() throws {
        let data = Data(#"{"schemaVersion":1,"generatedAt":"2026-09-03T03:39:18.123456Z","providers":[{"providerID":"tabitoken","keys":[{"slotID":"slot-1","label":"Key 1","secret":"test-secret","fingerprint":null}]}]}"#.utf8)
        let payload = try ProviderBootstrapPayload.decodeBootstrap(from: data)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.providers.first?.providerID, "tabitoken")
        XCTAssertGreaterThan(payload.generatedAt.timeIntervalSince1970, 0)
    }

    func testBootstrapDecoderDoesNotLetNonSecurityTimestampBlockKeyImport() throws {
        let data = Data(#"{"schemaVersion":1,"generatedAt":"legacy-timestamp","providers":[{"providerID":"tabitoken","keys":[{"slotID":"slot-1","label":"Key 1","secret":"test-secret","fingerprint":null}]}]}"#.utf8)
        let payload = try ProviderBootstrapPayload.decodeBootstrap(from: data)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.generatedAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(payload.providers.first?.keys.first?.secret, "test-secret")
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

    func test5xxWithoutOutputRotatesToFallbackAfterPerKeyRetriesAreExhausted() async throws {
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
        let text = try await collectText(router.stream(configuration: configuration, apiKey: "server-error", messages: [], tools: []))
        XCTAssertEqual(text, "good")
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
            apiKey: "test-secret",
            preferredAuthMode: .both
        )
        XCTAssertEqual(result.models, ["model-a"])
        XCTAssertEqual(result.authMode, .both)
        XCTAssertEqual(result.protocols, [.anthropic])
        XCTAssertEqual(result.readiness, .ready)
    }

    func testProviderProfileAppliesLiveDiscoveryAndDropsStaleModelMetadata() throws {
        var profile = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.tabitokenID }))
        let discovery = ProviderDiscoveryResult(
            models: ["live-model-a", "live-model-b", "live-model-a"],
            protocols: [.anthropic],
            authMode: .both,
            readiness: .ready
        )

        profile.applyDiscovery(discovery, keySlotID: "slot-1")

        XCTAssertEqual(profile.models, ["live-model-a", "live-model-b"])
        XCTAssertEqual(profile.models(for: "slot-1"), ["live-model-a", "live-model-b"])
        XCTAssertEqual(profile.models(for: "slot-2"), ["live-model-a", "live-model-b"])
        XCTAssertEqual(profile.protocols, [.anthropic])
        XCTAssertEqual(profile.authMode, .both)
        XCTAssertEqual(profile.readiness, .ready)
        XCTAssertTrue(profile.keySlots.first(where: { $0.id == "slot-1" })?.modelProtocols.isEmpty == true)

        let reconciled = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: profile.id, keySlotID: "slot-3", model: "claude-opus-5"),
            profiles: [profile]
        )
        XCTAssertEqual(reconciled.providerID, profile.id)
        XCTAssertEqual(reconciled.keySlotID, "slot-3")
        XCTAssertEqual(reconciled.model, "live-model-a")
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

        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"files_read","input":{}}}

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
        for try await event in client.stream(configuration: configuration, apiKey: "test-secret", messages: [ChatMessage(role: .user, content: "hi")], tools: [ProviderToolSchema(name: "files_read", description: "read", properties: ["path": "string"])]) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("hello")))
        XCTAssertTrue(events.contains(.toolCall(id: "tool-1", name: "files_read", argumentsJSON: "{\"path\":\"/tmp/a\"}")))
        XCTAssertEqual(events.last, .finished)
        let request = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://tabitoken.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream, application/json")
    }

    func testAnthropicAcceptsNonSSEFullJSONResponseFromCompatibleProxy() async throws {
        let body = Data("""
        {"id":"msg-proxy","type":"message","role":"assistant","content":[{"type":"text","text":"proxy-ok"}],"stop_reason":"end_turn"}
        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "application/json"])
        let client = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(
            name: "proxy",
            baseURL: URL(string: "https://proxy.example")!,
            model: "claude-test",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue
        )
        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("proxy-ok")))
        XCTAssertEqual(events.last, .finished)
    }

    func testAnthropicAcceptsMessageDeltaTerminalWithoutMessageStop() async throws {
        let body = Data("""
        data: {"type":"message_start","message":{"id":"m1"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
        let client = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(name: "proxy", baseURL: URL(string: "https://proxy.example")!, model: "m", apiKeyReference: "key", protocolName: ProviderProtocol.anthropic.rawValue)
        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("ok")))
        XCTAssertEqual(events.last, .finished)
    }

    func testOpenAIChatAcceptsNonSSEFullJSONResponseFromCompatibleProxy() async throws {
        let body = Data("""
        {"id":"chatcmpl-proxy","choices":[{"index":0,"message":{"role":"assistant","content":"chat-ok"},"finish_reason":"stop"}]}
        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "application/json"])
        let client = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(name: "proxy", baseURL: URL(string: "https://proxy.example")!, model: "m", apiKeyReference: "key", protocolName: ProviderProtocol.openAIChat.rawValue)
        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("chat-ok")))
        XCTAssertEqual(events.last, .finished)
    }

    func testResponsesAcceptsNonSSEFullJSONResponseFromCompatibleProxy() async throws {
        let body = Data("""
        {"id":"resp-proxy","object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"responses-ok"}]}]}
        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "application/json"])
        let client = OpenAIResponsesProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(name: "proxy", baseURL: URL(string: "https://proxy.example")!, model: "m", apiKeyReference: "key", protocolName: ProviderProtocol.openAIResponses.rawValue)
        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("responses-ok")))
        XCTAssertEqual(events.last, .finished)
    }

    func testAgentRouterDeepSeekUsesOpenAIChatCurrentOriginAndBearerAuth() async throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-agentrouter-org" }))
        let protocolName = provider.protocolFor(model: "deepseek-v4-flash", keySlotID: "slot-1")
        XCTAssertEqual(protocolName, .openAIChat)
        ProviderTestURLProtocol.install(
            status: 200,
            body: Data("data: [DONE]\n\n".utf8),
            headers: ["Content-Type": "text/event-stream"]
        )
        let client = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(
            name: provider.displayName,
            baseURL: provider.baseURL,
            model: "deepseek-v4-flash",
            apiKeyReference: ProviderCatalog.keyReference(providerID: provider.id, keySlotID: "slot-1"),
            providerID: provider.id,
            protocolName: protocolName.rawValue,
            authModeName: provider.authMode.rawValue
        )
        for try await _ in client.stream(configuration: configuration, apiKey: "test-secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
        let request = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://co.agentrouter.org/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
    }

    func testProviderEndpointReplacesFullProtocolEndpointWithoutDuplicatingV1() async throws {
        ProviderTestURLProtocol.install(status: 200, body: Data("data: [DONE]\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let chat = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let chatConfiguration = ProviderConfiguration(
            name: "chat",
            baseURL: URL(string: "https://example.com/v1/messages")!,
            model: "m",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIChat.rawValue
        )
        for try await _ in chat.stream(configuration: chatConfiguration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
        XCTAssertEqual(ProviderTestURLProtocol.lastRequest()?.url?.absoluteString, "https://example.com/v1/chat/completions")

        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"message_stop\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let anthropic = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let anthropicConfiguration = ProviderConfiguration(
            name: "anthropic",
            baseURL: URL(string: "https://example.com/v1/chat/completions")!,
            model: "m",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.anthropic.rawValue
        )
        for try await _ in anthropic.stream(configuration: anthropicConfiguration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
        XCTAssertEqual(ProviderTestURLProtocol.lastRequest()?.url?.absoluteString, "https://example.com/v1/messages")
    }

    func testResponsesStreamingTextAndToolCall() async throws {
        let body = Data("""
        data: {"type":"response.output_text.delta","delta":"ok"}

        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"item-1","call_id":"call-1","name":"files_read","arguments":""}}

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
        XCTAssertTrue(events.contains(.toolCall(id: "call-1", name: "files_read", argumentsJSON: "{\"path\":\"/x\"}")))
        XCTAssertEqual(ProviderTestURLProtocol.lastRequest()?.url?.absoluteString, "https://example.com/v1/responses")
    }

    func testImageAttachmentIsEncodedForChatAnthropicAndResponses() async throws {
        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("CloudCode/Attachments/provider-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let imageURL = support.appendingPathComponent("cloudcode-provider-image-\(UUID().uuidString).jpg")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try bytes.write(to: imageURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let message = ChatMessage(
            role: .user,
            content: "看图",
            attachments: [ChatAttachment(filename: "photo.jpg", path: imageURL.path, mimeType: "image/jpeg", byteSize: Int64(bytes.count))]
        )
        let expectedDataURL = "data:image/jpeg;base64,\(bytes.base64EncodedString())"

        ProviderTestURLProtocol.install(status: 200, body: Data("data: [DONE]\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let chat = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let chatConfig = ProviderConfiguration(name: "chat", baseURL: URL(string: "https://example.com/v1")!, model: "vision", apiKeyReference: "key", protocolName: ProviderProtocol.openAIChat.rawValue)
        for try await _ in chat.stream(configuration: chatConfig, apiKey: "secret", messages: [message], tools: []) {}
        let chatBodyData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let chatBody = try XCTUnwrap(JSONSerialization.jsonObject(with: chatBodyData) as? [String: Any])
        let chatMessages = try XCTUnwrap(chatBody["messages"] as? [[String: Any]])
        let chatContent = try XCTUnwrap(chatMessages.first?["content"] as? [[String: Any]])
        let chatImage = try XCTUnwrap(chatContent.last?["image_url"] as? [String: Any])
        XCTAssertEqual(chatImage["url"] as? String, expectedDataURL)

        ProviderTestURLProtocol.install(status: 200, body: Data("""
        data: {"type":"message_start","message":{"id":"m1"}}

        data: {"type":"message_stop"}

        """.utf8), headers: ["Content-Type": "text/event-stream"])
        let anthropic = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let anthropicConfig = ProviderConfiguration(name: "anthropic", baseURL: URL(string: "https://example.com/v1")!, model: "vision", apiKeyReference: "key", protocolName: ProviderProtocol.anthropic.rawValue)
        for try await _ in anthropic.stream(configuration: anthropicConfig, apiKey: "secret", messages: [message], tools: []) {}
        let anthropicBodyData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let anthropicBody = try XCTUnwrap(JSONSerialization.jsonObject(with: anthropicBodyData) as? [String: Any])
        let anthropicMessages = try XCTUnwrap(anthropicBody["messages"] as? [[String: Any]])
        let anthropicContent = try XCTUnwrap(anthropicMessages.first?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(anthropicContent.last?["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, bytes.base64EncodedString())

        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"response.completed\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let responses = OpenAIResponsesProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let responsesConfig = ProviderConfiguration(name: "responses", baseURL: URL(string: "https://example.com/v1")!, model: "vision", apiKeyReference: "key", protocolName: ProviderProtocol.openAIResponses.rawValue)
        for try await _ in responses.stream(configuration: responsesConfig, apiKey: "secret", messages: [message], tools: []) {}
        let responsesBodyData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let responsesBody = try XCTUnwrap(JSONSerialization.jsonObject(with: responsesBodyData) as? [String: Any])
        let input = try XCTUnwrap(responsesBody["input"] as? [[String: Any]])
        let responseContent = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(responseContent.last?["image_url"] as? String, expectedDataURL)
    }

    func testPersistedInternalToolNamesAreProviderSafeAcrossAnthropicChatAndResponsesHistory() async throws {
        let assistantCall = ChatMessage(role: .assistant, content: "", providerMetadata: [
            "tool_call_id": "call-1",
            "tool_name": "files.read",
            "tool_arguments": "{\"path\":\"/tmp/a\"}"
        ])
        let toolResult = ChatMessage(role: .tool, content: "ok", providerMetadata: [
            "tool_call_id": "call-1",
            "tool_name": "files.read"
        ])
        let messages = [ChatMessage(role: .user, content: "read"), assistantCall, toolResult]
        let safeSchema = ProviderToolSchema(name: "files_read", description: "read", properties: ["path": "string"], required: ["path"])

        ProviderTestURLProtocol.install(status: 200, body: Data("""
        data: {"type":"message_start","message":{"id":"m1"}}

        data: {"type":"message_stop"}

        """.utf8), headers: ["Content-Type": "text/event-stream"])
        let anthropic = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let anthropicConfig = ProviderConfiguration(name: "a", baseURL: URL(string: "https://example.com/v1")!, model: "m", apiKeyReference: "k", protocolName: ProviderProtocol.anthropic.rawValue)
        for try await _ in anthropic.stream(configuration: anthropicConfig, apiKey: "secret", messages: messages, tools: [safeSchema]) {}
        _ = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        let anthropicData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let anthropicBody = try XCTUnwrap(JSONSerialization.jsonObject(with: anthropicData) as? [String: Any])
        let anthropicMessages = try XCTUnwrap(anthropicBody["messages"] as? [[String: Any]])
        let assistantBlocks = try XCTUnwrap(anthropicMessages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.first?["name"] as? String, "files_read")

        ProviderTestURLProtocol.install(status: 200, body: Data("data: [DONE]\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let chat = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let chatConfig = ProviderConfiguration(name: "c", baseURL: URL(string: "https://example.com/v1")!, model: "m", apiKeyReference: "k", protocolName: ProviderProtocol.openAIChat.rawValue)
        for try await _ in chat.stream(configuration: chatConfig, apiKey: "secret", messages: messages, tools: [safeSchema]) {}
        _ = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        let chatData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let chatBody = try XCTUnwrap(JSONSerialization.jsonObject(with: chatData) as? [String: Any])
        let chatMessages = try XCTUnwrap(chatBody["messages"] as? [[String: Any]])
        let chatToolCalls = try XCTUnwrap(chatMessages[1]["tool_calls"] as? [[String: Any]])
        let chatFunction = try XCTUnwrap(chatToolCalls.first?["function"] as? [String: Any])
        XCTAssertEqual(chatFunction["name"] as? String, "files_read")
        XCTAssertEqual(chatMessages[2]["name"] as? String, "files_read")

        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"response.completed\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let responses = OpenAIResponsesProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let responsesConfig = ProviderConfiguration(name: "r", baseURL: URL(string: "https://example.com/v1")!, model: "m", apiKeyReference: "k", protocolName: ProviderProtocol.openAIResponses.rawValue)
        for try await _ in responses.stream(configuration: responsesConfig, apiKey: "secret", messages: messages, tools: [safeSchema]) {}
        _ = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        let responsesData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let responsesBody = try XCTUnwrap(JSONSerialization.jsonObject(with: responsesData) as? [String: Any])
        let input = try XCTUnwrap(responsesBody["input"] as? [[String: Any]])
        XCTAssertEqual(input[1]["name"] as? String, "files_read")
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

    func testTransient5xxAndCannotParseCanRotateOnlyBeforeOutput() {
        XCTAssertTrue(ProviderKeyRotationClassifier.shouldRotate(ProviderError.invalidResponse(502)))
        XCTAssertTrue(ProviderKeyRotationClassifier.shouldRotate(ProviderError.invalidResponse(503)))
        XCTAssertTrue(ProviderKeyRotationClassifier.shouldRotate(URLError(.cannotParseResponse)))
        XCTAssertFalse(ProviderKeyRotationClassifier.shouldRotate(ProviderError.invalidResponse(400)))
        XCTAssertFalse(ProviderKeyRotationClassifier.shouldRotate(ProviderError.rateLimited))
        XCTAssertFalse(ProviderKeyRotationClassifier.shouldRotate(ProviderError.streamInterrupted))
    }

    func testTransientDisconnectsRetryOnlyBeforeOutput() {
        XCTAssertTrue(ProviderRetryClassifier.isRetryableBeforeOutput(URLError(.timedOut)))
        XCTAssertTrue(ProviderRetryClassifier.isRetryableBeforeOutput(URLError(.networkConnectionLost)))
        XCTAssertTrue(ProviderRetryClassifier.isRetryableBeforeOutput(URLError(.cannotConnectToHost)))
        XCTAssertTrue(ProviderRetryClassifier.isRetryableBeforeOutput(URLError(.cannotParseResponse)))
        XCTAssertTrue(ProviderRetryClassifier.isReplaySafeAfterHTTPResponseBeforeOutput(URLError(.cannotParseResponse)))
        XCTAssertFalse(ProviderRetryClassifier.isReplaySafeAfterHTTPResponseBeforeOutput(URLError(.networkConnectionLost)))
        XCTAssertFalse(ProviderRetryClassifier.isRetryableBeforeOutput(ProviderError.streamInterrupted))
        XCTAssertFalse(ProviderRetryClassifier.isRetryableBeforeOutput(ProviderError.authenticationFailed(401)))
        XCTAssertFalse(ProviderRetryClassifier.isRetryableBeforeOutput(URLError(.secureConnectionFailed)))
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

final class ProviderLiveIntegrationTests: XCTestCase {
    func testJustwokerAgentUsesFullCloudCodeToolSchemaExecutesToolAndContinuesAfterResult() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODE_JUSTWOKER_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Justwoker live smoke is enabled only in the dedicated GitHub Actions workflow")
        }
        guard let bootstrapText = ProcessInfo.processInfo.environment["CLOUDCODE_PROVIDER_BOOTSTRAP"],
              let bootstrapData = bootstrapText.data(using: .utf8) else {
            XCTFail("CLOUDCODE_PROVIDER_BOOTSTRAP is missing")
            return
        }
        let payload = try ProviderBootstrapPayload.decodeBootstrap(from: bootstrapData)
        let provider = try XCTUnwrap(payload.providers.first(where: { $0.providerID == "https-api-justwoker-icu" }))
        let key = try XCTUnwrap(provider.keys.first?.secret)
        XCTAssertFalse(key.isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeJustwokerLiveSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryKeyVault(keys: ["live-justwoker": key])
        let registry = ToolRegistry()
        let probe = LiveSmokeCapabilityProbe()
        let router = ToolRouter(
            registry: registry,
            executors: [LiveSmokeCapabilityExecutor()],
            executionLedger: ToolExecutionLedger(fileURL: root.appendingPathComponent("execution-ledger.json"))
        )
        let sessions = SessionStore(root: root.appendingPathComponent("sessions", isDirectory: true))
        let agent = AgentCore(
            provider: AnthropicProviderClient(retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)),
            keyVault: vault,
            toolRouter: router,
            registry: registry,
            capabilityProbe: probe,
            sessionStore: sessions,
            checkpointStore: TaskCheckpointStore(fileURL: root.appendingPathComponent("checkpoints.json")),
            maxToolRounds: 4
        )
        let session = AgentSession(permissionMode: .full)
        let configuration = ProviderConfiguration(
            name: "api.justwoker.icu",
            baseURL: URL(string: "https://api.justwoker.icu")!,
            model: "claude-opus-5",
            apiKeyReference: "live-justwoker",
            providerID: "https-api-justwoker-icu",
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.both.rawValue
        )

        var capabilityToolCallCount = 0
        var sawSuccessfulToolResult = false
        var assistantText = ""
        let stream = await agent.send(
            text: "You must call the capability_probe tool exactly once before answering. Do not call any other tool. After receiving its tool result, reply exactly JUSTWOKER_TOOL_ROUND_OK.",
            session: session,
            providerConfiguration: configuration
        )
        for try await event in stream {
            switch event {
            case .toolStarted(let name, _):
                if name == "capability.probe" { capabilityToolCallCount += 1 }
            case .toolFinished(let result):
                if result.success { sawSuccessfulToolResult = true }
            case .token(let token):
                assistantText += token
            default:
                break
            }
        }

        XCTAssertEqual(capabilityToolCallCount, 1, "Justwoker live model must execute capability_probe exactly once")
        XCTAssertTrue(sawSuccessfulToolResult, "Justwoker live tool result was not produced")
        XCTAssertTrue(assistantText.contains("JUSTWOKER_TOOL_ROUND_OK"), "Justwoker live model did not continue after the tool result")
        let saved = try await sessions.load(session.id)
        XCTAssertTrue(saved.messages.contains { $0.role == .assistant && $0.content.contains("JUSTWOKER_TOOL_ROUND_OK") })
        let toolCall = saved.messages.first(where: { $0.role == .assistant && $0.providerMetadata["tool_call_id"] != nil })
        XCTAssertEqual(toolCall?.providerMetadata["tool_name"], "capability.probe")
        XCTAssertEqual(toolCall?.providerMetadata["provider_tool_name"], "capability_probe")
    }

    func testTabitokenAgentUsesFullCloudCodeToolSchemaExecutesToolAndContinuesAfterResult() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Live Provider smoke is enabled only in the dedicated GitHub Actions workflow")
        }
        guard let bootstrapText = ProcessInfo.processInfo.environment["CLOUDCODE_PROVIDER_BOOTSTRAP"],
              let bootstrapData = bootstrapText.data(using: .utf8) else {
            XCTFail("CLOUDCODE_PROVIDER_BOOTSTRAP is missing")
            return
        }
        let payload = try ProviderBootstrapPayload.decodeBootstrap(from: bootstrapData)
        let tabitoken = try XCTUnwrap(payload.providers.first(where: { $0.providerID == ProviderCatalog.tabitokenID }))
        let key = try XCTUnwrap(tabitoken.keys.first?.secret)
        let liveModel = ProcessInfo.processInfo.environment["CLOUDCODE_TABITOKEN_LIVE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(key.isEmpty)
        XCTAssertFalse(liveModel.isEmpty, "CLOUDCODE_TABITOKEN_LIVE_MODEL must come from the workflow's validated /v1/models probe")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeLiveSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryKeyVault(keys: ["live-tabitoken": key])
        let registry = ToolRegistry()
        let probe = LiveSmokeCapabilityProbe()
        let router = ToolRouter(
            registry: registry,
            executors: [LiveSmokeCapabilityExecutor()],
            executionLedger: ToolExecutionLedger(fileURL: root.appendingPathComponent("execution-ledger.json"))
        )
        let sessions = SessionStore(root: root.appendingPathComponent("sessions", isDirectory: true))
        let agent = AgentCore(
            provider: AnthropicProviderClient(retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)),
            keyVault: vault,
            toolRouter: router,
            registry: registry,
            capabilityProbe: probe,
            sessionStore: sessions,
            checkpointStore: TaskCheckpointStore(fileURL: root.appendingPathComponent("checkpoints.json")),
            maxToolRounds: 4
        )
        let session = AgentSession(permissionMode: .full)
        let configuration = ProviderConfiguration(
            name: "Tabitoken",
            baseURL: URL(string: "https://tabitoken.com")!,
            model: liveModel,
            apiKeyReference: "live-tabitoken",
            providerID: ProviderCatalog.tabitokenID,
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.both.rawValue
        )

        var capabilityToolCallCount = 0
        var sawSuccessfulToolResult = false
        var assistantText = ""
        let stream = await agent.send(
            text: "You must call the capability_probe tool exactly once before answering. Do not call any other tool. After receiving its tool result, reply exactly LIVE_TOOL_ROUND_OK.",
            session: session,
            providerConfiguration: configuration
        )
        for try await event in stream {
            switch event {
            case .toolStarted(let name, _):
                if name == "capability.probe" { capabilityToolCallCount += 1 }
            case .toolFinished(let result):
                if result.success { sawSuccessfulToolResult = true }
            case .token(let token):
                assistantText += token
            default:
                break
            }
        }

        XCTAssertEqual(capabilityToolCallCount, 1, "Live Tabitoken model must execute capability_probe exactly once")
        XCTAssertTrue(sawSuccessfulToolResult, "Live tool result was not produced")
        XCTAssertTrue(assistantText.contains("LIVE_TOOL_ROUND_OK"), "Live model did not continue after tool result")
        let saved = try await sessions.load(session.id)
        XCTAssertTrue(saved.messages.contains { $0.role == .assistant && $0.content.contains("LIVE_TOOL_ROUND_OK") })
        let toolCall = saved.messages.first(where: { $0.role == .assistant && $0.providerMetadata["tool_call_id"] != nil })
        XCTAssertEqual(toolCall?.providerMetadata["tool_name"], "capability.probe")
        XCTAssertEqual(toolCall?.providerMetadata["provider_tool_name"], "capability_probe")
    }
}

private struct LiveSmokeCapabilityProbe: CapabilityProbing, Sendable {
    func probe() async -> CapabilityProfile {
        CapabilityProfile(records: [CapabilityRecord(id: "filesystem.own_container", domain: .filesystem, status: .available, detail: "live smoke")])
    }
}

private struct LiveSmokeCapabilityExecutor: ToolExecuting, Sendable {
    let route: AppExecutionRoute = .structuredTool

    func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name == "capability.probe"
    }

    func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard call.name == "capability.probe" else { throw ToolRouterError.noExecutionRoute(call.name) }
        return ToolResult(toolCallID: call.id, success: true, summary: "Capability probe live smoke executed", payload: ["available": "1"])
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
            body = Data("{\"data\":[{\"provider_record\":{\"model_id\":\"model-a\"}}]}".utf8)
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
    private static var capturedBody: Data?

    static func install(status: Int, body: Data, headers: [String: String] = [:]) {
        lock.lock()
        responseStatus = status
        responseBody = body
        responseHeaders = headers
        capturedRequest = nil
        capturedBody = nil
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

    static func lastRequestBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while true {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            requestBody = data
        }

        Self.lock.lock()
        Self.capturedRequest = request
        Self.capturedBody = requestBody
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
