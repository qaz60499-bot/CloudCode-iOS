import Foundation
import XCTest
@testable import CloudCodeCore

final class CustomProviderUpdatePolicyTests: XCTestCase {
    func testPrepareRetainsKeyFingerprintWhenEffectiveKeyIsUnavailableAndUpdatesWhenProvided() {
        let retained = CustomProviderUpdatePolicy.prepare(
            previous: profile(key: "retained-key"),
            label: "  Updated Gateway  ",
            baseURL: URL(string: "https://api.example.com/v1")!,
            manualModel: "manual-model",
            preferredProtocol: .anthropic,
            authMode: .bearer,
            effectiveKey: nil
        )

        XCTAssertEqual(retained.displayName, "Updated Gateway")
        XCTAssertEqual(retained.keySlots[0].fingerprint, ProviderFingerprint.sha256("retained-key"))
        XCTAssertEqual(retained.readiness, .needsValidation)
        XCTAssertTrue(retained.keySlots.allSatisfy { $0.status == .needsValidation })

        let updated = CustomProviderUpdatePolicy.prepare(
            previous: profile(key: "retained-key"),
            label: "Updated Gateway",
            baseURL: URL(string: "https://api.example.com/v1")!,
            manualModel: "manual-model",
            preferredProtocol: .anthropic,
            authMode: .bearer,
            effectiveKey: "new-key"
        )
        XCTAssertEqual(updated.keySlots[0].fingerprint, ProviderFingerprint.sha256("new-key"))
    }

    func testChangedEndpointClearsExactProtocolEvidenceAndKeepsVisibleModels() {
        let previous = profile(key: "retained-key")

        let updated = CustomProviderUpdatePolicy.prepare(
            previous: previous,
            label: previous.displayName,
            baseURL: URL(string: "https://new.example.com/v1")!,
            manualModel: "manual-model",
            preferredProtocol: .anthropic,
            authMode: .bearer,
            effectiveKey: "retained-key"
        )

        XCTAssertEqual(updated.models.first, "manual-model")
        XCTAssertTrue(updated.models.contains("prior-model"))
        XCTAssertTrue(updated.models.contains("second-only"))
        XCTAssertEqual(updated.keySlots[0].modelProtocols, ["manual-model": [.anthropic]])
        XCTAssertTrue(updated.keySlots[1].modelProtocols.isEmpty)
        XCTAssertEqual(updated.keySlots[1].models, previous.keySlots[1].models)
    }

    func testChangedKeyFingerprintClearsEvidenceForThatKeyButPreservesOtherKeyEvidence() {
        let updated = CustomProviderUpdatePolicy.prepare(
            previous: profile(key: "retained-key"),
            label: "Gateway",
            baseURL: URL(string: "https://api.example.com/v1")!,
            manualModel: "manual-model",
            preferredProtocol: .anthropic,
            authMode: .bearer,
            effectiveKey: "new-key"
        )

        XCTAssertEqual(updated.keySlots[0].modelProtocols, ["manual-model": [.anthropic]])
        XCTAssertEqual(updated.keySlots[1].modelProtocols, ["second-only": [.openAIResponses]])
        XCTAssertEqual(updated.keySlots[0].fingerprint, ProviderFingerprint.sha256("new-key"))
        XCTAssertTrue(updated.keySlots.allSatisfy { $0.status == .needsValidation })
    }

    func testChangedProtocolClearsExactEvidenceButKeepsTheVisibleCatalog() {
        let previous = profile(key: "retained-key")
        let updated = CustomProviderUpdatePolicy.prepare(
            previous: previous,
            label: previous.displayName,
            baseURL: previous.baseURL,
            manualModel: "manual-model",
            preferredProtocol: .openAIResponses,
            authMode: .bearer,
            effectiveKey: "retained-key"
        )

        XCTAssertEqual(updated.models.first, "manual-model")
        XCTAssertTrue(updated.models.contains("prior-model"))
        XCTAssertTrue(updated.models.contains("second-only"))
        XCTAssertEqual(updated.keySlots[0].modelProtocols, ["manual-model": [.openAIResponses]])
        XCTAssertTrue(updated.keySlots[1].modelProtocols.isEmpty)
    }

    func testKnownProviderEndpointIsNormalized() {
        let updated = CustomProviderUpdatePolicy.prepare(
            previous: profile(key: "retained-key"),
            label: "Cline",
            baseURL: URL(string: "https://app.cline.bot/custom/path")!,
            manualModel: "manual-model",
            preferredProtocol: .openAIResponses,
            authMode: .bearer,
            effectiveKey: "retained-key"
        )

        XCTAssertEqual(updated.baseURL.absoluteString, "https://api.cline.bot/api/v1")
    }

