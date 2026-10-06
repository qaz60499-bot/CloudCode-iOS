import Foundation

/// Applies the local, unverified state for an edited custom provider profile.
public enum CustomProviderUpdatePolicy {
    public static func prepare(
        previous: ProviderProfile,
        label: String,
        baseURL: URL,
        manualModel: String,
        preferredProtocol: ProviderProtocol,
        authMode: ProviderAuthMode,
        effectiveKey: String?
    ) -> ProviderProfile {
        let normalizedURL = normalizedBaseURL(baseURL)
        let normalizedPreviousURL = normalizedBaseURL(previous.baseURL)
        let isGemini = ProviderEndpointPolicy.isOfficialGeminiAPI(normalizedURL)
        let selectedProtocol: ProviderProtocol = isGemini ? .openAIChat : preferredProtocol
        let selectedAuthMode: ProviderAuthMode = isGemini ? .xAPIKey : authMode
        let selectedModel = normalizedModel(manualModel, for: normalizedURL)

        var slots = previous.keySlots.map { normalize($0, for: normalizedURL) }
        if slots.isEmpty {
            slots = [ProviderKeySlot(
                id: "slot-1",
                label: "Key 1",
                fingerprint: "",
                protocols: [selectedProtocol]
            )]
        }

        var fingerprintChanged = false
        if let effectiveKey, !effectiveKey.isEmpty {
            let fingerprint = ProviderFingerprint.sha256(effectiveKey)
            fingerprintChanged = slots[0].fingerprint != fingerprint
            slots[0].fingerprint = fingerprint
        }

        let previousProtocol = ProviderEndpointPolicy.isOfficialGeminiAPI(normalizedPreviousURL)
            ? ProviderProtocol.openAIChat
            : previous.preferredProtocol
        let endpointChanged = normalizedPreviousURL != normalizedURL
        let protocolChanged = previousProtocol != selectedProtocol
        if endpointChanged || protocolChanged {
            for index in slots.indices {
                slots[index].modelProtocols = [:]
            }
        } else if fingerprintChanged {
            slots[0].modelProtocols = [:]
        }

        let priorModels = previous.models + previous.keySlots.flatMap(\.models)
        let models = unique(([selectedModel] + priorModels).map { normalizedModel($0, for: normalizedURL) })
        slots[0].models = unique([selectedModel] + slots[0].models)
        slots[0].protocols = [selectedProtocol]
        if !selectedModel.isEmpty {
            slots[0].modelProtocols[selectedModel] = [selectedProtocol]
        }

        if isGemini {
            for index in slots.indices {
                slots[index].protocols = [.openAIChat]
            }
        }
        for index in slots.indices {
            slots[index].status = .needsValidation
        }

        var updated = previous
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.displayName = trimmedLabel.isEmpty ? previous.displayName : trimmedLabel
        updated.baseURL = normalizedURL
        updated.protocols = [selectedProtocol]
        updated.preferredProtocol = selectedProtocol
        updated.authMode = selectedAuthMode
        updated.models = models
        updated.keySlots = slots
        updated.readiness = .needsValidation
        return updated
    }

    private static func normalizedBaseURL(_ url: URL) -> URL {
        let knownProviderURL = ProviderEndpointPolicy.normalizedKnownProviderBaseURL(url)
        guard ProviderEndpointPolicy.isOfficialGeminiAPI(knownProviderURL) else { return knownProviderURL }
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/")!
    }

    private static func normalizedModel(_ model: String, for url: URL) -> String {
        ProviderEndpointPolicy.normalizedModelID(model, for: url)
    }

    private static func normalize(_ slot: ProviderKeySlot, for url: URL) -> ProviderKeySlot {
        var normalized = slot
        normalized.models = unique(slot.models.map { normalizedModel($0, for: url) })
        var modelProtocols: [String: [ProviderProtocol]] = [:]
        for (model, protocols) in slot.modelProtocols {
            let key = normalizedModel(model, for: url)
            guard !key.isEmpty else { continue }
            modelProtocols[key] = uniqueProtocols((modelProtocols[key] ?? []) + protocols)
        }
        normalized.modelProtocols = modelProtocols
        return normalized
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func uniqueProtocols(_ values: [ProviderProtocol]) -> [ProviderProtocol] {
        var seen = Set<ProviderProtocol>()
        return values.filter { seen.insert($0).inserted }
    }
}
