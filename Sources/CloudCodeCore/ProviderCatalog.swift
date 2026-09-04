import Foundation
import CryptoKit

public enum ProviderProtocol: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openAIChat = "openai_chat"
    case openAIResponses = "openai_responses"
}

public enum ProviderAuthMode: String, Codable, Sendable {
    case bearer
    case xAPIKey = "x-api-key"
    case both
}

public enum ProviderReadiness: String, Codable, Sendable {
    case ready = "READY"
    case partial = "PARTIAL"
    case unavailable = "UNAVAILABLE"
    case authFailed = "AUTH_FAILED"
    case capacity = "CAPACITY"
    case needsValidation = "NEEDS_VALIDATION"
}

public enum ProviderEndpointHealthState: String, Codable, Sendable {
    case healthy
    case degraded
}

public struct ProviderEndpointHealth: Codable, Equatable, Sendable {
    public var state: ProviderEndpointHealthState
    public var updatedAt: Date
    public var errorDomain: String?
    public var errorCode: Int?

    public init(
        state: ProviderEndpointHealthState,
        updatedAt: Date = Date(),
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) {
        self.state = state
        self.updatedAt = updatedAt
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }
}

public enum ProviderEndpointHealthClassifier {
    public static func shouldMarkDegraded(_ error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .rateLimited:
                return true
            case .invalidResponse(let code):
                return (500...599).contains(code)
            case .streamInterrupted, .malformedEvent, .authenticationFailed:
                return true
            case .missingAPIKey, .invalidEndpoint, .capacityExhausted,
                 .attachmentUnavailable, .attachmentTooLarge,
                 .unsupportedAttachmentType, .transport:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotParseResponse, .timedOut, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }
}

public enum ProviderSource: String, Codable, Sendable {
    case desktopSnapshot = "desktop_snapshot"
    case builtIn = "built_in"
    case custom = "custom"
    case bootstrap = "bootstrap"
}

public enum ProviderKeyStatus: String, Codable, Sendable {
    case verified
    case unknown
    case unavailable
    case authFailed = "auth_failed"
    case capacity
    case needsValidation = "needs_validation"
}

public struct ProviderKeySlot: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var fingerprint: String
    public var status: ProviderKeyStatus
    public var models: [String]
    public var protocols: [ProviderProtocol]
    public var modelProtocols: [String: [ProviderProtocol]]

    public init(
        id: String,
        label: String,
        fingerprint: String,
        status: ProviderKeyStatus = .verified,
        models: [String] = [],
        protocols: [ProviderProtocol] = [],
        modelProtocols: [String: [ProviderProtocol]] = [:]
    ) {
        self.id = id
        self.label = label
        self.fingerprint = fingerprint
        self.status = status
        self.models = models
        self.protocols = protocols
        self.modelProtocols = modelProtocols
    }

    public var fingerprintPrefix: String {
        String(fingerprint.prefix(8))
    }
}

