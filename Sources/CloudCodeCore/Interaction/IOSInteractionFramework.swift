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

public struct IOSInteractionObservationExperience: Codable, Equatable, Sendable {
    public var bundleID: String
    public var backend: IOSInteractionObservationBackend
    public var successes: Int
    public var failures: Int
    public var totalLatencyMS: Int
    public var lastValidatedAt: Date

    public init(
        bundleID: String,
        backend: IOSInteractionObservationBackend,
        successes: Int = 0,
        failures: Int = 0,
        totalLatencyMS: Int = 0,
        lastValidatedAt: Date = Date()
    ) {
        self.bundleID = bundleID
        self.backend = backend
        self.successes = max(0, successes)
        self.failures = max(0, failures)
        self.totalLatencyMS = max(0, totalLatencyMS)
        self.lastValidatedAt = lastValidatedAt
    }

    public var attempts: Int { successes + failures }

    public var reliability: Double {
        // Light Bayesian smoothing prevents one lucky sample from becoming a learned rule.
        Double(successes + 1) / Double(attempts + 2)
    }

    public var averageLatencyMS: Int? {
        guard attempts > 0 else { return nil }
        return totalLatencyMS / attempts
    }
}

public actor IOSInteractionExperienceStore {
    private struct PersistedState: Codable {
        var version: Int
        var observations: [String: IOSInteractionObservationExperience]
    }

    private let fileURL: URL
    private let maximumRecords = 128
    private let maximumFileBytes = 256 * 1024
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private var loaded = false
    private var observations: [String: IOSInteractionObservationExperience] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func recordObservation(
        bundleID: String,
        backend: IOSInteractionObservationBackend,
        success: Bool,
        latencyMS: Int,
        now: Date = Date()
    ) async {
        guard Self.isValidBundleIdentifier(bundleID), latencyMS >= 0, latencyMS <= 120_000 else { return }
        loadIfNeeded(now: now)
        prune(now: now)
        let key = Self.key(bundleID: bundleID, backend: backend)
        var record = observations[key] ?? IOSInteractionObservationExperience(bundleID: bundleID, backend: backend, lastValidatedAt: now)
        if success { record.successes += 1 } else { record.failures += 1 }
        record.totalLatencyMS = min(Int.max / 2, record.totalLatencyMS + latencyMS)
        record.lastValidatedAt = now
        observations[key] = record
        trimToBound()
        persistBestEffort()
    }

    public func providerHint(bundleID: String, now: Date = Date()) -> String? {
        guard Self.isValidBundleIdentifier(bundleID) else { return nil }
        loadIfNeeded(now: now)
        prune(now: now)
        let candidates = IOSInteractionObservationBackend.allCases.compactMap {
            observations[Self.key(bundleID: bundleID, backend: $0)]
        }.filter { $0.attempts >= 3 }
        guard candidates.count >= 1 else { return nil }

        let ranked = candidates.sorted { lhs, rhs in
            if abs(lhs.reliability - rhs.reliability) > 0.08 { return lhs.reliability > rhs.reliability }
            return (lhs.averageLatencyMS ?? Int.max) < (rhs.averageLatencyMS ?? Int.max)
        }
        guard let preferred = ranked.first, preferred.reliability >= 0.70 else { return nil }
        let latency = preferred.averageLatencyMS.map(String.init) ?? "unknown"
        let evidence = ranked.map { item in
            let average = item.averageLatencyMS.map(String.init) ?? "unknown"
            return "\(item.backend.rawValue)=\(item.successes)/\(item.attempts) success, avg \(average)ms"
        }.joined(separator: "; ")
        return "iOS Interaction experience for \(bundleID): prefer \(preferred.backend.rawValue) for the next observation when it is semantically appropriate (learned reliability \(String(format: "%.2f", preferred.reliability)), average \(latency)ms). Evidence: \(evidence). This is a performance hint only; current-run evidence and safety rules override it, and failure should immediately fall back to another valid observation path."
    }

    public func snapshot(now: Date = Date()) -> [IOSInteractionObservationExperience] {
        loadIfNeeded(now: now)
        prune(now: now)
        return observations.values.sorted {
            if $0.bundleID == $1.bundleID { return $0.backend.rawValue < $1.backend.rawValue }
            return $0.bundleID < $1.bundleID
        }
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
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == 1 else {
            observations = [:]
            return
        }
        observations = state.observations.filter { key, value in
            key == Self.key(bundleID: value.bundleID, backend: value.backend)
                && Self.isValidBundleIdentifier(value.bundleID)
                && value.successes >= 0
                && value.failures >= 0
                && value.totalLatencyMS >= 0
        }
        prune(now: now)
        trimToBound()
    }

    private func prune(now: Date) {
        observations = observations.filter { _, record in
            now.timeIntervalSince(record.lastValidatedAt) <= retentionInterval
        }
    }

    private func trimToBound() {
        guard observations.count > maximumRecords else { return }
        let kept = observations.values
            .sorted { $0.lastValidatedAt > $1.lastValidatedAt }
            .prefix(maximumRecords)
        observations = Dictionary(uniqueKeysWithValues: kept.map { (Self.key(bundleID: $0.bundleID, backend: $0.backend), $0) })
    }

    private func persistBestEffort() {
        let state = PersistedState(version: 1, observations: observations)
        guard let data = try? JSONEncoder().encode(state), data.count <= maximumFileBytes else { return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Experience is an optimization only. Persistence failure must never block the Agent.
        }
    }

    private static func key(bundleID: String, backend: IOSInteractionObservationBackend) -> String {
        "\(bundleID)|observation|\(backend.rawValue)"
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum IOSInteractionFramework {
    /// Stable iOS interaction semantics embedded into the app. This is intentionally compact:
    /// it gives the Agent an operating model without turning every App into a coordinate script.
    public static let coreInstruction = """
    iOS Interaction Framework: reason about the foreground UI as surfaces and transitions, not as isolated coordinates. Track the current surface, its origin, the pending objective, and any return obligation. Treat navigation-stack detail as temporary when later work belongs to the origin; prefer an unambiguous visible Back/Close control, otherwise edge-back for an iOS navigation stack. Treat full-screen media and modal media as temporary immersive surfaces; prefer an unambiguous visible close control, otherwise dismiss-down when appropriate, then semantically confirm the returned surface. Treat sheets/modals as scoped context and return to the parent surface after their task completes. Treat tabs as peer roots rather than Back history. Before text input, establish the intended composer/text field and focus; after input, observe before Send and observe again after Send. Prefer screenshot for visually rich social/media surfaces and accessibility tree for semantic controls when it is reliable. Learned App-specific preferences are performance hints only: never let learned experience override current observations, permissions, protected-confirmation rules, or fail-closed verification. Never learn or persist passwords, message text, private screenshot contents, permanent screen coordinates, entitlements, privilege rules, or HID constants. Experience may tune observation-backend preference, bounded timing, and verified navigation strategy; stale or failing experience must decay and fall back to current evidence.
    """
}
