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

    func testJustwokerMatchesCurrentDesktopBearerAuthAndExactModelProtocolEvidence() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-api-justwoker-icu" }))
        XCTAssertEqual(provider.authMode, .bearer)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-5", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-5-thinking", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.protocolCandidates(for: "claude-opus-5", keySlotID: "slot-1"), [.anthropic])
    }

    func testGorouterWithoutExactModelProtocolEvidenceKeepsBoundedProtocolCandidates() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "ccs-7bdd07431575" }))
        XCTAssertEqual(provider.protocolCandidates(for: "claude-opus-5", keySlotID: "slot-1"), [.anthropic, .openAIChat])
        XCTAssertEqual(provider.protocolCandidates(for: "claude-opus-5", keySlotID: "slot-2"), [.anthropic, .openAIChat])
    }

    func testMultiKeyDesktopProvidersEnableSameProviderFailover() throws {
        for id in ["ccs-7bdd07431575", "https-sharellm-cn", "https-sirthisway-icu"] {
            let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == id }))
            XCTAssertGreaterThan(provider.keySlots.count, 1, id)
            XCTAssertTrue(provider.autoRotateKeys, id)
        }
    }

    func testAgentRouterUsesDocumentedProviderOriginButLegacyKeyEvidenceKeepsBoundedProtocols() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-agentrouter-org" }))
        XCTAssertEqual(provider.baseURL.absoluteString, "https://co.agentrouter.org")
        XCTAssertEqual(provider.authMode, .bearer)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-4-8", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.protocolFor(model: "claude-opus-5", keySlotID: "slot-1"), .anthropic)
        XCTAssertEqual(provider.protocolCandidates(for: "deepseek-v4-flash", keySlotID: "slot-1"), [.openAIChat, .anthropic])
        XCTAssertEqual(provider.protocolCandidates(for: "gpt-5.6-sol", keySlotID: "slot-1"), [.openAIChat, .anthropic])
        XCTAssertEqual(provider.protocolCandidates(for: "glm-5.3", keySlotID: "slot-1"), [.openAIChat, .anthropic])
        XCTAssertTrue(provider.selectableModels(for: "slot-1").contains("glm-5.3"))
        XCTAssertEqual(provider.protocolFor(model: "gpt-5.5", keySlotID: "slot-1"), .openAIChat)
        XCTAssertEqual(provider.protocolCandidates(for: "gpt-5.5", keySlotID: "slot-1"), [.openAIChat, .anthropic])
        XCTAssertFalse(provider.protocols.contains(.openAIResponses))
    }

    func testAgentRouterUnknownDiscoveredModelUsesModelFamilyOrderingButKeepsFallback() throws {
        var provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.agentRouterID }))
        provider.keySlots[0].models.append(contentsOf: ["claude-future-model", "future-general-model"])
        XCTAssertEqual(provider.protocolCandidates(for: "claude-future-model", keySlotID: "slot-1"), [.anthropic, .openAIChat])
        XCTAssertEqual(provider.protocolCandidates(for: "future-general-model", keySlotID: "slot-1"), [.openAIChat, .anthropic])
    }

    func testAgentRouterKeyReplacementClearsOldModelProtocolEvidence() throws {
        var provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.agentRouterID }))
        XCTAssertEqual(provider.protocolCandidates(for: "gpt-5.6-sol", keySlotID: "slot-1"), [.openAIChat, .anthropic])
        provider.updateKeyFingerprint(String(repeating: "a", count: 64), keySlotID: "slot-1", status: .needsValidation)
        XCTAssertTrue(provider.keySlots[0].modelProtocols.isEmpty)
        XCTAssertEqual(provider.protocolCandidates(for: "gpt-5.6-sol", keySlotID: "slot-1"), [.openAIChat, .anthropic])
    }

    func testAgentRouterEndpointCandidatesUseHistoricalFingerprintOnlyAsHostOrderHint() throws {
        let configured = try XCTUnwrap(URL(string: "https://co.agentrouter.org"))
        let legacy = ProviderEndpointRoutingPolicy.candidateBaseURLs(
            providerID: ProviderCatalog.agentRouterID,
            configuredBaseURL: configured,
            keyFingerprint: ProviderEndpointRoutingPolicy.agentRouterLegacyKeyFingerprint
        )
        XCTAssertEqual(legacy.map(\.host), ["agentrouter.org", "co.agentrouter.org"])
        let current = ProviderEndpointRoutingPolicy.candidateBaseURLs(
            providerID: ProviderCatalog.agentRouterID,
            configuredBaseURL: configured,
            keyFingerprint: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(current.map(\.host), ["co.agentrouter.org", "agentrouter.org"])

        let unapproved = ProviderEndpointRoutingPolicy.candidateBaseURLs(
            providerID: ProviderCatalog.agentRouterID,
            configuredBaseURL: URL(string: "https://unapproved.example.com/v1")!,
            keyFingerprint: String(repeating: "c", count: 64)
        )
        XCTAssertEqual(unapproved.map(\.host), ["co.agentrouter.org", "agentrouter.org"])
        XCTAssertFalse(unapproved.contains { $0.host == "unapproved.example.com" })
    }

    func testVyceLunaPrefersDeviceVerifiedChatCompletionsWithBoundedFallbacks() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-vyceai-com" }))
        XCTAssertEqual(
            provider.protocolCandidates(for: "gpt-5.6-luna", keySlotID: "slot-1"),
            [.openAIChat, .openAIResponses, .anthropic]
        )
    }

    func testProviderRequestKeyStatePersistsLearnedProtocolAcrossEquivalentConfigurations() async {
        let state = ProviderRequestKeyState(ttl: 3600)
        let routingKey = "https-vyceai-com|gpt-5.6-luna"
        await state.markSuccessful(
            routingKey: routingKey,
            reference: "provider.https-vyceai-com.key.slot-1",
            protocolName: ProviderProtocol.openAIChat.rawValue
        )
        let preferred = await state.preferredProtocol(
            routingKey: routingKey,
            reference: "provider.https-vyceai-com.key.slot-1",
            allowedProtocols: [ProviderProtocol.openAIResponses.rawValue, ProviderProtocol.anthropic.rawValue, ProviderProtocol.openAIChat.rawValue],
            fallback: ProviderProtocol.openAIResponses.rawValue
        )
        XCTAssertEqual(preferred, ProviderProtocol.openAIChat.rawValue)
    }

    func testProviderRequestKeyStateDegradesAndReverifiesExactRouteEvidence() async {
        let state = ProviderRequestKeyState(ttl: 3600)
        let routingKey = "provider|model|key|host|auth"
        let reference = "provider.key.slot-1"
        await state.markSuccessful(
            routingKey: routingKey,
            reference: reference,
            protocolName: ProviderProtocol.openAIChat.rawValue
        )
        await state.markDegraded(routingKey: routingKey, reference: reference)
        let degraded = await state.preferredProtocol(
            routingKey: routingKey,
            reference: reference,
            allowedProtocols: [ProviderProtocol.openAIChat.rawValue, ProviderProtocol.anthropic.rawValue],
            fallback: ProviderProtocol.anthropic.rawValue
        )
        XCTAssertEqual(degraded, ProviderProtocol.anthropic.rawValue)

        await state.markSuccessful(
            routingKey: routingKey,
            reference: reference,
            protocolName: ProviderProtocol.openAIChat.rawValue
        )
        let reverified = await state.preferredProtocol(
            routingKey: routingKey,
            reference: reference,
            allowedProtocols: [ProviderProtocol.openAIChat.rawValue, ProviderProtocol.anthropic.rawValue],
            fallback: ProviderProtocol.anthropic.rawValue
        )
        XCTAssertEqual(reverified, ProviderProtocol.openAIChat.rawValue)
    }

    func testProviderRequestKeyStateDoesNotDegradeVerifiedProtocolBecauseDifferentFallbackFailed() async {
        let state = ProviderRequestKeyState(ttl: 3600)
        let routingKey = "agentrouter|glm-5.3|legacy-host"
        let reference = "provider.https-agentrouter-org.key.slot-1"
        await state.markSuccessful(routingKey: routingKey, reference: reference, protocolName: ProviderProtocol.openAIChat.rawValue)
        await state.markProtocolDegraded(routingKey: routingKey, reference: reference, protocolName: ProviderProtocol.anthropic.rawValue)
        let preferred = await state.preferredProtocol(
            routingKey: routingKey,
            reference: reference,
            allowedProtocols: [ProviderProtocol.openAIChat.rawValue, ProviderProtocol.anthropic.rawValue],
            fallback: ProviderProtocol.anthropic.rawValue
        )
        XCTAssertEqual(preferred, ProviderProtocol.openAIChat.rawValue)
    }

    func testProviderRequestKeyStateDoesNotDegradeVerifiedHostBecauseAlternateHostFailed() async {
        let state = ProviderRequestKeyState(ttl: 3600)
        let routingKey = "agentrouter|legacy-key|host"
        let reference = "provider.https-agentrouter-org.key.slot-1"
        let verified = URL(string: "https://agentrouter.org")!
        let alternate = URL(string: "https://co.agentrouter.org")!
        await state.markSuccessfulBaseURL(routingKey: routingKey, reference: reference, baseURL: verified)
        await state.markBaseURLDegraded(routingKey: routingKey, reference: reference, baseURL: alternate)
        let preferred = await state.preferredBaseURL(
            routingKey: routingKey,
            reference: reference,
            allowedBaseURLs: [verified, alternate],
            fallback: alternate
        )
        XCTAssertEqual(ProviderEndpointRoutingPolicy.normalizedOrigin(preferred), ProviderEndpointRoutingPolicy.normalizedOrigin(verified))
    }

    func testProviderRequestKeyStateDoesNotReuseHostEvidenceAfterConfiguredHostChanges() async {
        let state = ProviderRequestKeyState(ttl: 3600)
        let reference = "provider.key.slot-1"
        let routingKey = "provider|key|host"
        let oldURL = URL(string: "https://old.example.com/v1")!
        let newURL = URL(string: "https://new.example.com/v1")!
        await state.markSuccessfulBaseURL(routingKey: routingKey, reference: reference, baseURL: oldURL)
        let preferred = await state.preferredBaseURL(
            routingKey: routingKey,
            reference: reference,
            allowedBaseURLs: [newURL],
            fallback: newURL
        )
        XCTAssertEqual(preferred, newURL)
    }

    func testAgentRouterLiveCatalogReplacesStaticPickerForSelectedKey() throws {
        var provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.agentRouterID }))
        XCTAssertGreaterThan(provider.selectableModels(for: "slot-1").count, 5)
        let liveModels = ["claude-opus-4-8", "claude-opus-5", "deepseek-v4-flash", "glm-5.3", "gpt-5.6-sol"]
        let discovery = ProviderDiscoveryResult(
            models: liveModels,
            protocols: [.anthropic, .openAIChat],
            authMode: .bearer,
            readiness: .ready
        )

        provider.applyDiscovery(discovery, keySlotID: "slot-1")

        XCTAssertEqual(provider.selectableModels(for: "slot-1"), liveModels)
        XCTAssertEqual(provider.models, liveModels)
        XCTAssertFalse(provider.selectableModels(for: "slot-1").contains("gpt-5.5"))
        XCTAssertEqual(provider.protocolCandidates(for: "deepseek-v4-flash", keySlotID: "slot-1"), [.openAIChat, .anthropic])
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

    func testModelScopedKeyRotationSkipsKeysThatDoNotAdvertiseTheSelectedModel() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-sharellm-cn" }))
        let references = provider.orderedKeyReferences(selectedKeySlotID: "slot-2", model: "claude-opus-5")
        XCTAssertEqual(references, [ProviderCatalog.keyReference(providerID: provider.id, keySlotID: "slot-2")])
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
            "provider.sameProviderFailover": "true",
            "provider.reasoningEffort": "xhigh"
        ]

        let resolved = try ProviderCheckpointConfigurationResolver.resolve(payload: payload, profiles: profiles)
        XCTAssertEqual(resolved.providerID, provider.id)
        XCTAssertEqual(resolved.baseURL, provider.baseURL)
        XCTAssertEqual(resolved.apiKeyReference, primary)
        XCTAssertEqual(resolved.fallbackAPIKeyReferences, [fallback])
        XCTAssertEqual(resolved.protocolName, ProviderProtocol.anthropic.rawValue)
        XCTAssertEqual(resolved.authModeName, ProviderAuthMode.both.rawValue)
        XCTAssertEqual(resolved.reasoningEffort, .xhigh)

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
        XCTAssertEqual(migratedAgentRouter.fallbackProtocolNames, [ProviderProtocol.anthropic.rawValue])

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

    func testCheckpointConfigurationCarriesBoundedProtocolFallbacks() throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "ccs-7bdd07431575" }))
        let primary = ProviderCatalog.keyReference(providerID: provider.id, keySlotID: "slot-1")
        let resolved = try ProviderCheckpointConfigurationResolver.resolve(payload: [
            "provider.id": provider.id,
            "provider.baseURL": provider.baseURL.absoluteString,
            "provider.model": "claude-opus-5",
            "provider.keyReference": primary,
            "provider.sameProviderFailover": "false"
        ], profiles: ProviderCatalog.desktopSnapshot)
        XCTAssertEqual(resolved.protocolName, ProviderProtocol.anthropic.rawValue)
        XCTAssertEqual(resolved.fallbackProtocolNames, [ProviderProtocol.openAIChat.rawValue])
        XCTAssertEqual(resolved.protocolNamesByKeyReference?[primary], [ProviderProtocol.anthropic.rawValue, ProviderProtocol.openAIChat.rawValue])
    }

    func testProviderConfigurationDecodesLegacyPayloadWithoutFallbackProtocols() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "name": "Legacy",
            "baseURL": "https://example.com",
            "model": "model",
            "apiKeyReference": "primary",
            "providerID": "legacy",
            "protocolName": ProviderProtocol.anthropic.rawValue,
            "authModeName": ProviderAuthMode.bearer.rawValue
        ])
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.fallbackProtocolNames)
        XCTAssertNil(decoded.protocolNamesByKeyReference)
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

    func testSameProviderModelUnavailableRotatesToNextKey() async throws {
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
        let text = try await collectText(router.stream(configuration: configuration, apiKey: "model-missing", messages: [], tools: []))
        XCTAssertEqual(text, "good")
    }

    func testModelUnavailableFallsBackToAlternateProtocolBeforeLeavingProviderRoute() async throws {
        let vault = MemoryKeyVault()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: AlwaysFailureProvider(error: .modelUnavailable(503)),
            openAIChat: FixedProvider(token: "chat-fallback"),
            responses: FixedProvider(token: "responses")
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]
        let text = try await collectText(router.stream(configuration: configuration, apiKey: "primary", messages: [], tools: []))
        XCTAssertEqual(text, "chat-fallback")
    }

    func testProtocolCompatibilityErrorFallsBackBeforeAnyOutput() async throws {
        let vault = MemoryKeyVault()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: AlwaysFailureProvider(error: .protocolIncompatible("unsupported compatibility envelope")),
            openAIChat: FixedProvider(token: "chat-fallback"),
            responses: FixedProvider(token: "responses")
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]
        let text = try await collectText(router.stream(configuration: configuration, apiKey: "primary", messages: [], tools: []))
        XCTAssertEqual(text, "chat-fallback")
    }

    func testKeyScopedProtocolMapChangesProtocolWhenRotatingKeys() async throws {
        let vault = MemoryKeyVault(keys: ["fallback": "fallback-key"])
        let recorder = RecordingKeyProtocolOutcomeProvider()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: recorder,
            openAIChat: recorder,
            responses: recorder
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]
        configuration.protocolNamesByKeyReference = [
            "primary": [ProviderProtocol.anthropic.rawValue],
            "fallback": [ProviderProtocol.openAIChat.rawValue]
        ]
        configuration.allowSameProviderKeyFailover = true

        let text = try await collectText(router.stream(configuration: configuration, apiKey: "primary-key", messages: [], tools: []))
        let seen = await recorder.routesSeen()
        XCTAssertEqual(text, "fallback-route-good")
        XCTAssertEqual(seen, [
            "primary-key|\(ProviderProtocol.anthropic.rawValue)",
            "fallback-key|\(ProviderProtocol.openAIChat.rawValue)"
        ])
    }

    func testSuccessfulFallbackProtocolIsPreferredOnLaterToolRound() async throws {
        let vault = MemoryKeyVault()
        let recorder = RecordingProtocolOutcomeProvider()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: recorder,
            openAIChat: recorder,
            responses: recorder
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]

        let first = try await collectText(router.stream(configuration: configuration, apiKey: "primary", messages: [], tools: []))
        let second = try await collectText(router.stream(configuration: configuration, apiKey: "primary", messages: [], tools: []))
        let seen = await recorder.protocolsSeen()
        XCTAssertEqual(first, "chat-good")
        XCTAssertEqual(second, "chat-good")
        XCTAssertEqual(seen, [ProviderProtocol.anthropic.rawValue, ProviderProtocol.openAIChat.rawValue, ProviderProtocol.openAIChat.rawValue])
    }

    func testProtocolFallbackNeverReplaysAfterProviderOutput() async throws {
        let vault = MemoryKeyVault()
        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: PartialThenFailureProvider(),
            openAIChat: FixedProvider(token: "must-not-run"),
            responses: FixedProvider(token: "responses")
        )
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]
        var text = ""
        do {
            for try await event in router.stream(configuration: configuration, apiKey: "primary", messages: [], tools: []) {
                if case .token(let token) = event { text += token }
            }
            XCTFail("Output followed by failure must never replay through another protocol")
        } catch {
            XCTAssertEqual(error as? ProviderError, .streamInterrupted)
        }
        XCTAssertEqual(text, "partial")
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

    func testSuccessfulFallbackPreferenceIsReusedAcrossEquivalentConfigurations() async throws {
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
        XCTAssertEqual(seen, ["bad-auth", "good", "good"])
    }

    func testSuccessfulFallbackPreferenceRemainsIsolatedByModel() async throws {
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
        second.model = "different-model"
        second.fallbackAPIKeyReferences = ["fallback"]
        second.allowSameProviderKeyFailover = true

        _ = try await collectText(router.stream(configuration: first, apiKey: "bad-auth", messages: [], tools: []))
        _ = try await collectText(router.stream(configuration: second, apiKey: "bad-auth", messages: [], tools: []))
        let seen = await recorder.keysSeen()
        XCTAssertEqual(seen, ["bad-auth", "good", "bad-auth", "good"])
    }

    func testSuccessfulProtocolPreferencePersistsAcrossRouterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeProviderRouteState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("verified-routes.json")
        let vault = MemoryKeyVault()
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]

        let firstRecorder = RecordingProtocolOutcomeProvider()
        let firstRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: firstRecorder,
            openAIChat: firstRecorder,
            responses: firstRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        let firstText = try await collectText(firstRouter.stream(configuration: configuration, apiKey: "same-key", messages: [], tools: []))
        let firstSeen = await firstRecorder.protocolsSeen()
        XCTAssertEqual(firstText, "chat-good")
        XCTAssertEqual(firstSeen, [ProviderProtocol.anthropic.rawValue, ProviderProtocol.openAIChat.rawValue])
        let persistedRouteState = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(persistedRouteState.contains("same-key"))

        let restartedRecorder = RecordingProtocolOutcomeProvider()
        let restartedRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: restartedRecorder,
            openAIChat: restartedRecorder,
            responses: restartedRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        let restartedText = try await collectText(restartedRouter.stream(configuration: configuration, apiKey: "same-key", messages: [], tools: []))
        let restartedSeen = await restartedRecorder.protocolsSeen()
        XCTAssertEqual(restartedText, "chat-good")
        XCTAssertEqual(restartedSeen, [ProviderProtocol.openAIChat.rawValue])
    }

    func testChangingAuthModeDoesNotReuseOldProtocolEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeProviderAuthIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("verified-routes.json")
        let vault = MemoryKeyVault()
        var bearerConfiguration = config(protocolName: .anthropic)
        bearerConfiguration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]
        bearerConfiguration.authModeName = ProviderAuthMode.bearer.rawValue

        let firstRecorder = RecordingProtocolOutcomeProvider()
        let firstRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: firstRecorder,
            openAIChat: firstRecorder,
            responses: firstRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(firstRouter.stream(configuration: bearerConfiguration, apiKey: "same-key", messages: [], tools: []))
        let firstSeenProtocols = await firstRecorder.protocolsSeen()
        XCTAssertEqual(firstSeenProtocols, [ProviderProtocol.anthropic.rawValue, ProviderProtocol.openAIChat.rawValue])

        var changedAuthConfiguration = bearerConfiguration
        changedAuthConfiguration.authModeName = ProviderAuthMode.xAPIKey.rawValue
        let changedRecorder = RecordingProtocolOutcomeProvider()
        let changedRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: changedRecorder,
            openAIChat: changedRecorder,
            responses: changedRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(changedRouter.stream(configuration: changedAuthConfiguration, apiKey: "same-key", messages: [], tools: []))
        let changedSeenProtocols = await changedRecorder.protocolsSeen()
        XCTAssertEqual(changedSeenProtocols, [ProviderProtocol.anthropic.rawValue, ProviderProtocol.openAIChat.rawValue])
    }

    func testPersistedHostPreferencePreservesConfiguredAPIPath() async {
        let state = ProviderRequestKeyState(ttl: 3600)
        let configured = URL(string: "https://api.example.com/v1")!
        await state.markSuccessfulBaseURL(routingKey: "provider|key|host", reference: "key", baseURL: configured)
        let preferred = await state.preferredBaseURL(
            routingKey: "provider|key|host",
            reference: "key",
            allowedBaseURLs: [configured],
            fallback: configured
        )
        XCTAssertEqual(preferred.absoluteString, "https://api.example.com/v1")
    }

    func testAgentRouterHostFallbackPersistsForExactKeyAcrossRouterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeProviderHostRoute-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("verified-routes.json")
        let vault = MemoryKeyVault()
        var configuration = config(protocolName: .anthropic)
        configuration.providerID = ProviderCatalog.agentRouterID
        configuration.baseURL = URL(string: "https://co.agentrouter.org")!

        let firstRecorder = RecordingHostOutcomeProvider()
        let firstRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: firstRecorder,
            openAIChat: firstRecorder,
            responses: firstRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        let firstText = try await collectText(firstRouter.stream(configuration: configuration, apiKey: "unknown-key-content", messages: [], tools: []))
        let firstHosts = await firstRecorder.hostsSeen()
        XCTAssertEqual(firstText, "legacy-host-good")
        XCTAssertEqual(firstHosts, ["co.agentrouter.org", "agentrouter.org"])

        let restartedRecorder = RecordingHostOutcomeProvider()
        let restartedRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: restartedRecorder,
            openAIChat: restartedRecorder,
            responses: restartedRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        let restartedText = try await collectText(restartedRouter.stream(configuration: configuration, apiKey: "unknown-key-content", messages: [], tools: []))
        let restartedHosts = await restartedRecorder.hostsSeen()
        XCTAssertEqual(restartedText, "legacy-host-good")
        XCTAssertEqual(restartedHosts, ["agentrouter.org"])
    }

    func testAgentRouterHostEvidenceIsIsolatedWhenKeyContentChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeProviderHostIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("verified-routes.json")
        let vault = MemoryKeyVault()
        var configuration = config(protocolName: .anthropic)
        configuration.providerID = ProviderCatalog.agentRouterID
        configuration.baseURL = URL(string: "https://co.agentrouter.org")!

        let firstRecorder = RecordingHostOutcomeProvider()
        let firstRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: firstRecorder,
            openAIChat: firstRecorder,
            responses: firstRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(firstRouter.stream(configuration: configuration, apiKey: "first-key", messages: [], tools: []))

        let changedRecorder = RecordingHostOutcomeProvider()
        let changedRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: changedRecorder,
            openAIChat: changedRecorder,
            responses: changedRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(changedRouter.stream(configuration: configuration, apiKey: "second-key", messages: [], tools: []))
        let changedHosts = await changedRecorder.hostsSeen()
        XCTAssertEqual(changedHosts, ["co.agentrouter.org", "agentrouter.org"])
    }

    func testAgentRouterProtocolEvidenceIsScopedToExactHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeProviderHostProtocolScope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("verified-routes.json")
        let vault = MemoryKeyVault()
        let recorder = RecordingHostProtocolOutcomeProvider()
        var configuration = config(protocolName: .anthropic)
        configuration.providerID = ProviderCatalog.agentRouterID
        configuration.baseURL = URL(string: "https://co.agentrouter.org")!
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]

        let router = ProviderClientRouter(
            keyVault: vault,
            anthropic: recorder,
            openAIChat: recorder,
            responses: recorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        let first = try await collectText(router.stream(configuration: configuration, apiKey: "same-key", messages: [], tools: []))
        XCTAssertEqual(first, "first-good")
        let second = try await collectText(router.stream(configuration: configuration, apiKey: "same-key", messages: [], tools: []))
        XCTAssertEqual(second, "second-good")
        let seen = await recorder.routesSeen()
        XCTAssertEqual(seen, [
            "co.agentrouter.org|\(ProviderProtocol.anthropic.rawValue)",
            "agentrouter.org|\(ProviderProtocol.anthropic.rawValue)",
            "agentrouter.org|\(ProviderProtocol.openAIChat.rawValue)",
            "agentrouter.org|\(ProviderProtocol.openAIChat.rawValue)",
            "co.agentrouter.org|\(ProviderProtocol.anthropic.rawValue)"
        ])
    }

    func testAgentRouterRateLimitDoesNotReplayOnAlternateHost() async throws {
        let vault = MemoryKeyVault()
        let recorder = RecordingRateLimitedHostProvider()
        var configuration = config(protocolName: .anthropic)
        configuration.providerID = ProviderCatalog.agentRouterID
        configuration.baseURL = URL(string: "https://co.agentrouter.org")!
        let router = ProviderClientRouter(keyVault: vault, anthropic: recorder, openAIChat: recorder, responses: recorder)
        do {
            _ = try await collectText(router.stream(configuration: configuration, apiKey: "unknown-key", messages: [], tools: []))
            XCTFail("429/rate-limit must not replay on the alternate AgentRouter host")
        } catch {
            XCTAssertEqual(error as? ProviderError, .rateLimited)
        }
        let seenHosts = await recorder.hostsSeen()
        XCTAssertEqual(seenHosts, ["co.agentrouter.org"])
    }

    func testAgentRouterOutputThenFailureDoesNotReplayOnAlternateHost() async throws {
        let vault = MemoryKeyVault()
        let recorder = RecordingPartialHostProvider()
        var configuration = config(protocolName: .anthropic)
        configuration.providerID = ProviderCatalog.agentRouterID
        configuration.baseURL = URL(string: "https://co.agentrouter.org")!
        let router = ProviderClientRouter(keyVault: vault, anthropic: recorder, openAIChat: recorder, responses: recorder)
        var text = ""
        do {
            for try await event in router.stream(configuration: configuration, apiKey: "unknown-key", messages: [], tools: []) {
                if case .token(let token) = event { text += token }
            }
            XCTFail("Provider output must prohibit host replay")
        } catch {
            XCTAssertEqual(error as? ProviderError, .streamInterrupted)
        }
        XCTAssertEqual(text, "partial")
        let seenHosts = await recorder.hostsSeen()
        XCTAssertEqual(seenHosts, ["co.agentrouter.org"])
    }

    func testReplacingKeyContentDoesNotReuseOldExactProtocolEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeProviderKeyIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("verified-routes.json")
        let vault = MemoryKeyVault()
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackProtocolNames = [ProviderProtocol.openAIChat.rawValue]

        let initialRecorder = RecordingProtocolOutcomeProvider()
        let initialRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: initialRecorder,
            openAIChat: initialRecorder,
            responses: initialRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(initialRouter.stream(configuration: configuration, apiKey: "old-key-content", messages: [], tools: []))

        let replacedRecorder = RecordingProtocolOutcomeProvider()
        let replacedRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: replacedRecorder,
            openAIChat: replacedRecorder,
            responses: replacedRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        let replacedText = try await collectText(replacedRouter.stream(configuration: configuration, apiKey: "new-key-content", messages: [], tools: []))
        let replacedSeen = await replacedRecorder.protocolsSeen()
        XCTAssertEqual(replacedText, "chat-good")
        XCTAssertEqual(replacedSeen, [ProviderProtocol.anthropic.rawValue, ProviderProtocol.openAIChat.rawValue])
    }

    func testSuccessfulFallbackKeyPreferencePersistsOnlyForSameKeyPool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeProviderKeyPool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("verified-routes.json")
        let vault = MemoryKeyVault(keys: ["fallback": "good"])
        var configuration = config(protocolName: .anthropic)
        configuration.fallbackAPIKeyReferences = ["fallback"]
        configuration.allowSameProviderKeyFailover = true

        let firstRecorder = RecordingKeyOutcomeProvider()
        let firstRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: firstRecorder,
            openAIChat: firstRecorder,
            responses: firstRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(firstRouter.stream(configuration: configuration, apiKey: "bad-auth", messages: [], tools: []))
        let firstKeys = await firstRecorder.keysSeen()
        XCTAssertEqual(firstKeys, ["bad-auth", "good"])

        let restartedRecorder = RecordingKeyOutcomeProvider()
        let restartedRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: restartedRecorder,
            openAIChat: restartedRecorder,
            responses: restartedRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(restartedRouter.stream(configuration: configuration, apiKey: "bad-auth", messages: [], tools: []))
        let restartedKeys = await restartedRecorder.keysSeen()
        XCTAssertEqual(restartedKeys, ["good"])

        let changedPoolRecorder = RecordingKeyOutcomeProvider()
        let changedPoolRouter = ProviderClientRouter(
            keyVault: vault,
            anthropic: changedPoolRecorder,
            openAIChat: changedPoolRecorder,
            responses: changedPoolRecorder,
            requestKeyState: ProviderRequestKeyState(fileURL: stateURL)
        )
        _ = try await collectText(changedPoolRouter.stream(configuration: configuration, apiKey: "different-bad-auth", messages: [], tools: []))
        let changedPoolKeys = await changedPoolRecorder.keysSeen()
        XCTAssertEqual(changedPoolKeys, ["different-bad-auth"])
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

    func testAgentRouterModelDiscoveryUsesCompatibleClientIdentity() async throws {
        ProviderTestURLProtocol.install(
            status: 200,
            body: Data("{\"data\":[{\"id\":\"glm-5.3\"}]}".utf8),
            headers: ["Content-Type": "application/json"]
        )
        defer { ProviderTestURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let models = try await ProviderDiscoveryClient(session: session).discoverModels(
            baseURL: URL(string: "https://co.agentrouter.org")!,
            apiKey: "test-secret",
            authMode: .bearer
        )
        XCTAssertEqual(models, ["glm-5.3"])
        let request = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://co.agentrouter.org/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-cli/1.0.120 (external, cli)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app"), "cli")
    }

    func testAgentRouterDiscoveryCanRestrictCatalogToPreferredAuthMode() async throws {
        ProviderTestURLProtocol.install(
            status: 401,
            body: Data("{\"error\":\"invalid api key\"}".utf8),
            headers: ["Content-Type": "application/json"]
        )
        defer { ProviderTestURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await ProviderDiscoveryClient(session: session).discover(
                baseURL: URL(string: "https://co.agentrouter.org")!,
                apiKey: "test-secret",
                preferredAuthMode: .bearer,
                allowAlternateAuthModes: false
            )
            XCTFail("401 should remain a route/auth failure for the caller to handle")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationFailed(401))
        }
        XCTAssertEqual(ProviderTestURLProtocol.requestCount(), 1)
        let request = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testDiscoveryFindsInferenceAuthModeInsteadOfTrustingModelsEndpointAlone() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderDiscoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://custom.example")!,
            apiKey: "test-secret",
            preferredAuthMode: .both,
            allowPricingCatalogFallback: true
        )
        XCTAssertEqual(result.models, ["model-a"])
        XCTAssertEqual(result.authMode, .both)
        XCTAssertEqual(result.protocols, [.anthropic])
        XCTAssertEqual(result.readiness, .ready)
    }

    func testDiscoveryFallsBackToPricingCatalogKeyedByModelAndKeepsDualInferenceAuth() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderPricingDiscoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://tabitoken.com")!,
            apiKey: "test-secret",
            preferredAuthMode: .both,
            allowPricingCatalogFallback: true
        )

        XCTAssertEqual(result.models, ["claude-sonnet-live"])
        XCTAssertEqual(result.authMode, .both)
        XCTAssertEqual(result.protocols, [.anthropic])
        XCTAssertEqual(result.readiness, .ready)
    }

    func testDiscoveryTreatsSuccessfulEmptyCatalogAsUnavailable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderEmptyDiscoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://tabitoken.com")!,
            apiKey: "test-secret",
            preferredAuthMode: .both,
            allowPricingCatalogFallback: true
        )

        XCTAssertEqual(result.models, [])
        XCTAssertEqual(result.protocols, [])
        XCTAssertEqual(result.authMode, .both)
        XCTAssertEqual(result.readiness, .unavailable)
    }

    func testProviderProfilePreservesCatalogWhenDiscoveryReturnsEmptyUnavailableResult() throws {
        var profile = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.tabitokenID }))
        let original = profile
        let staleSelection = ProviderSelectionState(providerID: profile.id, keySlotID: "slot-1", model: profile.models[0])

        profile.applyDiscovery(
            ProviderDiscoveryResult(models: [], protocols: [], authMode: .both, readiness: .unavailable),
            keySlotID: "slot-1"
        )

        XCTAssertEqual(profile, original)
        let reconciled = ProviderSelectionResolver.reconcile(staleSelection, profiles: [profile])
        XCTAssertEqual(reconciled, staleSelection)
    }

    func testProviderProfilePreservesCatalogWhenDiscoveryHasModelsButProtocolIsUnverified() throws {
        var profile = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-api-justwoker-icu" }))
        let original = profile

        profile.applyDiscovery(
            ProviderDiscoveryResult(models: ["unexpected-catalog-model"], protocols: [], authMode: .xAPIKey, readiness: .needsValidation),
            keySlotID: "slot-1"
        )

        XCTAssertEqual(profile, original)
    }

    func testDiscoveryUsesConfiguredCandidateOnlyAfterLiveInferenceValidationWhenCatalogIsEmpty() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderEmptyCatalogLiveInferenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://tabitoken.com")!,
            apiKey: "test-secret",
            preferredAuthMode: .both,
            allowPricingCatalogFallback: true,
            fallbackInferenceCandidates: ["stale-model", "claude-opus-live"],
            inferenceProtocols: [.anthropic]
        )

        XCTAssertEqual(result.models, ["claude-opus-live"])
        XCTAssertEqual(result.protocols, [.anthropic])
        XCTAssertEqual(result.authMode, .both)
        XCTAssertEqual(result.readiness, .ready)
    }

    func testDiscoveryLiveValidatesConfiguredCandidateWhenReachableCatalogWrapperIsUnparseable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderUnparseableCatalogLiveInferenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://community.example")!,
            apiKey: "test-secret",
            preferredAuthMode: .bearer,
            fallbackInferenceCandidates: ["claude-opus-live"],
            inferenceProtocols: [.anthropic]
        )

        XCTAssertEqual(result.models, ["claude-opus-live"])
        XCTAssertEqual(result.protocols, [.anthropic])
        XCTAssertEqual(result.authMode, .bearer)
        XCTAssertEqual(result.readiness, .ready)
    }

    func testDiscoveryFallsBackToRatioConfigWhenModelsAndPricingAreEmpty() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderRatioDiscoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = try await ProviderDiscoveryClient(session: session).discover(
            baseURL: URL(string: "https://tabitoken.com")!,
            apiKey: "test-secret",
            preferredAuthMode: .both,
            allowPricingCatalogFallback: true
        )

        XCTAssertEqual(result.models, ["claude-opus-live"])
        XCTAssertEqual(result.authMode, .both)
        XCTAssertEqual(result.protocols, [.anthropic])
        XCTAssertEqual(result.readiness, .ready)
    }

    func testProviderProfileLiveDiscoveryEnrichesWithoutShrinkingSelectableCatalog() throws {
        var profile = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.tabitokenID }))
        let originalProviderModels = profile.models
        let originalSlot1Models = profile.selectableModels(for: "slot-1")
        let originalSlot2Models = profile.selectableModels(for: "slot-2")
        let discovery = ProviderDiscoveryResult(
            models: ["live-model-a", "live-model-b", "live-model-a"],
            protocols: [.anthropic],
            authMode: .both,
            readiness: .ready
        )

        profile.applyDiscovery(discovery, keySlotID: "slot-1")

        XCTAssertTrue(originalProviderModels.allSatisfy { profile.models.contains($0) })
        XCTAssertTrue(profile.models.contains("live-model-a"))
        XCTAssertTrue(profile.models.contains("live-model-b"))
        XCTAssertTrue(originalSlot1Models.allSatisfy { profile.selectableModels(for: "slot-1").contains($0) })
        XCTAssertTrue(profile.selectableModels(for: "slot-1").contains("live-model-a"))
        XCTAssertEqual(profile.selectableModels(for: "slot-2"), originalSlot2Models)
        XCTAssertTrue(profile.protocols.contains(.anthropic))
        XCTAssertEqual(profile.authMode, .both)
        XCTAssertEqual(profile.readiness, .ready)

        let reconciled = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: profile.id, keySlotID: "slot-3", model: "claude-opus-5"),
            profiles: [profile]
        )
        XCTAssertEqual(reconciled.providerID, profile.id)
        XCTAssertEqual(reconciled.keySlotID, "slot-3")
        XCTAssertEqual(reconciled.model, "claude-opus-5")
    }

    func testAuthFailedKeyDoesNotEraseSelectableModels() throws {
        var profile = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-agentrouter-org" }))
        let originalModels = profile.selectableModels(for: "slot-1")
        XCTAssertFalse(originalModels.isEmpty)
        profile.keySlots[0].status = .authFailed

        XCTAssertTrue(profile.models(for: "slot-1").isEmpty)
        XCTAssertEqual(profile.selectableModels(for: "slot-1"), originalModels)
        let reconciled = ProviderSelectionResolver.reconcile(
            ProviderSelectionState(providerID: profile.id, keySlotID: "slot-1", model: "glm-5.2"),
            profiles: [profile]
        )
        XCTAssertEqual(reconciled.model, "glm-5.2")
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

    func testAnthropicErrorEnvelopePreservesUpstreamDetailForProtocolFallback() async throws {
        let body = Data("""
        data: {"error":{"type":"invalid_request_error","message":"tool schema is not supported on this compatibility route"}}

        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
        let client = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(
            name: "AgentRouter",
            baseURL: URL(string: "https://co.agentrouter.org")!,
            model: "deepseek-v4-flash",
            apiKeyReference: "key",
            providerID: ProviderCatalog.agentRouterID,
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue
        )
        do {
            for try await _ in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
            XCTFail("Expected compatibility error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .protocolIncompatible("tool schema is not supported on this compatibility route"))
        }
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

    func testAnthropicCompatibleProxyAcceptsOpenAIStyleChoiceEnvelopeAndBOM() async throws {
        let body = Data("""
        \u{feff}data: {"choices":[{"index":0,"delta":{"content":"compat-ok"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
        let client = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(name: "proxy", baseURL: URL(string: "https://proxy.example")!, model: "claude-opus-5", apiKeyReference: "key", protocolName: ProviderProtocol.anthropic.rawValue)
        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.token("compat-ok")))
        XCTAssertEqual(events.last, .finished)
    }

    func testReasoningEffortMapsToEachProtocolRequestBody() async throws {
        ProviderTestURLProtocol.install(status: 200, body: Data("data: [DONE]\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let chat = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let chatConfig = ProviderConfiguration(name: "chat", baseURL: URL(string: "https://example.com/v1")!, model: "gpt-5.6-sol", apiKeyReference: "k", protocolName: ProviderProtocol.openAIChat.rawValue, reasoningEffort: .xhigh)
        for try await _ in chat.stream(configuration: chatConfig, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
        let chatData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let chatBody = try XCTUnwrap(JSONSerialization.jsonObject(with: chatData) as? [String: Any])
        XCTAssertEqual(chatBody["reasoning_effort"] as? String, "xhigh")

        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"message_stop\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let anthropic = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let anthropicConfig = ProviderConfiguration(name: "anthropic", baseURL: URL(string: "https://example.com/v1")!, model: "claude-opus-5", apiKeyReference: "k", protocolName: ProviderProtocol.anthropic.rawValue, reasoningEffort: .max)
        for try await _ in anthropic.stream(configuration: anthropicConfig, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
        let anthropicData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let anthropicBody = try XCTUnwrap(JSONSerialization.jsonObject(with: anthropicData) as? [String: Any])
        let outputConfig = try XCTUnwrap(anthropicBody["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "max")

        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"response.completed\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let responses = OpenAIResponsesProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let responsesConfig = ProviderConfiguration(name: "responses", baseURL: URL(string: "https://example.com/v1")!, model: "gpt-5.6-sol", apiKeyReference: "k", protocolName: ProviderProtocol.openAIResponses.rawValue, reasoningEffort: .high)
        for try await _ in responses.stream(configuration: responsesConfig, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
        let responsesData = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let responsesBody = try XCTUnwrap(JSONSerialization.jsonObject(with: responsesData) as? [String: Any])
        let reasoning = try XCTUnwrap(responsesBody["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")
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

    func testAgentRouterHistoricalDeepSeekSeedUsesOpenAIChatOnLegacyOriginAndBearerAuth() async throws {
        let provider = try XCTUnwrap(ProviderCatalog.desktopSnapshot.first(where: { $0.id == "https-agentrouter-org" }))
        let slot = try XCTUnwrap(provider.keySlots.first(where: { $0.id == "slot-1" }))
        let protocolName = provider.protocolFor(model: "deepseek-v4-flash", keySlotID: "slot-1")
        XCTAssertEqual(protocolName, .openAIChat)
        XCTAssertEqual(provider.protocolCandidates(for: "deepseek-v4-flash", keySlotID: "slot-1"), [.openAIChat, .anthropic])
        let baseURL = try XCTUnwrap(ProviderEndpointRoutingPolicy.candidateBaseURLs(
            providerID: provider.id,
            configuredBaseURL: provider.baseURL,
            keyFingerprint: slot.fingerprint
        ).first)
        XCTAssertEqual(baseURL.host, "agentrouter.org")
        ProviderTestURLProtocol.install(
            status: 200,
            body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8),
            headers: ["Content-Type": "text/event-stream"]
        )
        let client = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(
            name: provider.displayName,
            baseURL: baseURL,
            model: "deepseek-v4-flash",
            apiKeyReference: ProviderCatalog.keyReference(providerID: provider.id, keySlotID: "slot-1"),
            providerID: provider.id,
            protocolName: protocolName.rawValue,
            authModeName: provider.authMode.rawValue
        )
        for try await _ in client.stream(configuration: configuration, apiKey: "test-secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
        let request = try XCTUnwrap(ProviderTestURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://agentrouter.org/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-cli/1.0.120 (external, cli)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app"), "cli")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "claude-code-20250219")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-stainless-runtime"), "node")
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
        XCTAssertNil(ProviderTestURLProtocol.lastRequest()?.value(forHTTPHeaderField: "x-app"))

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

    func testResponsesFailureEventPreservesUpstreamDetailAsProtocolIncompatibility() async throws {
        let body = Data("""
        data: {"type":"response.failed","response":{"status":"failed","error":{"code":"unsupported_stream","message":"responses streaming is not available for this model"}}}

        """.utf8)
        ProviderTestURLProtocol.install(status: 200, body: body, headers: ["Content-Type": "text/event-stream"])
        let client = OpenAIResponsesProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(
            name: "Responses",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "model-x",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIResponses.rawValue
        )
        do {
            for try await _ in client.stream(configuration: configuration, apiKey: "secret", messages: [ChatMessage(role: .user, content: "hi")], tools: []) {}
            XCTFail("expected provider error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .protocolIncompatible("responses streaming is not available for this model"))
        }
    }

    func testMultipleCurrentObservationImagesAreEncodedForAllProviderProtocols() async throws {
        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("CloudCode/Attachments/provider-multi-image-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let firstURL = support.appendingPathComponent("first-\(UUID().uuidString).jpg")
        let secondURL = support.appendingPathComponent("second-\(UUID().uuidString).jpg")
        let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x02, 0xFF, 0xD9])
        try first.write(to: firstURL, options: .atomic)
        try second.write(to: secondURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let message = ChatMessage(role: .user, content: "compare", attachments: [
            ChatAttachment(filename: "first.jpg", path: firstURL.path, mimeType: "image/jpeg", byteSize: Int64(first.count)),
            ChatAttachment(filename: "second.jpg", path: secondURL.path, mimeType: "image/jpeg", byteSize: Int64(second.count))
        ])

        ProviderTestURLProtocol.install(status: 200, body: Data("data: [DONE]\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let chat = OpenAICompatibleProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let chatConfig = ProviderConfiguration(name: "chat", baseURL: URL(string: "https://example.com/v1")!, model: "vision", apiKeyReference: "key", protocolName: ProviderProtocol.openAIChat.rawValue)
        for try await _ in chat.stream(configuration: chatConfig, apiKey: "secret", messages: [message], tools: []) {}
        let chatBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())) as? [String: Any])
        let chatMessages = try XCTUnwrap(chatBody["messages"] as? [[String: Any]])
        let chatContent = try XCTUnwrap(chatMessages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(chatContent.filter { $0["type"] as? String == "image_url" }.count, 2)

        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"message_stop\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let anthropic = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let anthropicConfig = ProviderConfiguration(name: "anthropic", baseURL: URL(string: "https://example.com/v1")!, model: "vision", apiKeyReference: "key", protocolName: ProviderProtocol.anthropic.rawValue)
        for try await _ in anthropic.stream(configuration: anthropicConfig, apiKey: "secret", messages: [message], tools: []) {}
        let anthropicBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())) as? [String: Any])
        let anthropicMessages = try XCTUnwrap(anthropicBody["messages"] as? [[String: Any]])
        let anthropicContent = try XCTUnwrap(anthropicMessages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(anthropicContent.filter { $0["type"] as? String == "image" }.count, 2)

        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"response.completed\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let responses = OpenAIResponsesProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let responsesConfig = ProviderConfiguration(name: "responses", baseURL: URL(string: "https://example.com/v1")!, model: "vision", apiKeyReference: "key", protocolName: ProviderProtocol.openAIResponses.rawValue)
        for try await _ in responses.stream(configuration: responsesConfig, apiKey: "secret", messages: [message], tools: []) {}
        let responsesBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())) as? [String: Any])
        let input = try XCTUnwrap(responsesBody["input"] as? [[String: Any]])
        let responsesContent = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(responsesContent.filter { $0["type"] as? String == "input_image" }.count, 2)
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

    func testAnthropicHistoryCoalescesRolesAndSanitizesNonObjectToolArguments() async throws {
        let messages = [
            ChatMessage(role: .user, content: "run"),
            ChatMessage(role: .assistant, content: "planning"),
            ChatMessage(role: .assistant, content: "", providerMetadata: [
                "tool_call_id": "call-1",
                "tool_name": "files.read",
                "tool_arguments": "[1,2,3]"
            ]),
            ChatMessage(role: .tool, content: "ok", providerMetadata: [
                "tool_call_id": "call-1",
                "tool_name": "files.read"
            ]),
            ChatMessage(role: .user, content: "continue")
        ]
        ProviderTestURLProtocol.install(status: 200, body: Data("data: {\"type\":\"message_stop\"}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        let client = AnthropicProviderClient(session: testSession(), retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0))
        let configuration = ProviderConfiguration(name: "a", baseURL: URL(string: "https://example.com/v1")!, model: "m", apiKeyReference: "k", protocolName: ProviderProtocol.anthropic.rawValue)
        for try await _ in client.stream(configuration: configuration, apiKey: "secret", messages: messages, tools: []) {}

        let data = try XCTUnwrap(ProviderTestURLProtocol.lastRequestBody())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(encoded.count, 3)
        XCTAssertEqual(encoded.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistantBlocks = try XCTUnwrap(encoded[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.count, 2)
        XCTAssertEqual(assistantBlocks[0]["type"] as? String, "text")
        XCTAssertEqual(assistantBlocks[1]["type"] as? String, "tool_use")
        XCTAssertEqual((assistantBlocks[1]["input"] as? [String: Any])?.count, 0)
        let finalUserBlocks = try XCTUnwrap(encoded[2]["content"] as? [[String: Any]])
        XCTAssertEqual(finalUserBlocks.map { $0["type"] as? String }, ["tool_result", "text"])
    }

    func testAgentRouterHTTP200PendingStreamStaysOnExactRouteAndIsReplaySafe() {
        let unknown = ProviderError.protocolIncompatible("上游未提供可解析的错误详情")
        let wait = ProviderError.protocolIncompatible("Waiting for API response")
        let hard = ProviderError.protocolIncompatible("tool schema is unsupported")

        XCTAssertNotNil(ProviderCompatibilityClassifier.agentRouterTransientStreamPendingDetail(unknown), "Within the AgentRouter HTTP-200/body/no-output guard, the opaque gateway sentinel is not protocol-incompatibility evidence.")
        XCTAssertNotNil(ProviderCompatibilityClassifier.agentRouterTransientStreamPendingDetail(wait))
        XCTAssertNotNil(ProviderCompatibilityClassifier.agentRouterTransientStreamPendingDetail(ProviderError.protocolIncompatible("Anthropic 流返回错误事件")))
        XCTAssertNil(ProviderCompatibilityClassifier.agentRouterTransientStreamPendingDetail(hard))

        let pending = ProviderError.upstreamPending("Waiting for API response")
        XCTAssertTrue(ProviderRetryClassifier.isRetryableBeforeOutput(pending))
        XCTAssertTrue(ProviderRetryClassifier.isReplaySafeAfterHTTPResponseBeforeOutput(pending))
        XCTAssertFalse(ProviderProtocolFallbackClassifier.shouldFallback(pending))
        XCTAssertFalse(ProviderHostFallbackClassifier.shouldFallback(pending))
        XCTAssertFalse(ProviderKeyRotationClassifier.shouldRotate(pending))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(pending))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeHost(pending, providerID: ProviderCatalog.agentRouterID))
    }

    func testAgentRouterOpaqueHTTP200PendingReplaysSameAnthropicRouteOnceBeforeOutput() async throws {
        AgentRouterPendingReplayURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentRouterPendingReplayURLProtocol.self]
        let client = AnthropicProviderClient(
            session: URLSession(configuration: configuration),
            retryPolicy: RetryPolicy(maxAttempts: 2, initialDelayNanoseconds: 0)
        )
        let provider = ProviderConfiguration(
            name: "AgentRouter",
            baseURL: URL(string: "https://agentrouter.org")!,
            model: "glm-5.3",
            apiKeyReference: "key",
            providerID: ProviderCatalog.agentRouterID,
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue
        )

        var events: [ProviderEvent] = []
        for try await event in client.stream(
            configuration: provider,
            apiKey: "test-secret",
            messages: [ChatMessage(role: .user, content: "hi")],
            tools: []
        ) {
            events.append(event)
        }

        XCTAssertEqual(events.last, .finished)
        XCTAssertTrue(events.contains { event in
            if case .status(let value) = event {
                return value.contains("等待上游 API") && value.contains("2/2")
            }
            return false
        }, "AgentRouter pending retries must surface the wait reason and bounded retry progress instead of looking like a disconnect")
        let requests = AgentRouterPendingReplayURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://agentrouter.org/v1/messages",
            "https://agentrouter.org/v1/messages"
        ])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret" })
    }

    func testAgentRouterTextOnlyCompatibilityRetryIsScopedToImageTypeRejection() {
        let image = ChatAttachment(filename: "screen.jpg", path: "/tmp/screen.jpg", mimeType: "image/jpeg", byteSize: 1024)
        let messages = [
            ChatMessage(role: .user, content: "Device screenshot", providerMetadata: ["internal_observation": "gui.screenshot"], attachments: [image])
        ]
        let body = Data("{\"error\":{\"message\":\"messages.4.content.1.type 参数非法，取值范围 ['text']\"}}".utf8)
        XCTAssertTrue(ProviderCompatibilityClassifier.shouldRetryAgentRouterWithoutImageAttachments(
            providerID: ProviderCatalog.agentRouterID,
            statusCode: 400,
            body: body,
            messages: messages
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryAgentRouterWithoutImageAttachments(
            providerID: "other-provider",
            statusCode: 400,
            body: body,
            messages: messages
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryAgentRouterWithoutImageAttachments(
            providerID: ProviderCatalog.agentRouterID,
            statusCode: 401,
            body: Data("{\"error\":\"invalid api key\"}".utf8),
            messages: messages
        ))
        let compacted = ProviderCompatibilityClassifier.agentRouterTextOnlyMessages(from: messages)
        XCTAssertTrue(compacted[0].attachments.isEmpty)
        XCTAssertEqual(compacted[0].providerMetadata["provider_image_compatibility"], "text_only_retry")
        XCTAssertTrue(compacted[0].content.contains("do not claim to have seen"))
    }

    func testProviderVisionCapabilityUsesMetadataBeforeTinyProbe() async throws {
        ProviderVisionCapabilityURLProtocol.install(mode: .metadataSupported)
        defer { ProviderVisionCapabilityURLProtocol.reset() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderVisionCapabilityURLProtocol.self]
        let client = OpenAICompatibleProviderClient(
            session: URLSession(configuration: sessionConfiguration),
            retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)
        )
        let configuration = ProviderConfiguration(
            name: "vision-metadata",
            baseURL: URL(string: "https://vision-metadata.example/v1")!,
            model: "vision-model-metadata",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIChat.rawValue
        )

        let assessment = await client.imageCapability(configuration: configuration, apiKey: "metadata-secret")

        XCTAssertEqual(assessment.capability, .supported)
        XCTAssertEqual(assessment.source, "models_metadata")
        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.requestCount(), 1)
        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.paths(), ["/v1/models"])

        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("CloudCode/Attachments/provider-vision-supported-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let imageURL = support.appendingPathComponent("supported-screenshot-\(UUID().uuidString).jpg")
        let imageBytes = Data([0xFF, 0xD8, 0x44, 0x55, 0x66, 0xFF, 0xD9])
        try imageBytes.write(to: imageURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let screenshot = ChatMessage(
            role: .user,
            content: "Device screenshot",
            providerMetadata: ["internal_observation": "gui.screenshot"],
            attachments: [ChatAttachment(filename: imageURL.lastPathComponent, path: imageURL.path, mimeType: "image/jpeg", byteSize: Int64(imageBytes.count))]
        )
        for try await _ in client.stream(configuration: configuration, apiKey: "metadata-secret", messages: [screenshot], tools: []) {}

        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.requestCount(), 2, "cached metadata support must avoid a second capability probe")
        let realRequestData = try XCTUnwrap(ProviderVisionCapabilityURLProtocol.bodies().last)
        let realRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: realRequestData) as? [String: Any])
        let messages = try XCTUnwrap(realRequest["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let imagePart = try XCTUnwrap(content.first(where: { ($0["type"] as? String) == "image_url" }))
        let imageDataURL = try XCTUnwrap((imagePart["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(imageDataURL.hasSuffix(imageBytes.base64EncodedString()))
    }

    func testProviderVisionCapabilityTinyProbeRunsOnceAndPreventsRealScreenshotSerializationWhenTextOnly() async throws {
        ProviderVisionCapabilityURLProtocol.install(mode: .tinyProbeTextOnly)
        defer { ProviderVisionCapabilityURLProtocol.reset() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderVisionCapabilityURLProtocol.self]
        let client = OpenAICompatibleProviderClient(
            session: URLSession(configuration: sessionConfiguration),
            retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)
        )
        let configuration = ProviderConfiguration(
            name: "vision-probe",
            baseURL: URL(string: "https://vision-probe.example/v1")!,
            model: "vision-probe-model-\(UUID().uuidString)",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIChat.rawValue
        )

        let first = await client.imageCapability(configuration: configuration, apiKey: "probe-secret")
        let second = await client.imageCapability(configuration: configuration, apiKey: "probe-secret")
        XCTAssertEqual(first.capability, .textOnly)
        XCTAssertEqual(first.source, "tiny_image_probe")
        XCTAssertEqual(second, first)
        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.requestCount(), 2, "metadata GET + exactly one tiny-image POST")
        let probeBodies = ProviderVisionCapabilityURLProtocol.bodies()
        XCTAssertTrue(probeBodies.contains { body in
            String(data: body, encoding: .utf8)?.contains("iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB") == true
        })

        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("CloudCode/Attachments/provider-vision-gate-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let imageURL = support.appendingPathComponent("real-screenshot-\(UUID().uuidString).jpg")
        let imageBytes = Data([0xFF, 0xD8, 0x11, 0x22, 0x33, 0xFF, 0xD9])
        try imageBytes.write(to: imageURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let screenshot = ChatMessage(
            role: .user,
            content: "Device screenshot",
            providerMetadata: ["internal_observation": "gui.screenshot"],
            attachments: [ChatAttachment(filename: imageURL.lastPathComponent, path: imageURL.path, mimeType: "image/jpeg", byteSize: Int64(imageBytes.count))]
        )
        let toolSchemas = try ["gui.tap", "gui.tapObserve", "gui.tapTextObserve"].map { internalName in
            ProviderToolSchema(name: try ProviderToolNameMap.encode(internalName), description: internalName)
        }
        for try await _ in client.stream(configuration: configuration, apiKey: "probe-secret", messages: [screenshot], tools: toolSchemas) {}

        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.requestCount(), 3)
        let realRequestBody = try XCTUnwrap(ProviderVisionCapabilityURLProtocol.bodies().last)
        let realRequestText = String(data: realRequestBody, encoding: .utf8) ?? ""
        XCTAssertFalse(realRequestText.contains(imageBytes.base64EncodedString()))
        XCTAssertFalse(realRequestText.contains("image_url"))
        XCTAssertTrue(realRequestText.contains("image-input capability is not proven") || realRequestText.contains("not proven able to consume image input"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: realRequestBody) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let names = tools.compactMap { tool -> String? in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertFalse(names.contains(try ProviderToolNameMap.encode("gui.tap")))
        XCTAssertFalse(names.contains(try ProviderToolNameMap.encode("gui.tapObserve")))
        XCTAssertTrue(names.contains(try ProviderToolNameMap.encode("gui.tapTextObserve")))
    }

    func testProviderVisionCapabilityInconclusiveTinyProbeStaysUnknown() async throws {
        ProviderVisionCapabilityURLProtocol.install(mode: .tinyProbeUnknown)
        defer { ProviderVisionCapabilityURLProtocol.reset() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderVisionCapabilityURLProtocol.self]
        let client = OpenAICompatibleProviderClient(
            session: URLSession(configuration: sessionConfiguration),
            retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)
        )
        let configuration = ProviderConfiguration(
            name: "vision-unknown",
            baseURL: URL(string: "https://vision-unknown.example/v1")!,
            model: "vision-unknown-model-\(UUID().uuidString)",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIChat.rawValue
        )

        let assessment = await client.imageCapability(configuration: configuration, apiKey: "unknown-secret")
        let cached = await client.imageCapability(configuration: configuration, apiKey: "unknown-secret")

        XCTAssertEqual(assessment.capability, .unknown)
        XCTAssertEqual(assessment.source, "tiny_image_probe_inconclusive")
        XCTAssertEqual(cached, assessment)
        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.requestCount(), 2, "metadata GET + one bounded 1px probe; unknown must remain cached for the runtime window")
        let cachedPolicyAssessment = await ProviderImageCompatibilityPolicy.currentAssessment(configuration: configuration, apiKey: "unknown-secret")
        XCTAssertEqual(cachedPolicyAssessment.capability, .unknown)

        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("CloudCode/Attachments/provider-vision-unknown-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let imageURL = support.appendingPathComponent("unknown-route-screen-\(UUID().uuidString).jpg")
        let imageBytes = Data([0xFF, 0xD8, 0x44, 0x55, 0x66, 0xFF, 0xD9])
        try imageBytes.write(to: imageURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let screenshot = ChatMessage(
            role: .user,
            content: "Device screenshot",
            providerMetadata: ["internal_observation": "gui.screenshot"],
            attachments: [ChatAttachment(filename: imageURL.lastPathComponent, path: imageURL.path, mimeType: "image/jpeg", byteSize: Int64(imageBytes.count))]
        )
        let toolSchemas = try ["gui.tap", "gui.tapObserve", "gui.tapTextObserve"].map { internalName in
            ProviderToolSchema(name: try ProviderToolNameMap.encode(internalName), description: internalName)
        }
        for try await _ in client.stream(configuration: configuration, apiKey: "unknown-secret", messages: [screenshot], tools: toolSchemas) {}
        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.requestCount(), 3)
        let body = ProviderVisionCapabilityURLProtocol.bodies().last ?? Data()
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains(imageBytes.base64EncodedString()))
        XCTAssertFalse(text.contains("image_url"))
        let rawObject = try JSONSerialization.jsonObject(with: body)
        let object = try XCTUnwrap(rawObject as? [String: Any])
        let tools = object["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { tool -> String? in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertFalse(names.contains(try ProviderToolNameMap.encode("gui.tap")))
        XCTAssertFalse(names.contains(try ProviderToolNameMap.encode("gui.tapObserve")))
        XCTAssertTrue(names.contains(try ProviderToolNameMap.encode("gui.tapTextObserve")))
    }

    func testUnknownVisionRouteWithoutAttachmentWithholdsFreeCoordinateToolsWithoutCapabilityProbe() async throws {
        ProviderVisionCapabilityURLProtocol.install(mode: .tinyProbeUnknown)
        defer { ProviderVisionCapabilityURLProtocol.reset() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderVisionCapabilityURLProtocol.self]
        let client = OpenAICompatibleProviderClient(
            session: URLSession(configuration: sessionConfiguration),
            retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)
        )
        let configuration = ProviderConfiguration(
            name: "vision-unknown-text-round",
            baseURL: URL(string: "https://vision-unknown-text-round.example/v1")!,
            model: "vision-unknown-text-round-model-\(UUID().uuidString)",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIChat.rawValue
        )
        let toolSchemas = try ["gui.tap", "gui.tapObserve", "gui.tapTextObserve"].map { internalName in
            ProviderToolSchema(name: try ProviderToolNameMap.encode(internalName), description: internalName)
        }

        for try await _ in client.stream(
            configuration: configuration,
            apiKey: "unknown-text-round-secret",
            messages: [ChatMessage(role: .user, content: "continue from local OCR evidence")],
            tools: toolSchemas
        ) {}

        XCTAssertEqual(ProviderVisionCapabilityURLProtocol.requestCount(), 1, "a text-only round must not trigger /models or a tiny-image capability probe")
        XCTAssertFalse(ProviderVisionCapabilityURLProtocol.paths().contains(where: { $0.hasSuffix("/models") }))
        let body = try XCTUnwrap(ProviderVisionCapabilityURLProtocol.bodies().last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let names = tools.compactMap { tool -> String? in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertFalse(names.contains(try ProviderToolNameMap.encode("gui.tap")))
        XCTAssertFalse(names.contains(try ProviderToolNameMap.encode("gui.tapObserve")))
        XCTAssertTrue(names.contains(try ProviderToolNameMap.encode("gui.tapTextObserve")))
    }

    func testProviderClientRouterVisionPreflightUsesRouterPreferredExactHostAndProtocol() async throws {
        let recorder = ImageCapabilityRecordingProvider(
            assessment: ProviderImageCapabilityAssessment(capability: .supported, source: "router_mock")
        )
        let router = ProviderClientRouter(
            keyVault: MemoryKeyVault(keys: [:]),
            anthropic: recorder,
            openAIChat: recorder,
            responses: recorder,
            requestKeyState: ProviderRequestKeyState()
        )
        let configuration = ProviderConfiguration(
            name: "AgentRouter",
            baseURL: URL(string: "https://agentrouter.org")!,
            model: "router-vision-model",
            apiKeyReference: "primary",
            providerID: ProviderCatalog.agentRouterID,
            protocolName: ProviderProtocol.openAIChat.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue,
            protocolNamesByKeyReference: ["primary": [ProviderProtocol.openAIChat.rawValue]]
        )

        let assessment = await router.imageCapability(configuration: configuration, apiKey: "unrecognized-test-key")

        XCTAssertEqual(assessment.capability, .supported)
        let recordedRequest = await recorder.lastCapabilityRequest()
        let snapshot = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(snapshot.configuration.baseURL.host, "co.agentrouter.org", "vision preflight must use the same preferred AgentRouter host as request routing")
        XCTAssertEqual(snapshot.configuration.protocolName, ProviderProtocol.openAIChat.rawValue)
        XCTAssertEqual(snapshot.configuration.model, configuration.model)
        XCTAssertEqual(snapshot.apiKey, "unrecognized-test-key")
    }

    func testProviderVisionCapabilityCacheIsExactKeyHostProtocolModel() async {
        let base = ProviderConfiguration(
            name: "vision-cache",
            baseURL: URL(string: "https://vision-cache.example/v1")!,
            model: "model-a-\(UUID().uuidString)",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.openAIChat.rawValue
        )
        await ProviderImageCompatibilityPolicy.mark(.textOnly, source: "test", configuration: base, apiKey: "key-a")
        let sameRoute = await ProviderImageCompatibilityPolicy.currentAssessment(configuration: base, apiKey: "key-a")
        XCTAssertEqual(sameRoute.capability, .textOnly)

        var differentHost = base
        differentHost.baseURL = URL(string: "https://vision-cache-alt.example/v1")!
        let hostAssessment = await ProviderImageCompatibilityPolicy.currentAssessment(configuration: differentHost, apiKey: "key-a")
        XCTAssertEqual(hostAssessment.capability, .unknown)

        var differentProtocol = base
        differentProtocol.protocolName = ProviderProtocol.anthropic.rawValue
        let protocolAssessment = await ProviderImageCompatibilityPolicy.currentAssessment(configuration: differentProtocol, apiKey: "key-a")
        XCTAssertEqual(protocolAssessment.capability, .unknown)

        var differentModel = base
        differentModel.model += "-other"
        let modelAssessment = await ProviderImageCompatibilityPolicy.currentAssessment(configuration: differentModel, apiKey: "key-a")
        let keyAssessment = await ProviderImageCompatibilityPolicy.currentAssessment(configuration: base, apiKey: "key-b")
        XCTAssertEqual(modelAssessment.capability, .unknown)
        XCTAssertEqual(keyAssessment.capability, .unknown)
    }

    func testAgentRouterLargeToolEnvelopeGetsOneBoundedCompatibilityRecovery() throws {
        XCTAssertTrue(ProviderCompatibilityClassifier.shouldRetryAgentRouterCompatibilityEnvelope(
            providerID: ProviderCatalog.agentRouterID,
            statusCode: 400,
            body: Data("{\"error\":{\"message\":\"bad request\"}}".utf8),
            messageCount: 67,
            toolCount: 64
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryAgentRouterCompatibilityEnvelope(
            providerID: "other-provider",
            statusCode: 400,
            body: Data("{\"error\":{\"message\":\"bad request\"}}".utf8),
            messageCount: 67,
            toolCount: 64
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryAgentRouterCompatibilityEnvelope(
            providerID: ProviderCatalog.agentRouterID,
            statusCode: 401,
            body: Data("{\"error\":{\"message\":\"invalid api key\"}}".utf8),
            messageCount: 67,
            toolCount: 64
        ))

        let names = ["apps.launch", "apps.list", "gui.screenshot", "gui.swipeSequence", "interaction.confirmTransition", "files.read", "sqlite.query"]
        let schemas = try names.map { internalName in
            ProviderToolSchema(name: try ProviderToolNameMap.encode(internalName), description: internalName)
        }
        let messages = [
            ChatMessage(role: .assistant, content: "", providerMetadata: ["tool_call_id": "call-1", "tool_name": "apps.launch", "tool_arguments": "{\"bundleId\":\"com.example.app\"}"]),
            ChatMessage(role: .tool, content: "accepted but foreground unverified", providerMetadata: ["tool_call_id": "call-1", "tool_name": "apps.launch"])
        ]
        let recovered = ProviderCompatibilityClassifier.recoveryToolSchemas(from: schemas, messages: messages)
        let recoveredInternal = try recovered.map { try ProviderToolNameMap.decode($0.name) }
        XCTAssertTrue(recoveredInternal.contains("apps.launch"))
        XCTAssertTrue(recoveredInternal.contains("gui.screenshot"))
        XCTAssertTrue(recoveredInternal.contains("gui.swipeSequence"))
        XCTAssertTrue(recoveredInternal.contains("interaction.confirmTransition"))
        XCTAssertFalse(recoveredInternal.contains("files.read"))
        XCTAssertFalse(recoveredInternal.contains("sqlite.query"))
    }

    func testProviderSafeUpstreamErrorDetailExtractsJSONAndSSEMessages() {
        XCTAssertEqual(
            ProviderCompatibilityClassifier.safeUpstreamErrorDetail(body: Data("{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"tool result history rejected\"}}".utf8)),
            "tool result history rejected"
        )
        XCTAssertEqual(
            ProviderCompatibilityClassifier.safeUpstreamErrorDetail(body: Data("data: {\"error\":{\"message\":\"content-blocked\"}}\n\n".utf8)),
            "content-blocked"
        )
    }

    func testReasoningEffortCompatibilityFallbackRequiresExplicitUnsupportedFieldEvidence() {
        XCTAssertTrue(ProviderCompatibilityClassifier.shouldRetryWithoutReasoningEffort(
            statusCode: 400,
            body: Data("{\"error\":\"unknown field output_config.effort\"}".utf8)
        ))
        XCTAssertTrue(ProviderCompatibilityClassifier.shouldRetryWithoutReasoningEffort(
            statusCode: 422,
            body: Data("{\"error\":\"unsupported reasoning_effort parameter\"}".utf8)
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryWithoutReasoningEffort(
            statusCode: 401,
            body: Data("{\"error\":\"unknown reasoning_effort\"}".utf8)
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryWithoutReasoningEffort(
            statusCode: 400,
            body: Data("{\"error\":\"model not found\"}".utf8)
        ))
    }

    func testGatewayRecoveryCompactsGeneric503ButNotExplicitQuotaOrCredentialFailures() {
        XCTAssertTrue(ProviderCompatibilityClassifier.shouldRetryWithCompactContext(
            statusCode: 503,
            body: Data("{\"error\":\"upstream overloaded\"}".utf8)
        ))
        XCTAssertTrue(ProviderCompatibilityClassifier.shouldRetryWithCompactContext(
            statusCode: 413,
            body: Data("{\"error\":\"request too large\"}".utf8)
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryWithCompactContext(
            statusCode: 503,
            body: Data("{\"error\":\"insufficient_user_quota\"}".utf8)
        ))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryWithCompactContext(
            statusCode: 503,
            body: Data("{\"error\":\"invalid api key\"}".utf8)
        ))
    }

    func testAnthropicGeneric503RetriesOnceWithCompactedContextBeforeNormalRetryBudget() async throws {
        ProviderGatewayRecoveryURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderGatewayRecoveryURLProtocol.self]
        let client = AnthropicProviderClient(
            session: URLSession(configuration: configuration),
            retryPolicy: RetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)
        )
        let provider = ProviderConfiguration(
            name: "gateway-recovery",
            baseURL: URL(string: "https://proxy.example/v1")!,
            model: "claude-test",
            apiKeyReference: "key",
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue
        )
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "safety")]
        for index in 0..<80 {
            messages.append(ChatMessage(role: .user, content: "old-\(index)-" + String(repeating: "x", count: 2_000)))
            messages.append(ChatMessage(role: .assistant, content: "answer-\(index)-" + String(repeating: "y", count: 2_000)))
        }
        messages.append(ChatMessage(role: .user, content: "latest-user-must-survive"))

        var events: [ProviderEvent] = []
        for try await event in client.stream(configuration: provider, apiKey: "secret", messages: messages, tools: []) {
            events.append(event)
        }
        XCTAssertEqual(events.last, .finished)
        let bodies = ProviderGatewayRecoveryURLProtocol.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertGreaterThan(bodies[0].count, bodies[1].count)
        let compactText = String(data: bodies[1], encoding: .utf8) ?? ""
        XCTAssertTrue(compactText.contains("latest-user-must-survive"))
    }

    func testHTTP503ModelNotFoundIsModelScopedAndUsesOnlyBoundedRouteFallbacks() {
        let body = Data("{\"error\":{\"code\":\"model_not_found\",\"message\":\"No available channel for model claude-opus-5 under group default\"}}".utf8)
        let error = ProviderHTTPClassifier.error(for: 503, body: body)
        XCTAssertEqual(error, .modelUnavailable(503))
        XCTAssertFalse(ProviderCompatibilityClassifier.shouldRetryWithCompactContext(statusCode: 503, body: body))
        XCTAssertFalse(ProviderRetryClassifier.isRetryableBeforeOutput(try! XCTUnwrap(error)))
        XCTAssertTrue(ProviderProtocolFallbackClassifier.shouldFallback(try! XCTUnwrap(error)))
        XCTAssertTrue(ProviderKeyRotationClassifier.shouldRotate(try! XCTUnwrap(error)))
        XCTAssertFalse(ProviderEndpointHealthClassifier.shouldMarkDegraded(try! XCTUnwrap(error)))
    }

    func testUnauthorizedClientErrorDoesNotInvalidateKeyProviderHealthOrTriggerProtocolFallback() {
        let body = Data("{\"error\":{\"type\":\"unauthorized_client_error\",\"message\":\"unauthorized client detected\"}}".utf8)
        let error = ProviderHTTPClassifier.error(for: 401, body: body)
        XCTAssertEqual(error, .clientRejected(401))
        XCTAssertFalse(ProviderRetryClassifier.isRetryableBeforeOutput(try! XCTUnwrap(error)))
        XCTAssertFalse(ProviderProtocolFallbackClassifier.shouldFallback(try! XCTUnwrap(error)))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(try! XCTUnwrap(error)))
        XCTAssertFalse(ProviderKeyRotationClassifier.shouldRotate(try! XCTUnwrap(error)))
        XCTAssertFalse(ProviderEndpointHealthClassifier.shouldMarkDegraded(try! XCTUnwrap(error)))
    }

    func testHTTP403QuotaIsCapacityNotCredentialFailure() {
        let body = Data("{\"error\":\"insufficient_user_quota\"}".utf8)
        let error = ProviderHTTPClassifier.error(for: 403, body: body)
        XCTAssertEqual(error, .capacityExhausted(403))
        XCTAssertFalse(ProviderHostFallbackClassifier.shouldFallback(try! XCTUnwrap(error)))
    }

    func testHTTP401CanTryAlternateSameProviderHostBeforeInvalidatingKey() {
        let error = try! XCTUnwrap(ProviderHTTPClassifier.error(for: 401, body: Data("{\"msg\":\"Invalid API Key!\"}".utf8)))
        XCTAssertEqual(error, .authenticationFailed(401))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(error))
        XCTAssertFalse(ProviderProtocolFallbackClassifier.shouldFallback(error))
    }

    func testHostFallbackClassificationCoversRouteLayersWithoutReplayingCapacity() {
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(ProviderError.authenticationFailed(403)))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(ProviderError.clientRejected(401)))
        XCTAssertFalse(ProviderHostFallbackClassifier.shouldFallback(ProviderError.invalidResponse(400)))
        XCTAssertTrue(ProviderProtocolFallbackClassifier.shouldFallback(ProviderError.invalidResponse(400)))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(ProviderError.invalidResponse(404)))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(ProviderError.invalidResponse(405)))
        XCTAssertFalse(ProviderHostFallbackClassifier.shouldFallback(ProviderError.invalidResponse(422)))
        XCTAssertTrue(ProviderProtocolFallbackClassifier.shouldFallback(ProviderError.invalidResponse(422)))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(ProviderError.invalidResponse(503)))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(ProviderError.protocolIncompatible("route mismatch")))
        XCTAssertTrue(ProviderHostFallbackClassifier.shouldFallback(URLError(.timedOut)))
        XCTAssertFalse(ProviderHostFallbackClassifier.shouldFallback(ProviderError.capacityExhausted(403)))
        XCTAssertFalse(ProviderHostFallbackClassifier.shouldFallback(ProviderError.rateLimited))
        XCTAssertFalse(ProviderHostFallbackClassifier.shouldFallback(ProviderError.streamInterrupted))
    }

    func testCompatibilityDriftDegradesOnlyExactProtocolOrAgentRouterAuthHostEvidence() {
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.protocolIncompatible("shape changed")))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.malformedEvent))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(400)))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(404)))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(422)))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.invalidResponse(503)))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.capacityExhausted(403)))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.rateLimited))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeProtocol(ProviderError.streamInterrupted))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeHost(ProviderError.authenticationFailed(401), providerID: ProviderCatalog.agentRouterID))
        XCTAssertTrue(ProviderCompatibilityDriftClassifier.shouldDegradeHost(ProviderError.clientRejected(403), providerID: ProviderCatalog.agentRouterID))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeHost(ProviderError.authenticationFailed(401), providerID: "other-provider"))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeHost(ProviderError.capacityExhausted(403), providerID: ProviderCatalog.agentRouterID))
        XCTAssertFalse(ProviderCompatibilityDriftClassifier.shouldDegradeHost(ProviderError.rateLimited, providerID: ProviderCatalog.agentRouterID))
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
            authModeName: ProviderAuthMode.bearer.rawValue
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

    func testSirthiswayAgentUsesFullCloudCodeToolSchemaExecutesToolAndContinuesAfterResult() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODE_SIRTHISWAY_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("sirthisway live smoke is enabled only in the dedicated GitHub Actions workflow")
        }
        guard let bootstrapText = ProcessInfo.processInfo.environment["CLOUDCODE_PROVIDER_BOOTSTRAP"],
              let bootstrapData = bootstrapText.data(using: .utf8) else {
            XCTFail("CLOUDCODE_PROVIDER_BOOTSTRAP is missing")
            return
        }
        let payload = try ProviderBootstrapPayload.decodeBootstrap(from: bootstrapData)
        let provider = try XCTUnwrap(payload.providers.first(where: { $0.providerID == "https-sirthisway-icu" }))
        let key = try XCTUnwrap(provider.keys.first?.secret)
        XCTAssertFalse(key.isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeSirthiswayLiveSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryKeyVault(keys: ["live-sirthisway": key])
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
            name: "sirthisway.icu",
            baseURL: URL(string: "https://sirthisway.icu")!,
            model: "claude-opus-5",
            apiKeyReference: "live-sirthisway",
            providerID: "https-sirthisway-icu",
            protocolName: ProviderProtocol.anthropic.rawValue,
            authModeName: ProviderAuthMode.bearer.rawValue
        )

        var capabilityToolCallCount = 0
        var sawSuccessfulToolResult = false
        var assistantText = ""
        let stream = await agent.send(
            text: "You must call the capability_probe tool exactly once before answering. Do not call any other tool. After receiving its tool result, reply exactly SIRTHISWAY_TOOL_ROUND_OK.",
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

        XCTAssertEqual(capabilityToolCallCount, 1, "sirthisway live model must execute capability_probe exactly once")
        XCTAssertTrue(sawSuccessfulToolResult, "sirthisway live tool result was not produced")
        XCTAssertTrue(assistantText.contains("SIRTHISWAY_TOOL_ROUND_OK"), "sirthisway live model did not continue after the tool result")
        let saved = try await sessions.load(session.id)
        XCTAssertTrue(saved.messages.contains { $0.role == .assistant && $0.content.contains("SIRTHISWAY_TOOL_ROUND_OK") })
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
        let liveKeyIndex = Int(ProcessInfo.processInfo.environment["CLOUDCODE_TABITOKEN_LIVE_KEY_INDEX"] ?? "") ?? 0
        XCTAssertTrue((1...tabitoken.keys.count).contains(liveKeyIndex), "workflow must pass the exact Tabitoken Key slot that completed live inference")
        let key = try XCTUnwrap(tabitoken.keys[liveKeyIndex - 1].secret)
        let liveModel = ProcessInfo.processInfo.environment["CLOUDCODE_TABITOKEN_LIVE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(key.isEmpty)
        XCTAssertFalse(liveModel.isEmpty, "CLOUDCODE_TABITOKEN_LIVE_MODEL must come from a real live inference validation")

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

private struct AlwaysFailureProvider: ProviderStreaming {
    let error: ProviderError
    func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

private actor RecordingHostOutcomeProvider: ProviderStreaming {
    private var seenHosts: [String] = []

    func hostsSeen() -> [String] { seenHosts }

    nonisolated func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let host = configuration.baseURL.host ?? ""
                await record(host)
                if host == "co.agentrouter.org" {
                    continuation.finish(throwing: ProviderError.authenticationFailed(401))
                } else if host == "agentrouter.org" {
                    continuation.yield(.token("legacy-host-good"))
                    continuation.yield(.finished)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProviderError.invalidEndpoint)
                }
            }
        }
    }

    private func record(_ host: String) {
        seenHosts.append(host)
    }
}

