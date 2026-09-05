import Foundation

public enum IOSInteractionSurface: String, Codable, CaseIterable, Sendable {
    case unknown
    case tabRoot
    case list
    case detail
    case chat
    case composer
    case fullscreenMedia
    case sheet
    case alert
    case settings
    case web
}

public enum IOSInteractionObservationBackend: String, Codable, CaseIterable, Sendable {
    case screenshot
    case accessibilityTree
}

public enum IOSInteractionNavigationStrategy: String, Codable, CaseIterable, Sendable {
    case visibleControl
    case edge
    case dismissDown
}

public struct IOSInteractionEnvironment: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appVersion: String
    public var osMajorVersion: Int
    public var deviceClass: String

    public init(bundleID: String, appVersion: String = "unknown", osMajorVersion: Int, deviceClass: String) {
        self.bundleID = bundleID
        self.appVersion = appVersion.isEmpty ? "unknown" : String(appVersion.prefix(128))
        self.osMajorVersion = max(0, osMajorVersion)
        self.deviceClass = deviceClass.isEmpty ? "unknown" : String(deviceClass.prefix(64))
    }

    public static func current(bundleID: String, appVersion: String? = nil) -> IOSInteractionEnvironment {
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #if os(iOS)
        let deviceClass = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "ios-device"
        #else
        let deviceClass = "non-ios-test"
        #endif
        return IOSInteractionEnvironment(
            bundleID: bundleID,
            appVersion: appVersion ?? "unknown",
            osMajorVersion: osMajor,
            deviceClass: deviceClass
        )
    }

    public var stableKey: String {
        "\(bundleID)|app=\(appVersion)|os=\(osMajorVersion)|device=\(deviceClass)"
    }
}

public struct IOSInteractionObservationExperience: Codable, Equatable, Sendable {
    public var environment: IOSInteractionEnvironment
    public var backend: IOSInteractionObservationBackend
    public var successes: Int
    public var failures: Int
    public var totalLatencyMS: Int
    public var lastValidatedAt: Date

    public init(
        environment: IOSInteractionEnvironment,
        backend: IOSInteractionObservationBackend,
        successes: Int = 0,
        failures: Int = 0,
        totalLatencyMS: Int = 0,
        lastValidatedAt: Date = Date()
    ) {
        self.environment = environment
        self.backend = backend
        self.successes = max(0, successes)
        self.failures = max(0, failures)
        self.totalLatencyMS = max(0, totalLatencyMS)
        self.lastValidatedAt = lastValidatedAt
    }

    public var bundleID: String { environment.bundleID }
    public var attempts: Int { successes + failures }

    public var reliability: Double {
        Double(successes + 1) / Double(attempts + 2)
    }

    public var averageLatencyMS: Int? {
        guard attempts > 0 else { return nil }
        return totalLatencyMS / attempts
    }
}

public struct IOSInteractionNavigationExperience: Codable, Equatable, Sendable {
    public var environment: IOSInteractionEnvironment
    public var fromSurface: IOSInteractionSurface
    public var toSurface: IOSInteractionSurface
    public var strategy: IOSInteractionNavigationStrategy
    public var successes: Int
    public var failures: Int
    public var lastValidatedAt: Date

    public init(
        environment: IOSInteractionEnvironment,
        fromSurface: IOSInteractionSurface,
        toSurface: IOSInteractionSurface,
        strategy: IOSInteractionNavigationStrategy,
        successes: Int = 0,
        failures: Int = 0,
        lastValidatedAt: Date = Date()
    ) {
        self.environment = environment
        self.fromSurface = fromSurface
        self.toSurface = toSurface
        self.strategy = strategy
        self.successes = max(0, successes)
        self.failures = max(0, failures)
        self.lastValidatedAt = lastValidatedAt
    }

    public var attempts: Int { successes + failures }
    public var reliability: Double { Double(successes + 1) / Double(attempts + 2) }
}