    func testOfficialGeminiNormalizesEndpointModelProtocolAuthAndEverySlot() {
        let previous = profile(key: "retained-key")
        let updated = CustomProviderUpdatePolicy.prepare(
            previous: previous,
            label: "Gemini",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash")!,
            manualModel: "models/gemini-3.8-flash",
            preferredProtocol: .anthropic,
            authMode: .bearer,
            effectiveKey: "retained-key"
        )

        XCTAssertEqual(updated.baseURL.absoluteString, "https://generativelanguage.googleapis.com/v1beta/")
        XCTAssertEqual(updated.protocols, [.openAIChat])
        XCTAssertEqual(updated.preferredProtocol, .openAIChat)
        XCTAssertEqual(updated.authMode, .xAPIKey)
        XCTAssertEqual(updated.models.first, "gemini-3.8-flash")
        XCTAssertTrue(updated.models.allSatisfy { !$0.hasPrefix("models/") })
        XCTAssertTrue(updated.keySlots.allSatisfy { $0.protocols == [.openAIChat] })
        XCTAssertEqual(updated.keySlots[0].modelProtocols["gemini-3.8-flash"], [.openAIChat])
        XCTAssertTrue(updated.keySlots[1].models.allSatisfy { !$0.hasPrefix("models/") })
        XCTAssertTrue(updated.keySlots[1].modelProtocols.isEmpty)
    }

    func testSelectionResolverKeepsSelectedNonFirstKeyAndItsModel() {
        let previous = profile(key: "retained-key")
        let updated = CustomProviderUpdatePolicy.prepare(
            previous: previous,
            label: previous.displayName,
            baseURL: previous.baseURL,
            manualModel: "manual-model",
            preferredProtocol: .anthropic,
            authMode: .bearer,
            effectiveKey: "retained-key"
        )
        let selection = ProviderSelectionState(providerID: previous.id, keySlotID: "slot-2", model: "second-only")

        XCTAssertEqual(ProviderSelectionResolver.reconcile(selection, profiles: [updated]), selection)
        XCTAssertEqual(updated.keySlots[0].models.first, "manual-model")
        XCTAssertEqual(updated.keySlots[1].models, previous.keySlots[1].models)
    }

    func testDiscoveryAppliesOnlyReadyNonemptyCatalog() {
        let prepared = CustomProviderUpdatePolicy.prepare(
            previous: profile(key: "retained-key"),
            label: "Gateway",
            baseURL: URL(string: "https://api.example.com/v1")!,
            manualModel: "manual-model",
            preferredProtocol: .anthropic,
            authMode: .bearer,
            effectiveKey: "retained-key"
        )

        var inconclusive = prepared
        inconclusive.applyDiscovery(
            ProviderDiscoveryResult(models: ["unverified-model"], protocols: [], authMode: .xAPIKey, readiness: .needsValidation),
            keySlotID: "slot-1"
        )
        XCTAssertEqual(inconclusive, prepared)

        var empty = prepared
        empty.applyDiscovery(
            ProviderDiscoveryResult(models: [], protocols: [], authMode: .bearer, readiness: .unavailable),
            keySlotID: "slot-1"
        )
        XCTAssertEqual(empty, prepared)

        var ready = prepared
        ready.applyDiscovery(
            ProviderDiscoveryResult(models: ["verified-model"], protocols: [.anthropic], authMode: .bearer, readiness: .ready),
            keySlotID: "slot-1"
        )
        XCTAssertEqual(ready.readiness, .ready)
        XCTAssertEqual(ready.keySlots[0].status, .verified)
        XCTAssertEqual(ready.keySlots[0].models, ["verified-model"])
    }

    func testProvisioningFinalizerFailureRestoresPreviouslyStoredKey() async throws {
        let vault = PolicyTestKeyVault(keys: ["provider.key": "old-key"])
        do {
            _ = try await ProviderKeyProvisioner.apply([
                ProviderKeyMutation(reference: "provider.key", secret: "new-key")
            ], vault: vault, finalizer: {
                throw ProviderError.transport("profile save failed")
            })
            XCTFail("A profile save failure must roll back the staged Keychain mutation")
        } catch {
            XCTAssertEqual(error as? ProviderError, .transport("profile save failed"))
        }
        XCTAssertEqual(vault.snapshot(), ["provider.key": "old-key"])
    }

    private func profile(key: String) -> ProviderProfile {
        ProviderProfile(
            id: "custom-gateway",
            displayName: "Gateway",
            baseURL: URL(string: "https://api.example.com/v1")!,
            protocols: [.anthropic, .openAIResponses],
            preferredProtocol: .anthropic,
            authMode: .bearer,
            models: ["prior-model", "second-only"],
            keySlots: [
                ProviderKeySlot(
                    id: "slot-1",
                    label: "Key 1",
                    fingerprint: ProviderFingerprint.sha256(key),
                    status: .verified,
                    models: ["prior-model", "first-only"],
                    protocols: [.anthropic],
                    modelProtocols: ["prior-model": [.anthropic]]
                ),
                ProviderKeySlot(
                    id: "slot-2",
                    label: "Key 2",
                    fingerprint: "second-fingerprint",
                    status: .authFailed,
                    models: ["second-only"],
                    protocols: [.openAIResponses],
                    modelProtocols: ["second-only": [.openAIResponses]]
                )
            ],
            source: .custom,
            customModelAllowed: true
        )
    }
}

private final class PolicyTestKeyVault: MutableAPIKeyVault, @unchecked Sendable {
    private var keys: [String: String]

    init(keys: [String: String] = [:]) {
        self.keys = keys
    }

    func set(_ value: String, for reference: String) throws {
        keys[reference] = value
    }

    func remove(_ reference: String) throws {
        keys.removeValue(forKey: reference)
    }

    func key(for reference: String) async throws -> String {
        guard let value = keys[reference] else { throw ProviderError.missingAPIKey }
        return value
    }

    func snapshot() -> [String: String] {
        keys
    }
}