private actor RecordingHostProtocolOutcomeProvider: ProviderStreaming {
    private var seen: [String] = []
    private var legacyChatAttempts = 0
    private var coAnthropicAttempts = 0

    func routesSeen() -> [String] { seen }

    nonisolated func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let host = configuration.baseURL.host ?? ""
                let protocolName = configuration.protocolName ?? ""
                let route = "\(host)|\(protocolName)"
                let outcome = await recordAndResolve(host: host, protocolName: protocolName, route: route)
                switch outcome {
                case .success(let token):
                    continuation.yield(.token(token))
                    continuation.yield(.finished)
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private enum Outcome {
        case success(String)
        case failure(ProviderError)
    }

    private func recordAndResolve(host: String, protocolName: String, route: String) -> Outcome {
        seen.append(route)
        if host == "co.agentrouter.org", protocolName == ProviderProtocol.anthropic.rawValue {
            coAnthropicAttempts += 1
            return coAnthropicAttempts == 1
                ? .failure(.authenticationFailed(401))
                : .success("second-good")
        }
        if host == "agentrouter.org", protocolName == ProviderProtocol.anthropic.rawValue {
            return .failure(.protocolIncompatible("anthropic adapter mismatch"))
        }
        if host == "agentrouter.org", protocolName == ProviderProtocol.openAIChat.rawValue {
            legacyChatAttempts += 1
            return legacyChatAttempts == 1
                ? .success("first-good")
                : .failure(.authenticationFailed(401))
        }
        return .failure(.invalidEndpoint)
    }
}

private actor RecordingRateLimitedHostProvider: ProviderStreaming {
    private var seenHosts: [String] = []
    func hostsSeen() -> [String] { seenHosts }

    nonisolated func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(configuration.baseURL.host ?? "")
                continuation.finish(throwing: ProviderError.rateLimited)
            }
        }
    }

    private func record(_ host: String) { seenHosts.append(host) }
}

