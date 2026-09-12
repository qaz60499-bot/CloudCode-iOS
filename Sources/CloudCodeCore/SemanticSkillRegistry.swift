import Foundation

/// Semantic skills are reusable planning knowledge only. They never execute a tool directly and
/// never bypass ToolRouter, CapabilityProfile, PolicyEngine, confirmations, or fresh observation.
public struct SemanticSkillTransition: Codable, Hashable, Sendable {
    public var fromSurface: String
    public var toSurface: String
    public var semanticAction: String

    public init(fromSurface: String, toSurface: String, semanticAction: String) {
        self.fromSurface = fromSurface
        self.toSurface = toSurface
        self.semanticAction = semanticAction
    }
}

public struct SemanticSkillDefinition: Codable, Hashable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case predefined
        case explicitlyValidated
    }

    public var id: String
    public var semanticGoal: String
    public var bundleID: String?
    public var requiredSemanticSurface: String
    public var requiredCapabilities: [String]
    public var landmarks: [String]
    public var transitions: [SemanticSkillTransition]
    public var verificationObligations: [String]
    public var allowedLocalRecovery: [String]
    public var environment: AppActionEnvironment
    public var evidenceCount: Int
    public var reliability: Double
    public var lastValidatedAt: Date?
    public var lastFailureAt: Date?
    public var exactlyOnce: Bool
    public var origin: Origin

    public init(
        id: String,
        semanticGoal: String,
        bundleID: String? = nil,
        requiredSemanticSurface: String,
        requiredCapabilities: [String],
        landmarks: [String] = [],
        transitions: [SemanticSkillTransition],
        verificationObligations: [String],
        allowedLocalRecovery: [String] = [],
        environment: AppActionEnvironment = AppActionEnvironment(),
        evidenceCount: Int = 0,
        reliability: Double = 0.5,
        lastValidatedAt: Date? = nil,
        lastFailureAt: Date? = nil,
        exactlyOnce: Bool = false,
        origin: Origin = .predefined
    ) {
        self.id = String(id.prefix(128))
        self.semanticGoal = String(semanticGoal.prefix(128))
        self.bundleID = bundleID.map { String($0.prefix(255)) }
        self.requiredSemanticSurface = String(requiredSemanticSurface.prefix(128))
        self.requiredCapabilities = Array(requiredCapabilities.map { String($0.prefix(128)) }.prefix(16))
        self.landmarks = Array(landmarks.map { String($0.prefix(128)) }.prefix(24))
        self.transitions = Array(transitions.prefix(12))
        self.verificationObligations = Array(verificationObligations.map { String($0.prefix(128)) }.prefix(12))
        self.allowedLocalRecovery = Array(allowedLocalRecovery.map { String($0.prefix(128)) }.prefix(12))
        self.environment = environment
        self.evidenceCount = max(0, evidenceCount)
        self.reliability = min(max(reliability, 0), 1)
        self.lastValidatedAt = lastValidatedAt
        self.lastFailureAt = lastFailureAt
        self.exactlyOnce = exactlyOnce
        self.origin = origin
    }
}

public struct SemanticSkillCandidate: Sendable, Equatable {
    public var skill: SemanticSkillDefinition
    public var requiresRevalidation: Bool

    public init(skill: SemanticSkillDefinition, requiresRevalidation: Bool) {
        self.skill = skill
        self.requiresRevalidation = requiresRevalidation
    }
}

public enum SemanticSkillRegistryError: Error, Equatable, Sendable {
    case invalidSkill
    case unknownSkill(String)
    case cacheTooLarge
}