public struct ProviderProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var baseURL: URL
    public var enabled: Bool
    public var protocols: [ProviderProtocol]
    public var preferredProtocol: ProviderProtocol
    public var authMode: ProviderAuthMode
    public var models: [String]
    public var keySlots: [ProviderKeySlot]
    public var readiness: ProviderReadiness
    public var source: ProviderSource
    public var customModelAllowed: Bool
    public var autoRotateKeys: Bool

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        enabled: Bool = true,
        protocols: [ProviderProtocol],
        preferredProtocol: ProviderProtocol,
        authMode: ProviderAuthMode,
        models: [String],
        keySlots: [ProviderKeySlot],
        readiness: ProviderReadiness = .ready,
        source: ProviderSource,
        customModelAllowed: Bool,
        autoRotateKeys: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.enabled = enabled
        self.protocols = protocols
        self.preferredProtocol = preferredProtocol
        self.authMode = authMode
        self.models = Self.unique(models)
        self.keySlots = keySlots
        self.readiness = readiness
        self.source = source
        self.customModelAllowed = customModelAllowed
        self.autoRotateKeys = autoRotateKeys
    }

    public func models(for keySlotID: String?) -> [String] {
        guard let keySlotID,
              let slot = keySlots.first(where: { $0.id == keySlotID }) else {
            return models
        }
        if slot.status == .unavailable || slot.status == .authFailed {
            return []
        }
        return slot.models.isEmpty ? models : Self.unique(slot.models)
    }

    public func protocolFor(model: String, keySlotID: String?) -> ProviderProtocol {
        if let keySlotID,
           let slot = keySlots.first(where: { $0.id == keySlotID }) {
            if let verified = slot.modelProtocols[model], !verified.isEmpty {
                if verified.contains(preferredProtocol) { return preferredProtocol }
                return verified[0]
            }
            if !slot.protocols.isEmpty {
                if slot.protocols.contains(preferredProtocol) { return preferredProtocol }
                return slot.protocols[0]
            }
        }
        if protocols.contains(preferredProtocol) { return preferredProtocol }
        return protocols.first ?? preferredProtocol
    }

    public func orderedKeyReferences(selectedKeySlotID: String?) -> [String] {
        guard !keySlots.isEmpty else { return [] }
        let selectedIndex = selectedKeySlotID.flatMap { value in keySlots.firstIndex(where: { $0.id == value }) } ?? 0
        return (0..<keySlots.count).map { offset in
            let slot = keySlots[(selectedIndex + offset) % keySlots.count]
            return ProviderCatalog.keyReference(providerID: id, keySlotID: slot.id)
        }
    }

    public mutating func applyDiscovery(_ discovery: ProviderDiscoveryResult, keySlotID: String) {
        let discoveredModels = Self.unique(discovery.models)
        guard !discoveredModels.isEmpty || discovery.readiness == .unavailable else { return }
        guard let targetSlotIndex = keySlots.firstIndex(where: { $0.id == keySlotID }) else { return }

        authMode = discovery.authMode
        if discoveredModels.isEmpty, discovery.readiness == .unavailable {
            // An authenticated empty catalog is authoritative for the Key that produced it,
            // not for sibling credentials. Do not let one empty/limited Key erase the model
            // scope of every other configured Key before rotation has a chance to run.
            keySlots[targetSlotIndex].models = []
            keySlots[targetSlotIndex].status = .unavailable
            keySlots[targetSlotIndex].modelProtocols.removeAll()
            let aggregateModels = Self.unique(keySlots.flatMap { slot in
                (slot.status == .unavailable || slot.status == .authFailed) ? [] : slot.models
            })
            models = aggregateModels
            readiness = aggregateModels.isEmpty ? .unavailable : .partial
            return
        }

        let previousProviderModels = models
        models = discoveredModels
        readiness = discovery.readiness
        if !discovery.protocols.isEmpty {
            protocols = discovery.protocols
            if !protocols.contains(preferredProtocol), let first = protocols.first {
                preferredProtocol = first
            }
        }

        for slotIndex in keySlots.indices {
            let sharesProviderCatalog = keySlots[slotIndex].models == previousProviderModels
            guard keySlots[slotIndex].id == keySlotID || sharesProviderCatalog else { continue }
            keySlots[slotIndex].models = discoveredModels
            keySlots[slotIndex].status = Self.keyStatus(for: discovery.readiness)
            if !discovery.protocols.isEmpty {
                keySlots[slotIndex].protocols = discovery.protocols
            }
            keySlots[slotIndex].modelProtocols = keySlots[slotIndex].modelProtocols.filter { discoveredModels.contains($0.key) }
        }
    }

    private static func keyStatus(for readiness: ProviderReadiness) -> ProviderKeyStatus {
        switch readiness {
        case .ready:
            return .verified
        case .capacity:
            return .capacity
        case .authFailed:
            return .authFailed
        case .unavailable:
            return .unavailable
        case .partial, .needsValidation:
            return .needsValidation
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public struct ProviderSelectionState: Codable, Equatable, Sendable {
    public var providerID: String
    public var keySlotID: String
    public var model: String

    public init(providerID: String = "", keySlotID: String = "", model: String = "") {
        self.providerID = providerID
        self.keySlotID = keySlotID
        self.model = model
    }
}

public enum ProviderSelectionResolver {
    public static func reconcile(_ state: ProviderSelectionState, profiles: [ProviderProfile]) -> ProviderSelectionState {
        let available = profiles.filter { $0.enabled }
        guard let profile = available.first(where: { $0.id == state.providerID }) ?? available.first else {
            return ProviderSelectionState()
        }
        let requestedSlot = profile.keySlots.first(where: { $0.id == state.keySlotID }) ?? profile.keySlots.first
        let selectedSlot: ProviderKeySlot?
        if let requestedSlot, !profile.models(for: requestedSlot.id).isEmpty || profile.customModelAllowed {
            selectedSlot = requestedSlot
        } else {
            selectedSlot = profile.keySlots.first(where: { !profile.models(for: $0.id).isEmpty }) ?? requestedSlot
        }
        let models = profile.models(for: selectedSlot?.id)
        let selectedModel = models.contains(state.model) ? state.model : (models.first ?? (profile.customModelAllowed ? state.model : ""))
        return ProviderSelectionState(
            providerID: profile.id,
            keySlotID: selectedSlot?.id ?? "",
            model: selectedModel
        )
    }
}

public enum ProviderCheckpointConfigurationError: Error, Equatable, CustomStringConvertible {
    case missingProvider
    case providerUnavailable(String)
    case endpointMismatch
    case invalidKeyReference
    case invalidModel(String)
    case crossProviderFallback(String)

    public var description: String {
        switch self {
        case .missingProvider: return "Checkpoint is missing a Provider identity"
        case .providerUnavailable(let id): return "Checkpoint Provider is unavailable: \(id)"
        case .endpointMismatch: return "Checkpoint Provider endpoint does not match the current Provider catalog"
        case .invalidKeyReference: return "Checkpoint Key reference is not owned by the checkpoint Provider"
        case .invalidModel(let model): return "Checkpoint model is not valid for the checkpoint Provider/Key: \(model)"
        case .crossProviderFallback(let reference): return "Checkpoint fallback Key reference is outside the checkpoint Provider: \(reference)"
        }
    }
}

public enum ProviderCheckpointConfigurationResolver {
    public static func resolve(payload: [String: String], profiles: [ProviderProfile]) throws -> ProviderConfiguration {
        guard let providerID = payload["provider.id"], !providerID.isEmpty else {
            throw ProviderCheckpointConfigurationError.missingProvider
        }
        guard let profile = profiles.first(where: { $0.id == providerID && $0.enabled }) else {
            throw ProviderCheckpointConfigurationError.providerUnavailable(providerID)
        }
        if let storedURL = payload["provider.baseURL"], !storedURL.isEmpty,
           !checkpointEndpointMatches(storedURL, profile: profile) {
            throw ProviderCheckpointConfigurationError.endpointMismatch
        }
        guard let primaryReference = payload["provider.keyReference"], !primaryReference.isEmpty,
              let slot = profile.keySlots.first(where: {
                  ProviderCatalog.keyReference(providerID: profile.id, keySlotID: $0.id) == primaryReference
              }) else {
            throw ProviderCheckpointConfigurationError.invalidKeyReference
        }
        let model = payload["provider.model"] ?? ""
        let allowedModels = profile.models(for: slot.id)
        guard !model.isEmpty, allowedModels.contains(model) || profile.customModelAllowed else {
            throw ProviderCheckpointConfigurationError.invalidModel(model)
        }
        let providerReferences = Set(profile.keySlots.map {
            ProviderCatalog.keyReference(providerID: profile.id, keySlotID: $0.id)
        })
        let storedFallbacks = (payload["provider.fallbackKeyReferences"] ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
        for reference in storedFallbacks where !providerReferences.contains(reference) {
            throw ProviderCheckpointConfigurationError.crossProviderFallback(reference)
        }
        let ordered = profile.orderedKeyReferences(selectedKeySlotID: slot.id)
        let allowedFallbacks = storedFallbacks.filter { $0 != primaryReference && ordered.contains($0) }
        let allowFailover = profile.autoRotateKeys && payload["provider.sameProviderFailover"] == "true"
        return ProviderConfiguration(
            name: profile.displayName,
            baseURL: profile.baseURL,
            model: model,
            apiKeyReference: primaryReference,
            providerID: profile.id,
            protocolName: profile.protocolFor(model: model, keySlotID: slot.id).rawValue,
            authModeName: profile.authMode.rawValue,
            fallbackAPIKeyReferences: allowFailover ? allowedFallbacks : [],
            allowSameProviderKeyFailover: allowFailover
        )
    }

    private static func checkpointEndpointMatches(_ storedURL: String, profile: ProviderProfile) -> Bool {
        if storedURL == profile.baseURL.absoluteString { return true }
        // AgentRouter moved its documented API origin from agentrouter.org to
        // co.agentrouter.org. Old checkpoints may resume only through this explicit,
        // provider-scoped migration; arbitrary endpoint changes remain rejected.
        return profile.id == "https-agentrouter-org"
            && storedURL == "https://agentrouter.org"
            && profile.baseURL.absoluteString == "https://co.agentrouter.org"
    }
}

public enum ProviderFingerprint {
    public static func sha256(_ secret: String) -> String {
        sha256(Data(secret.utf8))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProviderBootstrapPayload: Codable, Equatable, Sendable {
    public struct ProviderKeys: Codable, Equatable, Sendable {
        public var providerID: String
        public var keys: [Key]

        public init(providerID: String, keys: [Key]) {
            self.providerID = providerID
            self.keys = keys
        }
    }

    public struct Key: Codable, Equatable, Sendable {
        public var slotID: String
        public var label: String
        public var secret: String
        public var fingerprint: String?

        public init(slotID: String, label: String, secret: String, fingerprint: String? = nil) {
            self.slotID = slotID
            self.label = label
            self.secret = secret
            self.fingerprint = fingerprint
        }
    }

    public var schemaVersion: Int
    public var generatedAt: Date
    public var providers: [ProviderKeys]

    public init(schemaVersion: Int = 1, generatedAt: Date = Date(), providers: [ProviderKeys]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.providers = providers
    }

    public static func decodeBootstrap(from data: Data) throws -> ProviderBootstrapPayload {
        struct WirePayload: Decodable {
            var schemaVersion: Int
            var generatedAt: String?
            var providers: [ProviderKeys]
        }

        let wire = try JSONDecoder().decode(WirePayload.self, from: data)
        let generatedAt = wire.generatedAt.flatMap(parseBootstrapDate) ?? Date(timeIntervalSince1970: 0)
        return ProviderBootstrapPayload(schemaVersion: wire.schemaVersion, generatedAt: generatedAt, providers: wire.providers)
    }

    /// Stable across rebuild timestamps. Only actual provider/key material and schema identity
    /// participate so regenerating the same private bootstrap does not look like a key rotation.
    public var stableContentFingerprint: String {
        var canonical = "schema=\(schemaVersion)\n"
        for provider in providers.sorted(by: { $0.providerID < $1.providerID }) {
            canonical += "provider=\(provider.providerID)\n"
            for key in provider.keys.sorted(by: { $0.slotID < $1.slotID }) {
                canonical += "slot=\(key.slotID)\n"
                canonical += "secret=\(ProviderFingerprint.sha256(key.secret))\n"
            }
        }
        return ProviderFingerprint.sha256(canonical)
    }

    private static func parseBootstrapDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

public enum ProviderCatalog {
    public static let tabitokenID = "tabitoken"

    public static func keyReference(providerID: String, keySlotID: String) -> String {
        "provider.\(providerID).key.\(keySlotID)"
    }

    public static let desktopSnapshot: [ProviderProfile] = {
        let tabitokenModels = [
            "claude-opus-5",
            "claude-opus-5-thinking",
            "claude-opus-4-8",
            "claude-opus-4-8-thinking"
        ]
        let tabitokenFingerprints = [
            "3c792c35105403233657638fa1cbd6f21729180aae1688ef0a33997cac38fc0c",
            "9a8614e9d8d67657747f7d4021165faeaae95233002b58fee4896b375df96a03",
            "143102ddc4e230c63b4cf067cef1eebfbbd30c48a800a1cb23a134b2bcb049a8",
            "9a283d3b577ab04670e8a62553a24d5da3d47bd999b6a0851146cdcd2c0de359",
            "9f5a1119daea8610a0e17ac8a23eb76b4d9ad6ca3292507dd1199eaa7d7ff4b7"
        ]
        let tabitokenSlots = tabitokenFingerprints.enumerated().map { index, fingerprint in
            ProviderKeySlot(
                id: "slot-\(index + 1)",
                label: "Key \(index + 1)",
                fingerprint: fingerprint,
                models: tabitokenModels,
                protocols: [.anthropic]
            )
        }

        let gorouterModels = ["claude-opus-5-thinking", "claude-opus-4-8", "claude-opus-4-8-thinking", "claude-opus-5"]
        let gorouterFingerprints = [
            "f86fb13ce3a8faf2f3818173d6f3b3f9c96ec24ee9b30f799ff79ccc68ba07ff",
            "46767b9792d0cc85290500a9ba5957e88e36071daf4c2a28e55e37a39438a586",
            "de313dfdeee5f931966248c1ceb766f7c84a8f647afe0e5eacad43e2f023dbd5",
            "2cf8e64fbd0111b07706ae8c3ccc77e474ca66bbe155c87e5bef1265d2806ace",
            "bf07bf7dfe7416b22dac7bfd5eecdd92f4f4784973d62ccb801b422088427133"
        ]
        let gorouterSlots = gorouterFingerprints.enumerated().map { index, fingerprint in
            ProviderKeySlot(
                id: "slot-\(index + 1)",
                label: "Key \(index + 1)",
                fingerprint: fingerprint,
                models: gorouterModels,
                protocols: [.anthropic, .openAIChat],
                modelProtocols: index == 0 ? [:] : [
                    "claude-opus-5": [.anthropic, .openAIChat],
                    "claude-opus-4-8": index == 2 ? [.anthropic, .openAIChat] : [.anthropic],
                    "claude-opus-5-thinking": index == 2 ? [.anthropic] : []
                ]
            )
        }

        let shareLLMModels = [
            "kimi-k3", "gpt-5.6-luna", "glm-5.2", "glm-5", "qwen3.8-27b", "agnes-2.5-flash",
            "minimax-m3", "kimi-k2.6", "deepseek-v4-flash-0731", "kimi-k2.5", "grok-4.5",
            "deepseek-v4-pro", "grok-4.6", "Ox Alpha", "deepseek-v4-flash", "deepseek-v4-flash-vision",
            "dots3-note", "gpt-5.6-terra", "hy3", "laguna–s-2.1", "minimax-m2.5", "minimax-m2.7",
            "minimax-m2.7-highspeed", "nemotron-3-ultra", "nemotron-3.5-lightning", "qwen3.7-plus",
            "sensenova-6.8-flash-lite", "sensenova-u1-fast", "step-3.7-flash", "claude-opus-5",
            "qwen3.8-max", "claude-opus-4-8", "LongCat-2.0", "claude-opus-4-6", "gpt-5.6-sol",
            "claude-fable-5", "gemini-3.7-flash", "gpt-5.5", "gemini-3.6-flash", "MiniMax-M3",
            "MiniMax/MiniMax-M3", "Qwen/Qwen3.8-27B", "Tencent-Hunyuan/Hy3", "ZhipuAI/GLM-5.2",
            "claude-opus-5-thinking", "claude-sonnet-4-6", "codex-auto-review", "deepseek-ai/DeepSeek-V4-Pro",
            "deepseek-ai/DeepSeek-V4-Pro-0813", "deepseek-ai/deepseek-v4-flash-0731", "deepseek-v4-flash-free",
            "deepseek-v4-flash-ga-260731", "deepseek-v4-flash-vision-exp", "deepseek/deepseek-v4-flash",
            "deepseek/deepseek-v4-pro", "dots-3-note", "dots-studio/dots-3-note-preview:free", "dots3-note-prev",
            "gemini-3.1-pro-preview", "glm-5.2-free", "glm-5.3", "gpt-5.4-mini", "gpt-image-2", "hy3-free",
            "laguna-s-2.1-free", "mimo-v2.5", "mimo-v2.5-pro", "minimax/minimax-m2.7",
            "minimax/minimax-m2.7-highspeed", "minimaxai/minimax-m3", "moonshotai/kimi-k2.6",
            "moonshotai/kimi-k3", "nemotron-3-ultra-free", "nemotron-3.5-lightning-free",
            "openai/gpt-5.6-luna", "openai/gpt-5.6-terra", "ox-alpha", "qwen/qwen3.7-max",
            "qwen/qwen3.7-plus", "qwen/qwen3.8-max", "qwen3.6-plus", "qwen3.7-max", "stealth/ox-alpha",
            "step-router-v1", "stepfun-ai/step-3.7-flash", "z-ai/glm-5.2"
        ]
        let shareLLMKey1Models = [
            "kimi-k3", "gpt-5.6-luna", "glm-5.2", "glm-5", "qwen3.8-27b", "agnes-2.5-flash",
            "minimax-m3", "kimi-k2.6", "deepseek-v4-flash-0731", "kimi-k2.5", "grok-4.5",
            "deepseek-v4-pro", "grok-4.6", "Ox Alpha", "deepseek-v4-flash", "deepseek-v4-flash-vision",
            "dots3-note", "gpt-5.6-terra", "hy3", "laguna–s-2.1", "minimax-m2.5", "minimax-m2.7",
            "minimax-m2.7-highspeed", "nemotron-3-ultra", "nemotron-3.5-lightning", "qwen3.7-plus",
            "sensenova-6.8-flash-lite", "sensenova-u1-fast", "step-3.7-flash"
        ]

        let sirModels = [
            "claude-fable-5", "claude-opus-4-5-20251101", "claude-opus-4-6", "claude-opus-4-7",
            "claude-opus-4-8", "claude-opus-5", "claude-sonnet-5", "claude-sonnet-4-6",
            "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001"
        ]
        let sirFingerprints = [
            "5518d67ffe8f53384a024ed6694276491718bae9e471d007b3196141f09af254",
            "45e186f221e7513eadea431756ea81543f3b54857b8a2aa34508fdc9fd0c4362",
            "5e501665dc1ae5b54751f3d7d23f42b66275fd5dc4068e3fa54b65731267cf92",
            "c7201d5e6e956e2f3520a24e97b296fc31f5111fe80f19595d68c2c75c2219e6",
            "63a730506d6a9418037352bb874c6df7f652159e188e286b6eeadad00afd34a9"
        ]
        let sirSlots = sirFingerprints.enumerated().map { index, fingerprint in
            ProviderKeySlot(
                id: "slot-\(index + 1)",
                label: "Key \(index + 1)",
                fingerprint: fingerprint,
                models: sirModels,
                protocols: [.anthropic, .openAIResponses, .openAIChat]
            )
        }

        return [
            ProviderProfile(
                id: tabitokenID,
                displayName: "Tabitoken",
                baseURL: URL(string: "https://tabitoken.com")!,
                protocols: [.anthropic],
                preferredProtocol: .anthropic,
                authMode: .both,
                models: tabitokenModels,
                keySlots: tabitokenSlots,
                source: .builtIn,
                customModelAllowed: false,
                autoRotateKeys: true
            ),
            ProviderProfile(
                id: "https-ai-fsykk-cn",
                displayName: "ai.fsykk.cn",
                baseURL: URL(string: "https://ai.fsykk.cn")!,
                protocols: [.anthropic],
                preferredProtocol: .anthropic,
                authMode: .bearer,
                models: ["deepseek-v4-flash", "deepseek-v4-pro", "gemini-3.1-pro", "gemini-3.5-flash", "glm-5", "glm-5.1", "glm-5.2", "kimi-k2.6", "kimi-k3", "step-3.7-flash"],
                keySlots: [ProviderKeySlot(id: "slot-1", label: "Key 1", fingerprint: "9cbadbcbf3a8afdb2ac50501239f8cf47bc9e86b64c127fcc7c1b2f81c8a1975", models: ["deepseek-v4-flash", "deepseek-v4-pro", "gemini-3.1-pro", "gemini-3.5-flash", "glm-5", "glm-5.1", "glm-5.2", "kimi-k2.6", "kimi-k3", "step-3.7-flash"], protocols: [.anthropic])],
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "ccs-7bdd07431575",
                displayName: "gorouter.app",
                baseURL: URL(string: "https://gorouter.app")!,
                protocols: [.anthropic, .openAIChat],
                preferredProtocol: .anthropic,
                authMode: .bearer,
                models: gorouterModels,
                keySlots: gorouterSlots,
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "https-api-denxio-top",
                displayName: "api.denxio.top",
                baseURL: URL(string: "https://api.denxio.top")!,
                protocols: [.anthropic],
                preferredProtocol: .anthropic,
                authMode: .bearer,
                models: ["grok-4.5", "grok-imagine-video-1.5", "grok-4.6", "grok-imagine-image-2.0"],
                keySlots: [ProviderKeySlot(id: "slot-1", label: "Key 1", fingerprint: "a913ab95cdfb29203c2725184a9e9db2359b3d5af01d0d0fecebb259a16f30a3", models: ["grok-4.5", "grok-imagine-video-1.5", "grok-4.6", "grok-imagine-image-2.0"], protocols: [.anthropic], modelProtocols: ["grok-4.6": [.anthropic]])],
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "https-api-justwoker-icu",
                displayName: "api.justwoker.icu",
                baseURL: URL(string: "https://api.justwoker.icu")!,
                protocols: [.anthropic, .openAIChat],
                preferredProtocol: .anthropic,
                authMode: .both,
                models: ["claude-opus-5", "claude-opus-5-thinking"],
                keySlots: [ProviderKeySlot(id: "slot-1", label: "Key 1", fingerprint: "4b311d96d45555d663e567e0e82b8cddc46d90f02a834ea81a78ed716e690184", models: ["claude-opus-5", "claude-opus-5-thinking"], protocols: [.anthropic, .openAIChat], modelProtocols: ["claude-opus-5": [.anthropic], "claude-opus-5-thinking": [.anthropic]])],
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "https-sharellm-cn",
                displayName: "sharellm.cn",
                baseURL: URL(string: "https://sharellm.cn")!,
                protocols: [.anthropic, .openAIResponses, .openAIChat],
                preferredProtocol: .anthropic,
                authMode: .bearer,
                models: shareLLMModels,
                keySlots: [
                    ProviderKeySlot(id: "slot-1", label: "Key 1", fingerprint: "f831d2be52423f32eab43109869d0acac38a49814bbb0669cd49b57bfea444eb", models: shareLLMKey1Models, protocols: [.anthropic, .openAIResponses, .openAIChat]),
                    ProviderKeySlot(id: "slot-2", label: "Key 2", fingerprint: "1290d3f87fe1b12bdc3155496d93f6a9ffbc28dd5d622b7c628938e209b0b602", models: shareLLMModels, protocols: [.anthropic, .openAIResponses])
                ],
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "https-agentrouter-org",
                displayName: "agentrouter.org",
                baseURL: URL(string: "https://co.agentrouter.org")!,
                protocols: [.anthropic, .openAIChat],
                preferredProtocol: .anthropic,
                authMode: .bearer,
                models: ["claude-opus-4-8", "claude-opus-5", "deepseek-v4-flash", "gpt-5.6-sol"],
                keySlots: [ProviderKeySlot(
                    id: "slot-1",
                    label: "Key 1",
                    fingerprint: "105a3fce9a105c41472b926f6448a91be2f9726d5e074adbaaa2206f4d6dbf23",
                    models: ["claude-opus-4-8", "claude-opus-5", "deepseek-v4-flash", "gpt-5.6-sol"],
                    protocols: [.anthropic, .openAIChat],
                    modelProtocols: [
                        "claude-opus-4-8": [.anthropic],
                        "claude-opus-5": [.anthropic],
                        "deepseek-v4-flash": [.openAIChat],
                        "gpt-5.6-sol": [.openAIChat]
                    ]
                )],
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "https-sirthisway-icu",
                displayName: "sirthisway.icu",
                baseURL: URL(string: "https://sirthisway.icu")!,
                protocols: [.anthropic, .openAIResponses, .openAIChat],
                preferredProtocol: .anthropic,
                authMode: .bearer,
                models: sirModels,
                keySlots: sirSlots,
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "https-vyceai-com",
                displayName: "vyceai.com",
                baseURL: URL(string: "https://vyceai.com")!,
                protocols: [.anthropic, .openAIResponses, .openAIChat],
                preferredProtocol: .openAIResponses,
                authMode: .bearer,
                models: ["claude-sonnet-4-6", "gpt-5.6-luna", "gpt-5.6-new", "gpt-5.6-luna-testing", "deepseek-v4-flash", "deepseek-v4-flash-lr", "nemotron-ultra-550b", "nemotron-vision", "grok-imagine-2", "grok-imagine"],
                keySlots: [ProviderKeySlot(id: "slot-1", label: "Key 1", fingerprint: "f79abeb673144d33c472a21cf54b39cb1bd0c34be0b56a1f645ac84c9a2d2078", models: ["claude-sonnet-4-6", "gpt-5.6-luna", "gpt-5.6-new", "gpt-5.6-luna-testing", "deepseek-v4-flash", "deepseek-v4-flash-lr", "nemotron-ultra-550b", "nemotron-vision", "grok-imagine-2", "grok-imagine"], protocols: [.anthropic, .openAIResponses, .openAIChat], modelProtocols: ["claude-sonnet-4-6": [.openAIResponses]])],
                source: .desktopSnapshot,
                customModelAllowed: true
            ),
            ProviderProfile(
                id: "https-free-supxh-xin",
                displayName: "free.supxh.xin",
                baseURL: URL(string: "https://free.supxh.xin")!,
                protocols: [.anthropic, .openAIResponses, .openAIChat],
                preferredProtocol: .anthropic,
                authMode: .bearer,
                models: ["gemini-3.1-pro", "claude-sonnet-4-5", "claude-opus-4-5", "入梦 Flash", "gemini-3-flash", "gemini-2.5-pro"],
                keySlots: [ProviderKeySlot(id: "slot-1", label: "Key 1", fingerprint: "d02869497356e521250db84b252e7822dff6732cf1672654ddeb8770cfb2c4fd", models: ["gemini-3.1-pro", "claude-sonnet-4-5", "claude-opus-4-5", "入梦 Flash", "gemini-3-flash", "gemini-2.5-pro"], protocols: [.anthropic, .openAIResponses, .openAIChat], modelProtocols: ["入梦 Flash": [.anthropic]])],
                source: .desktopSnapshot,
                customModelAllowed: true
            )
        ]
    }()
}