private actor RecordingPartialHostProvider: ProviderStreaming {
    private var seenHosts: [String] = []
    func hostsSeen() -> [String] { seenHosts }

    nonisolated func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(configuration.baseURL.host ?? "")
                continuation.yield(.token("partial"))
                continuation.finish(throwing: ProviderError.streamInterrupted)
            }
        }
    }

    private func record(_ host: String) { seenHosts.append(host) }
}

private struct KeyOutcomeProvider: ProviderStreaming {
    func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            switch apiKey {
            case "bad-auth": continuation.finish(throwing: ProviderError.authenticationFailed(401))
            case "no-quota": continuation.finish(throwing: ProviderError.capacityExhausted(403))
            case "rate-limit": continuation.finish(throwing: ProviderError.rateLimited)
            case "server-error": continuation.finish(throwing: ProviderError.invalidResponse(503))
            case "model-missing": continuation.finish(throwing: ProviderError.modelUnavailable(503))
            default:
                continuation.yield(.token("good"))
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }
}

private actor RecordingKeyProtocolOutcomeProvider: ProviderStreaming {
    private var seen: [String] = []

    func routesSeen() -> [String] { seen }

    nonisolated func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let protocolName = configuration.protocolName ?? ""
                await record("\(apiKey)|\(protocolName)")
                if apiKey == "fallback-key" && protocolName == ProviderProtocol.openAIChat.rawValue {
                    continuation.yield(.token("fallback-route-good"))
                    continuation.yield(.finished)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProviderError.modelUnavailable(503))
                }
            }
        }
    }

    private func record(_ route: String) {
        seen.append(route)
    }
}