public enum SemanticSkillCatalog {
    /// Deliberately small generic primitives. They are planning templates until explicitly
    /// validated with repeated evidence for a concrete environment.
    public static let predefined: [SemanticSkillDefinition] = [
        SemanticSkillDefinition(
            id: "skill.chat.focus.composer",
            semanticGoal: "focus_text_composer",
            requiredSemanticSurface: "chat.conversation",
            requiredCapabilities: [GUIAutomationFeature.screenshot.capabilityID, GUIAutomationFeature.touch.capabilityID],
            landmarks: ["composer"],
            transitions: [.init(fromSurface: "chat.conversation", toSurface: "chat.composer", semanticAction: "focus_composer")],
            verificationObligations: ["composer_focus_verified"],
            allowedLocalRecovery: ["fresh_observation", "single_refocus_attempt"]
        ),
        SemanticSkillDefinition(
            id: "skill.chat.enter.body.once",
            semanticGoal: "enter_requested_text_once",
            requiredSemanticSurface: "chat.composer",
            requiredCapabilities: [GUIAutomationFeature.textInput.capabilityID, GUIAutomationFeature.screenshot.capabilityID],
            landmarks: ["focused_composer"],
            transitions: [.init(fromSurface: "chat.composer", toSurface: "chat.composer", semanticAction: "enter_message_body")],
            verificationObligations: ["message_body_entered_once"],
            allowedLocalRecovery: ["fresh_observation"],
            exactlyOnce: true
        ),
        SemanticSkillDefinition(
            id: "skill.chat.commit.send.once",
            semanticGoal: "commit_message_once",
            requiredSemanticSurface: "chat.composer",
            requiredCapabilities: [GUIAutomationFeature.touch.capabilityID, GUIAutomationFeature.screenshot.capabilityID],
            landmarks: ["send_control"],
            transitions: [.init(fromSurface: "chat.composer", toSurface: "chat.conversation", semanticAction: "commit_send")],
            verificationObligations: ["message_commit_verified", "postcondition_verified"],
            allowedLocalRecovery: ["reconcile_before_retry"],
            exactlyOnce: true
        ),
        SemanticSkillDefinition(
            id: "skill.feed.collect.metric",
            semanticGoal: "collect_bounded_items",
            requiredSemanticSurface: "fullscreenMedia",
            requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID, GUIAutomationFeature.screenshot.capabilityID],
            landmarks: ["feed_item", "visible_metric"],
            transitions: [.init(fromSurface: "fullscreenMedia", toSurface: "fullscreenMedia", semanticAction: "collect_next_feed_item")],
            verificationObligations: ["bounded_sample_count", "metric_evidence_complete"],
            allowedLocalRecovery: ["stop_on_ambiguous_identity", "fresh_observation"]
        ),
        SemanticSkillDefinition(
            id: "skill.feed.commit.like.once",
            semanticGoal: "commit_selected_item_like",
            requiredSemanticSurface: "feed.item.selected",
            requiredCapabilities: [GUIAutomationFeature.touch.capabilityID, GUIAutomationFeature.screenshot.capabilityID],
            landmarks: ["like_control"],
            transitions: [.init(fromSurface: "feed.item.selected", toSurface: "feed.item.selected", semanticAction: "commit_like")],
            verificationObligations: ["liked_state_verified"],
            allowedLocalRecovery: ["reconcile_before_retry"],
            exactlyOnce: true
        )
    ]
}