public actor IOSInteractionExperienceStore {
    private struct PersistedState: Codable {
        var version: Int
        var observations: [String: IOSInteractionObservationExperience]
        var navigation: [String: IOSInteractionNavigationExperience]
    }

    private struct VersionHeader: Codable { var version: Int }
    private struct LegacyObservation: Codable {
        var bundleID: String
        var backend: IOSInteractionObservationBackend
        var successes: Int
        var failures: Int
        var totalLatencyMS: Int
        var lastValidatedAt: Date
    }
    private struct LegacyState: Codable {
        var version: Int
        var observations: [String: LegacyObservation]
    }

    private let fileURL: URL
    private let maximumRecords = 192
    private let maximumFileBytes = 384 * 1024
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private var loaded = false
    private var observations: [String: IOSInteractionObservationExperience] = [:]
    private var navigation: [String: IOSInteractionNavigationExperience] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func recordObservation(
        environment: IOSInteractionEnvironment,
        backend: IOSInteractionObservationBackend,
        success: Bool,
        latencyMS: Int,
        now: Date = Date()
    ) async {
        guard Self.isValid(environment: environment), latencyMS >= 0, latencyMS <= 120_000 else { return }
        loadIfNeeded(now: now)
        prune(now: now)
        let key = Self.observationKey(environment: environment, backend: backend)
        var record = observations[key] ?? IOSInteractionObservationExperience(environment: environment, backend: backend, lastValidatedAt: now)
        if success { record.successes += 1 } else { record.failures += 1 }
        record.totalLatencyMS = min(Int.max / 2, record.totalLatencyMS + latencyMS)
        record.lastValidatedAt = now
        observations[key] = record
        trimToBound()
        persistBestEffort()
    }

    public func recordObservation(
        bundleID: String,
        appVersion: String? = nil,
        backend: IOSInteractionObservationBackend,
        success: Bool,
        latencyMS: Int,
        now: Date = Date()
    ) async {
        await recordObservation(
            environment: .current(bundleID: bundleID, appVersion: appVersion),
            backend: backend,
            success: success,
            latencyMS: latencyMS,
            now: now
        )
    }

    public func recordNavigationTransition(
        environment: IOSInteractionEnvironment,
        fromSurface: IOSInteractionSurface,
        toSurface: IOSInteractionSurface,
        strategy: IOSInteractionNavigationStrategy,
        success: Bool,
        now: Date = Date()
    ) async {
        guard Self.isValid(environment: environment), fromSurface != .unknown, toSurface != .unknown else { return }
        loadIfNeeded(now: now)
        prune(now: now)
        let key = Self.navigationKey(environment: environment, fromSurface: fromSurface, toSurface: toSurface, strategy: strategy)
        var record = navigation[key] ?? IOSInteractionNavigationExperience(
            environment: environment,
            fromSurface: fromSurface,
            toSurface: toSurface,
            strategy: strategy,
            lastValidatedAt: now
        )
        if success { record.successes += 1 } else { record.failures += 1 }
        record.lastValidatedAt = now
        navigation[key] = record
        trimToBound()
        persistBestEffort()
    }

    public func providerHint(environment: IOSInteractionEnvironment, now: Date = Date()) -> String? {
        guard Self.isValid(environment: environment) else { return nil }
        loadIfNeeded(now: now)
        prune(now: now)

        var hints: [String] = []
        let observationCandidates = IOSInteractionObservationBackend.allCases.compactMap {
            observations[Self.observationKey(environment: environment, backend: $0)]
        }.filter { $0.attempts >= 3 }
        if let preferred = observationCandidates.sorted(by: Self.preferObservation).first,
           preferred.reliability >= 0.70 {
            let evidence = observationCandidates.sorted(by: Self.preferObservation).map { item in
                let average = item.averageLatencyMS.map(String.init) ?? "unknown"
                return "\(item.backend.rawValue)=\(item.successes)/\(item.attempts),avg=\(average)ms"
            }.joined(separator: "; ")
            hints.append("prefer observation backend \(preferred.backend.rawValue) when semantically appropriate; evidence \(evidence)")
        }

        let learnedNavigation = navigation.values
            .filter { $0.environment == environment && $0.attempts >= 3 && $0.reliability >= 0.70 }
            .sorted { lhs, rhs in
                if lhs.reliability != rhs.reliability { return lhs.reliability > rhs.reliability }
                return lhs.lastValidatedAt > rhs.lastValidatedAt
            }
            .prefix(3)
        for item in learnedNavigation {
            hints.append("verified navigation \(item.fromSurface.rawValue)→\(item.toSurface.rawValue): prefer \(item.strategy.rawValue) (\(item.successes)/\(item.attempts), reliability \(String(format: "%.2f", item.reliability)))")
        }

        guard !hints.isEmpty else { return nil }
        return "iOS Interaction learned experience for \(environment.bundleID) app=\(environment.appVersion) iOS=\(environment.osMajorVersion) device=\(environment.deviceClass): \(hints.joined(separator: ". ")). This is a performance hint only; current-run evidence, HomeOS capability state, permissions, safety policy, and semantic verification always override it."
    }

    public func providerHint(bundleID: String, appVersion: String? = nil, now: Date = Date()) -> String? {
        providerHint(environment: .current(bundleID: bundleID, appVersion: appVersion), now: now)
    }

    public func observationSnapshot(now: Date = Date()) -> [IOSInteractionObservationExperience] {
        loadIfNeeded(now: now)
        prune(now: now)
        return observations.values.sorted {
            if $0.environment.stableKey == $1.environment.stableKey { return $0.backend.rawValue < $1.backend.rawValue }
            return $0.environment.stableKey < $1.environment.stableKey
        }
    }

    public func navigationSnapshot(now: Date = Date()) -> [IOSInteractionNavigationExperience] {
        loadIfNeeded(now: now)
        prune(now: now)
        return navigation.values.sorted {
            if $0.environment.stableKey == $1.environment.stableKey { return $0.lastValidatedAt > $1.lastValidatedAt }
            return $0.environment.stableKey < $1.environment.stableKey
        }
    }

    public func snapshot(now: Date = Date()) -> [IOSInteractionObservationExperience] {
        observationSnapshot(now: now)
    }

    public func clearAll() async {
        loadIfNeeded(now: Date())
        observations.removeAll()
        navigation.removeAll()
        persistBestEffort()
    }

    public func clear(bundleID: String) async {
        loadIfNeeded(now: Date())
        observations = observations.filter { $0.value.environment.bundleID != bundleID }
        navigation = navigation.filter { $0.value.environment.bundleID != bundleID }
        persistBestEffort()
    }

    private func loadIfNeeded(now: Date) {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= maximumFileBytes,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let header = try? JSONDecoder().decode(VersionHeader.self, from: data) else {
            observations = [:]
            navigation = [:]
            return
        }

        if header.version == 2,
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            observations = state.observations.filter { key, value in
                key == Self.observationKey(environment: value.environment, backend: value.backend)
                    && Self.isValid(environment: value.environment)
                    && value.successes >= 0 && value.failures >= 0 && value.totalLatencyMS >= 0
            }
            navigation = state.navigation.filter { key, value in
                key == Self.navigationKey(environment: value.environment, fromSurface: value.fromSurface, toSurface: value.toSurface, strategy: value.strategy)
                    && Self.isValid(environment: value.environment)
                    && value.successes >= 0 && value.failures >= 0
            }
        } else if header.version == 1,
                  let legacy = try? JSONDecoder().decode(LegacyState.self, from: data) {
            observations = [:]
            for item in legacy.observations.values where Self.isValidBundleIdentifier(item.bundleID) {
                let environment = IOSInteractionEnvironment.current(bundleID: item.bundleID)
                let record = IOSInteractionObservationExperience(
                    environment: environment,
                    backend: item.backend,
                    successes: item.successes,
                    failures: item.failures,
                    totalLatencyMS: item.totalLatencyMS,
                    lastValidatedAt: item.lastValidatedAt
                )
                observations[Self.observationKey(environment: environment, backend: item.backend)] = record
            }
            navigation = [:]
        } else {
            observations = [:]
            navigation = [:]
        }
        prune(now: now)
        trimToBound()
    }

    private func prune(now: Date) {
        observations = observations.filter { now.timeIntervalSince($0.value.lastValidatedAt) <= retentionInterval }
        navigation = navigation.filter { now.timeIntervalSince($0.value.lastValidatedAt) <= retentionInterval }
    }

    private func trimToBound() {
        let combinedCount = observations.count + navigation.count
        guard combinedCount > maximumRecords else { return }
        struct Stamp { var kind: Int; var key: String; var date: Date }
        var stamps = observations.map { Stamp(kind: 0, key: $0.key, date: $0.value.lastValidatedAt) }
        stamps += navigation.map { Stamp(kind: 1, key: $0.key, date: $0.value.lastValidatedAt) }
        let kept = Set(stamps.sorted { $0.date > $1.date }.prefix(maximumRecords).map { "\($0.kind)|\($0.key)" })
        observations = observations.filter { kept.contains("0|\($0.key)") }
        navigation = navigation.filter { kept.contains("1|\($0.key)") }
    }

    private func persistBestEffort() {
        let state = PersistedState(version: 2, observations: observations, navigation: navigation)
        guard let data = try? JSONEncoder().encode(state), data.count <= maximumFileBytes else { return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Experience is an optimization only. Persistence failure must never block the Agent.
        }
    }

    private static func preferObservation(_ lhs: IOSInteractionObservationExperience, _ rhs: IOSInteractionObservationExperience) -> Bool {
        if abs(lhs.reliability - rhs.reliability) > 0.08 { return lhs.reliability > rhs.reliability }
        return (lhs.averageLatencyMS ?? Int.max) < (rhs.averageLatencyMS ?? Int.max)
    }

    private static func observationKey(environment: IOSInteractionEnvironment, backend: IOSInteractionObservationBackend) -> String {
        "\(environment.stableKey)|observation|\(backend.rawValue)"
    }

    private static func navigationKey(
        environment: IOSInteractionEnvironment,
        fromSurface: IOSInteractionSurface,
        toSurface: IOSInteractionSurface,
        strategy: IOSInteractionNavigationStrategy
    ) -> String {
        "\(environment.stableKey)|navigation|\(fromSurface.rawValue)|\(toSurface.rawValue)|\(strategy.rawValue)"
    }

    private static func isValid(environment: IOSInteractionEnvironment) -> Bool {
        isValidBundleIdentifier(environment.bundleID)
            && !environment.appVersion.isEmpty && environment.appVersion.count <= 128
            && environment.osMajorVersion >= 0 && environment.osMajorVersion <= 100
            && !environment.deviceClass.isEmpty && environment.deviceClass.count <= 64
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// A typed semantic acknowledgement tool. It does not perform GUI actions; it only promotes
/// a navigation strategy after the model has inspected fresh observation evidence and explicitly
/// classified the transition. This keeps learning separate from dispatch success or pixel motion.
public struct IOSInteractionLearningExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .structuredTool
    private let experienceStore: IOSInteractionExperienceStore

    public init(experienceStore: IOSInteractionExperienceStore) {
        self.experienceStore = experienceStore
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name == "interaction.confirmTransition"
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard call.name == "interaction.confirmTransition" else { throw ToolRouterError.noExecutionRoute(call.name) }
        guard let bundleID = call.arguments["bundleId"],
              let fromRaw = call.arguments["fromSurface"], let from = IOSInteractionSurface(rawValue: fromRaw), from != .unknown,
              let toRaw = call.arguments["toSurface"], let to = IOSInteractionSurface(rawValue: toRaw), to != .unknown,
              let strategyRaw = call.arguments["strategy"], let strategy = IOSInteractionNavigationStrategy(rawValue: strategyRaw),
              let successRaw = call.arguments["success"], let success = Self.parseBoolean(successRaw),
              let confidenceRaw = call.arguments["confidence"], let confidence = Double(confidenceRaw), confidence.isFinite,
              confidence >= 0.5, confidence <= 1.0 else {
            throw ToolRouterError.noExecutionRoute("interaction.confirmTransition arguments are invalid")
        }
        let environment = IOSInteractionEnvironment.current(bundleID: bundleID, appVersion: call.arguments["appVersion"])
        if confidence >= 0.75 {
            await experienceStore.recordNavigationTransition(
                environment: environment,
                fromSurface: from,
                toSurface: to,
                strategy: strategy,
                success: success
            )
        }
        return ToolResult(
            toolCallID: call.id,
            success: true,
            summary: confidence >= 0.75 ? "Semantic navigation evidence recorded" : "Semantic navigation evidence ignored because confidence was below promotion threshold",
            payload: [
                "learning": confidence >= 0.75 ? "recorded" : "ignored_low_confidence",
                "bundleId": bundleID,
                "strategy": strategy.rawValue,
                "success": success ? "true" : "false"
            ]
        )
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}

public enum IOSInteractionFramework {
    public static let coreInstruction = """
    iOS Interaction Framework is the interaction domain of Cloud Code's existing HomeOS/Core/Harness runtime, not a separate authority. HomeOS capability evidence determines which primitives actually exist; Harness compiles task shape; ToolRouter/PolicyEngine/root helper execute bounded actions; the Interaction Framework models iOS surfaces, transitions, input state, return obligations, and verified experience. Reason about the foreground UI as surfaces and transitions, not isolated coordinates. Track current surface, origin, pending objective, and return obligation. Treat navigation-stack detail as temporary when later work belongs to the origin; prefer an unambiguous visible Back/Close control, otherwise edge-back for an iOS navigation stack. Treat full-screen/modal media as temporary immersive surfaces; prefer an unambiguous visible close control, otherwise dismiss-down when appropriate, then semantically confirm the returned surface. Treat sheets/modals as scoped context and return to the parent after their task completes. Treat tabs as peer roots rather than Back history. Before text input, establish the intended composer/text field and focus; after input, observe before Send and observe again after Send. Prefer screenshot for visually rich social/media surfaces and accessibility tree for semantic controls when reliable. For one bounded state-changing primitive whose next required step is only observation, prefer the paired local action-observe tool (gui.tapObserve/gui.typeObserve/gui.scrollObserve/gui.swipeObserve) so action and fresh screenshot occur inside one tool call. Never chain a second state-changing action locally when it depends on interpreting the first result. After gui.navigateBack or another learned navigation attempt, pixel/hash change alone is never semantic proof. If a fresh observation clearly establishes the transition, call interaction.confirmTransition with the actual from/to surface, strategy, success, and confidence; only that typed semantic evidence may promote navigation experience. Learned App-specific preferences are performance hints only and are partitioned by App version, iOS major version, and device class when known. Never let learned experience override current observations, HomeOS capability state, permissions, protected-confirmation rules, or fail-closed verification. Never learn or persist passwords, message text, private screenshot contents, permanent screen coordinates, entitlements, privilege rules, or HID constants. Stale or failing experience must decay and fall back to current evidence.
    """
}