private actor RecordingProtocolOutcomeProvider: ProviderStreaming {
    private var seen: [String] = []

    func protocolsSeen() -> [String] { seen }

    nonisolated func stream(configuration: ProviderConfiguration, apiKey: String, messages: [ChatMessage], tools: [ProviderToolSchema]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let protocolName = configuration.protocolName ?? ""
                await record(protocolName)
                if protocolName == ProviderProtocol.anthropic.rawValue {
                    continuation.finish(throwing: ProviderError.modelUnavailable(503))
                } else {
                    continuation.yield(.token("chat-good"))
                    continuation.yield(.finished)
                    continuation.finish()
                }
            }
        }
    }

    private func record(_ protocolName: String) {
        seen.append(protocolName)
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
            body = Data("{\"data\":[]}".utf8)
        } else if path == "/api/pricing" {
            status = 200
            body = Data("{\"data\":[],\"priced_models\":[\"model-a\"]}".utf8)
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

private final class ProviderEmptyDiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status: Int
        let body: Data
        if url.path.hasSuffix("/v1/models") || url.path == "/api/pricing" {
            status = 200
            body = Data(#"{"data":[],"success":true}"#.utf8)
        } else {
            status = 404
            body = Data(#"{"error":"unsupported"}"#.utf8)
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

private final class ProviderEmptyCatalogLiveInferenceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status: Int
        let body: Data
        if url.path.hasSuffix("/v1/models") || url.path == "/api/pricing" {
            status = 200
            body = Data(#"{"data":[],"success":true}"#.utf8)
        } else if url.path.hasSuffix("/v1/messages") {
            var rawRequestBody = request.httpBody
            if rawRequestBody == nil, let stream = request.httpBodyStream {
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
                rawRequestBody = data
            }
            let requestBody = rawRequestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let model = requestBody?["model"] as? String
            if model == "claude-opus-live",
               request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret",
               request.value(forHTTPHeaderField: "x-api-key") == "test-secret" {
                status = 200
                body = Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
            } else {
                status = 503
                body = Data(#"{"error":{"type":"model_not_found","message":"model unavailable"}}"#.utf8)
            }
        } else {
            status = 404
            body = Data(#"{"error":"unsupported"}"#.utf8)
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

private final class ProviderUnparseableCatalogLiveInferenceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status: Int
        let body: Data
        if url.path.hasSuffix("/v1/models") {
            status = 200
            body = Data(#"{"success":true,"result":{"rows":[]}}"#.utf8)
        } else if url.path.hasSuffix("/v1/messages"),
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret" {
            status = 200
            body = Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
        } else {
            status = 404
            body = Data(#"{"error":"unsupported"}"#.utf8)
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

private final class ProviderRatioDiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let hasBearer = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret"
        let hasXAPIKey = request.value(forHTTPHeaderField: "x-api-key") == "test-secret"
        let status: Int
        let body: Data
        if url.path.hasSuffix("/v1/models") || url.path == "/api/pricing" {
            status = 200
            body = Data(#"{"data":[],"success":true}"#.utf8)
        } else if url.path == "/api/ratio_config", hasBearer, !hasXAPIKey {
            status = 200
            body = Data(#"{"data":{"model_ratio":{"claude-opus-live":1},"model_price":{},"completion_ratio":{}},"success":true}"#.utf8)
        } else if url.path.hasSuffix("/v1/messages"), hasBearer, hasXAPIKey {
            status = 200
            body = Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
        } else {
            status = 404
            body = Data(#"{"error":"unsupported"}"#.utf8)
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

private final class ProviderPricingDiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let hasBearer = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret"
        let hasXAPIKey = request.value(forHTTPHeaderField: "x-api-key") == "test-secret"
        let status: Int
        let body: Data
        if url.path.hasSuffix("/v1/models") {
            status = 200
            body = Data(#"{"data":[],"object":"list","success":true}"#.utf8)
        } else if url.path == "/api/pricing" {
            status = 200
            body = Data(#"{"priced_model_details":{"claude-sonnet-live":{"input":1,"output":2}},"success":true}"#.utf8)
        } else if url.path.hasSuffix("/v1/messages"), hasBearer, hasXAPIKey {
            status = 200
            body = Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
        } else {
            status = 404
            body = Data(#"{"error":"unsupported"}"#.utf8)
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

private final class AgentRouterPendingReplayURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var capturedRequests: [URLRequest] = []

    static func reset() {
        lock.lock()
        capturedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let index = Self.capturedRequests.count
        Self.capturedRequests.append(request)
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = index == 0
            ? Data("data: {\"error\":{}}\n\n".utf8)
            : Data("data: {\"type\":\"message_stop\"}\n\n".utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProviderGatewayRecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var bodies: [Data] = []

    static func reset() {
        lock.lock()
        bodies = []
        lock.unlock()
    }

    static func requestBodies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
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
        let body = requestBody ?? Data()
        Self.lock.lock()
        let index = Self.bodies.count
        Self.bodies.append(body)
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status = index == 0 ? 503 : 200
        let responseBody = index == 0
            ? Data("{\"error\":\"upstream overloaded\"}".utf8)
            : Data("data: {\"type\":\"message_stop\"}\n\n".utf8)
        let headers = ["Content-Type": index == 0 ? "application/json" : "text/event-stream"]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
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
    private static var capturedRequestCount = 0

    static func install(status: Int, body: Data, headers: [String: String] = [:]) {
        lock.lock()
        responseStatus = status
        responseBody = body
        responseHeaders = headers
        capturedRequest = nil
        capturedBody = nil
        capturedRequestCount = 0
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

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequestCount
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
        Self.capturedRequestCount += 1
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

private actor ImageCapabilityRecordingProvider: ProviderStreaming {
    struct CapabilityRequest: Sendable {
        var configuration: ProviderConfiguration
        var apiKey: String
    }

    private let assessment: ProviderImageCapabilityAssessment
    private var lastRequest: CapabilityRequest?

    init(assessment: ProviderImageCapabilityAssessment) {
        self.assessment = assessment
    }

    func imageCapability(configuration: ProviderConfiguration, apiKey: String) async -> ProviderImageCapabilityAssessment {
        lastRequest = CapabilityRequest(configuration: configuration, apiKey: apiKey)
        return assessment
    }

    func lastCapabilityRequest() -> CapabilityRequest? {
        lastRequest
    }

    nonisolated func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}

private final class ProviderVisionCapabilityURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Equatable {
        case metadataSupported
        case tinyProbeTextOnly
        case tinyProbeUnknown
    }

    private static let lock = NSLock()
    private static var mode: Mode = .metadataSupported
    private static var capturedPaths: [String] = []
    private static var capturedBodies: [Data] = []

    static func install(mode: Mode) {
        lock.lock()
        self.mode = mode
        capturedPaths = []
        capturedBodies = []
        lock.unlock()
    }

    static func reset() {
        install(mode: .metadataSupported)
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedPaths.count
    }

    static func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPaths
    }

    static func bodies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
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
            body = data
        }

        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.capturedPaths.append(path)
        if let body { Self.capturedBodies.append(body) }
        let currentMode = Self.mode
        let requestIndex = Self.capturedPaths.count
        Self.lock.unlock()

        let status: Int
        let responseBody: Data
        let headers: [String: String]
        if path.hasSuffix("/models") {
            status = 200
            headers = ["Content-Type": "application/json"]
            switch currentMode {
            case .metadataSupported:
                responseBody = Data("{\"data\":[{\"id\":\"vision-model-metadata\",\"input_modalities\":[\"text\",\"image\"]}]}".utf8)
            case .tinyProbeTextOnly, .tinyProbeUnknown:
                responseBody = Data("{\"data\":[{\"id\":\"unrelated-model\"}]}".utf8)
            }
        } else if currentMode == .tinyProbeTextOnly && requestIndex == 2 {
            status = 400
            headers = ["Content-Type": "application/json"]
            responseBody = Data("{\"error\":{\"message\":\"image_url is unsupported; only text input is allowed\"}}".utf8)
        } else if currentMode == .tinyProbeUnknown && requestIndex == 2 {
            status = 200
            headers = ["Content-Type": "text/html"]
            responseBody = Data("<html><body>gateway front door</body></html>".utf8)
        } else {
            status = 200
            headers = ["Content-Type": "text/event-stream"]
            responseBody = Data("data: [DONE]\n\n".utf8)
        }

        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseBody.isEmpty { client?.urlProtocol(self, didLoad: responseBody) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