public actor SemanticSkillRegistry {
    private let fileURL: URL
    private let predefined: [String: SemanticSkillDefinition]
    private var validated: [String: SemanticSkillDefinition] = [:]
    private var didLoad = false
    private static let maxSerializedBytes: Int64 = 2 * 1024 * 1024
    private static let minimumReusableEvidence = 2
    private static let revalidationAge: TimeInterval = 30 * 24 * 60 * 60
    private static let invalidationAge: TimeInterval = 180 * 24 * 60 * 60

    public init(
        fileURL: URL,
        predefinedSkills: [SemanticSkillDefinition] = SemanticSkillCatalog.predefined
    ) {
        self.fileURL = fileURL
        self.predefined = Dictionary(uniqueKeysWithValues: predefinedSkills.map { ($0.id, $0) })
    }

    public func all() -> [SemanticSkillDefinition] {
        loadIfNeeded()
        var merged = predefined
        for (id, value) in validated { merged[id] = value }
        return merged.values.sorted { $0.id < $1.id }
    }

    public func candidates(
        semanticGoal: String,
        bundleID: String?,
        currentSemanticSurface: String?,
        environment: AppActionEnvironment,
        now: Date = Date()
    ) -> [SemanticSkillCandidate] {
        loadIfNeeded()
        let goal = Self.normalized(semanticGoal)
        guard !goal.isEmpty else { return [] }
        var merged = predefined
        for (id, value) in validated where !Self.isInvalidated(value, now: now) {
            merged[id] = value
        }
        return merged.values
            .filter { skill in
                Self.normalized(skill.semanticGoal) == goal
                    && (skill.bundleID == nil || skill.bundleID == bundleID)
            }
            .map { skill in
                let surfaceMismatch = currentSemanticSurface.map(Self.normalized) != Self.normalized(skill.requiredSemanticSurface)
                let environmentMismatch = !skill.environment.matches(environment)
                let insufficientEvidence = skill.origin != .explicitlyValidated
                    || skill.evidenceCount < Self.minimumReusableEvidence
                let stale = Self.isStale(skill, now: now)
                return SemanticSkillCandidate(
                    skill: skill,
                    requiresRevalidation: surfaceMismatch || environmentMismatch || insufficientEvidence || stale
                )
            }
            .sorted { lhs, rhs in
                if lhs.requiresRevalidation != rhs.requiresRevalidation { return !lhs.requiresRevalidation }
                if lhs.skill.reliability != rhs.skill.reliability { return lhs.skill.reliability > rhs.skill.reliability }
                return lhs.skill.evidenceCount > rhs.skill.evidenceCount
            }
    }

    /// Validation must be explicit semantic evidence. One success is intentionally insufficient to
    /// become a reusable current-environment skill; two or more validations are required.
    public func recordExplicitValidation(
        skillID: String,
        bundleID: String?,
        environment: AppActionEnvironment,
        success: Bool,
        at now: Date = Date()
    ) throws {
        loadIfNeeded()
        guard let base = validated[skillID] ?? predefined[skillID] else {
            throw SemanticSkillRegistryError.unknownSkill(skillID)
        }
        guard !base.id.isEmpty, !base.semanticGoal.isEmpty, !base.requiredSemanticSurface.isEmpty,
              base.transitions.count <= 12, base.requiredCapabilities.count <= 16 else {
            throw SemanticSkillRegistryError.invalidSkill
        }
        var value = validated[skillID] ?? base
        let resolvedBundleID = bundleID ?? value.bundleID
        if !value.environment.matches(environment) || value.bundleID != resolvedBundleID {
            // Evidence is environment-scoped. Never combine one success from an old App/iOS/device
            // tuple with another success from a new tuple to manufacture a reusable skill.
            value.evidenceCount = 0
            value.reliability = base.reliability
            value.lastValidatedAt = nil
            value.lastFailureAt = nil
            value.origin = .predefined
        }
        value.bundleID = resolvedBundleID
        value.environment = environment
        if success {
            value.origin = .explicitlyValidated
            value.evidenceCount += 1
            value.reliability = min(0.99, value.reliability * 0.75 + 0.25)
            value.lastValidatedAt = now
        } else {
            value.reliability = max(0.02, value.reliability * 0.55)
            value.lastFailureAt = now
        }
        validated[skillID] = value
        try persist()
    }

    public func providerHint(
        semanticGoal: String,
        bundleID: String?,
        currentSemanticSurface: String?,
        environment: AppActionEnvironment
    ) -> String? {
        let matches = candidates(
            semanticGoal: semanticGoal,
            bundleID: bundleID,
            currentSemanticSurface: currentSemanticSurface,
            environment: environment
        ).prefix(3)
        guard !matches.isEmpty else { return nil }
        var lines = [
            "Semantic Skill Registry candidates are planning hints only. Fresh ObservationFrame, ToolRouter capability checks, PolicyEngine, confirmations, and postcondition verification always override them."
        ]
        for candidate in matches {
            let skill = candidate.skill
            let state = candidate.requiresRevalidation ? "revalidate" : "validated"
            let reliability = String(format: "%.2f", skill.reliability)
            let exactlyOnce = skill.exactlyOnce ? "true" : "false"
            let capabilities = skill.requiredCapabilities.joined(separator: ",")
            let verification = skill.verificationObligations.joined(separator: ",")
            let recovery = skill.allowedLocalRecovery.joined(separator: ",")
            lines.append(
                "\(skill.id): goal=\(skill.semanticGoal) surface=\(skill.requiredSemanticSurface) state=\(state) evidence=\(skill.evidenceCount) rel=\(reliability) exactlyOnce=\(exactlyOnce) capabilities=\(capabilities) verify=\(verification) recovery=\(recovery)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func persist() throws {
        let data = try JSONEncoder.pretty.encode(validated)
        guard data.count <= Self.maxSerializedBytes else { throw SemanticSkillRegistryError.cacheTooLarge }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > Self.maxSerializedBytes {
            validated = [:]
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        validated = (try? decoder.decode([String: SemanticSkillDefinition].self, from: data)) ?? [:]
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isStale(_ skill: SemanticSkillDefinition, now: Date) -> Bool {
        guard let lastValidatedAt = skill.lastValidatedAt else { return true }
        return now.timeIntervalSince(lastValidatedAt) > revalidationAge
    }

    private static func isInvalidated(_ skill: SemanticSkillDefinition, now: Date) -> Bool {
        guard skill.reliability >= 0.10 else { return true }
        guard let lastValidatedAt = skill.lastValidatedAt else {
            return skill.origin == .explicitlyValidated
        }
        return now.timeIntervalSince(lastValidatedAt) > invalidationAge
    }
}
