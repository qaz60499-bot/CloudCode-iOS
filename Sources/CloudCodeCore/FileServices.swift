import Foundation
import ZIPFoundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public actor AuditLogStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let fileManager: FileManager
    private static let maxTailReadBytes: UInt64 = 4 * 1024 * 1024

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func append(_ event: AuditEvent) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        var line = try encoder.encode(event)
        line.append(0x0A)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func readAll() throws -> [AuditEvent] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AuditEvent.self, from: Data($0)) }
    }

    public func readNewest(limit: Int = 200) throws -> [AuditEvent] {
        guard limit > 0, fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end > Self.maxTailReadBytes ? end - Self.maxTailReadBytes : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let completeLines = start > 0 ? Array(lines.dropFirst()) : lines
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let boundedLimit = min(limit, 2_000)
        return completeLines.suffix(boundedLimit).compactMap {
            try? decoder.decode(AuditEvent.self, from: Data($0))
        }
    }

    public func exportSnapshotData() throws -> Data {
        guard fileManager.fileExists(atPath: fileURL.path) else { return Data() }
        return try Data(contentsOf: fileURL)
    }
}

public enum AppKnowledgeRegistryError: Error, Equatable, Sendable {
    case cacheTooLarge
    case invalidAction
    case invalidSemanticKnowledge
    case missingApp(String)
}

public actor AppKnowledgeRegistry {
    private let fileURL: URL
    private var entries: [String: AppKnowledge] = [:]
    private var didLoad = false
    private static let maxSerializedBytes: Int64 = 8 * 1024 * 1024

    public init(fileURL: URL) {
        // This registry is a rebuildable heuristic cache. Defer all disk reads until
        // after launch so corrupt/oversized history can never kill the first frame.
        self.fileURL = fileURL
    }

    public func all() -> [AppKnowledge] {
        loadIfNeeded()
        return entries.values.sorted { lhs, rhs in
            if lhs.estimatedCost == rhs.estimatedCost { return lhs.successRate > rhs.successRate }
            return lhs.estimatedCost < rhs.estimatedCost
        }
    }

    public func knowledge(for bundleID: String) -> AppKnowledge? {
        loadIfNeeded()
        return entries[bundleID]
    }

    public func upsert(_ value: AppKnowledge) throws {
        loadIfNeeded()
        let previous = entries[value.bundleID]
        entries[value.bundleID] = value
        let data = try JSONEncoder.pretty.encode(entries)
        guard data.count <= Self.maxSerializedBytes else {
            if let previous {
                entries[value.bundleID] = previous
            } else {
                entries.removeValue(forKey: value.bundleID)
            }
            throw AppKnowledgeRegistryError.cacheTooLarge
        }
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func providerHint(
        bundleID: String,
        appVersion: String?,
        environment: AppActionEnvironment? = nil
    ) -> String? {
        loadIfNeeded()
        guard let knowledge = entries[bundleID] else { return nil }
        var lines: [String] = [
            "AppKnowledge hint for \(bundleID) (performance/discovery only; never a capability or authority grant)."
        ]
        if let appVersion, let storedVersion = knowledge.appVersion, storedVersion != appVersion {
            lines.append("Stored AppKnowledge version \(storedVersion) differs from current \(appVersion); treat all stored routes as stale candidates requiring bounded revalidation.")
        }
        if !knowledge.urlSchemes.isEmpty {
            lines.append("Discovered URL schemes: \(knowledge.urlSchemes.prefix(12).joined(separator: ", ")). Use only through the validated URL/deep-link executor; never invent a scheme or target path.")
        }
        if let metadata = knowledge.introspectionMetadata, !metadata.isEmpty {
            let selectedKeys = ["executable", "documentTypes", "extensions", "frameworks", "appGroups", "associatedDomains"]
            let rendered = selectedKeys.compactMap { key -> String? in
                guard let value = metadata[key], !value.isEmpty else { return nil }
                return "\(key)=\(String(value.prefix(512)))"
            }
            if !rendered.isEmpty { lines.append("Static introspection: " + rendered.joined(separator: "; ")) }
        }
        if let localDataMap = knowledge.localDataMap, !localDataMap.isEmpty {
            let aliases = localDataMap.keys.sorted().prefix(12)
            lines.append("Known local-data aliases: \(aliases.joined(separator: ", ")). Stored paths are candidates only: resolve the current container and revalidate before any read or mutation.")
        }
        if let environment {
            // Consume the existing actionCandidates() API in the production planning hint instead
            // of maintaining a second sorter here. Learning remains performance/discovery only:
            // capability/policy eligibility is still enforced later by ToolRouter.
            let semanticActions = Set((knowledge.actionMap ?? []).map { Self.normalizedAction($0.semanticAction) })
                .filter { !$0.isEmpty }
            let candidates = semanticActions
                .flatMap { actionCandidates(for: bundleID, semanticAction: $0, environment: environment) }
                .sorted { lhs, rhs in
                    if lhs.requiresRevalidation != rhs.requiresRevalidation { return !lhs.requiresRevalidation }
                    if lhs.hint.reliability != rhs.hint.reliability { return lhs.hint.reliability > rhs.hint.reliability }
                    return lhs.hint.estimatedLatencyMS < rhs.hint.estimatedLatencyMS
                }
                .prefix(8)
            if !candidates.isEmpty {
                let rendered = candidates.map { candidate in
                    let stale = candidate.requiresRevalidation ? "stale/revalidate" : "current"
                    return "\(candidate.hint.semanticAction)->\(candidate.hint.route.rawValue) rel=\(String(format: "%.2f", candidate.hint.reliability)) latency=\(candidate.hint.estimatedLatencyMS)ms \(stale)"
                }
                lines.append("ActionMap candidates: " + rendered.joined(separator: " | "))
            }

            let surfaces = semanticSurfaceCandidates(for: bundleID, environment: environment).prefix(6)
            if !surfaces.isEmpty {
                let rendered = surfaces.map { candidate in
                    let stale = candidate.requiresRevalidation ? "stale/revalidate" : "current"
                    let landmarks = candidate.knowledge.landmarks.prefix(4).joined(separator: "/")
                    return "\(candidate.knowledge.semanticSurface)[\(candidate.knowledge.genericSurface.rawValue)] rel=\(String(format: "%.2f", candidate.knowledge.reliability)) evidence=\(candidate.knowledge.evidenceCount) \(stale) landmarks=\(landmarks)"
                }
                lines.append("Semantic surfaces: " + rendered.joined(separator: " | "))
            }

            let transitions = semanticTransitionCandidates(for: bundleID, environment: environment).prefix(6)
            if !transitions.isEmpty {
                let rendered = transitions.map { candidate in
                    let stale = candidate.requiresRevalidation ? "stale/revalidate" : "current"
                    return "\(candidate.knowledge.fromSurface)->\(candidate.knowledge.toSurface) action=\(candidate.knowledge.semanticAction) rel=\(String(format: "%.2f", candidate.knowledge.reliability)) latency=\(candidate.knowledge.estimatedLatencyMS)ms \(stale)"
                }
                lines.append("Semantic transitions: " + rendered.joined(separator: " | "))
            }
            if !surfaces.isEmpty || !transitions.isEmpty {
                lines.append("Fresh ObservationFrame evidence always overrides cached semantic surfaces/transitions; ambiguity requires re-observation rather than cache-driven execution.")
            }
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    public func actionCandidates(
        for bundleID: String,
        semanticAction: String,
        environment: AppActionEnvironment
    ) -> [AppActionCandidate] {
        loadIfNeeded()
        let action = Self.normalizedAction(semanticAction)
        guard !action.isEmpty, let knowledge = entries[bundleID] else { return [] }
        return (knowledge.actionMap ?? [])
            .filter { Self.normalizedAction($0.semanticAction) == action }
            .map { hint in
                AppActionCandidate(hint: hint, requiresRevalidation: !hint.environment.matches(environment))
            }
            .sorted { lhs, rhs in
                if lhs.requiresRevalidation != rhs.requiresRevalidation {
                    return !lhs.requiresRevalidation
                }
                if lhs.hint.reliability != rhs.hint.reliability {
                    return lhs.hint.reliability > rhs.hint.reliability
                }
                return lhs.hint.estimatedLatencyMS < rhs.hint.estimatedLatencyMS
            }
    }

    public func semanticSurfaceCandidates(
        for bundleID: String,
        environment: AppActionEnvironment,
        now: Date = Date()
    ) -> [AppSemanticSurfaceCandidate] {
        loadIfNeeded()
        guard let knowledge = entries[bundleID] else { return [] }
        return (knowledge.semanticSurfaces ?? [])
            .filter { !Self.isInvalidated(lastValidatedAt: $0.lastValidatedAt, reliability: $0.reliability, now: now) }
            .map { value in
                AppSemanticSurfaceCandidate(
                    knowledge: value,
                    requiresRevalidation: !value.environment.matches(environment)
                        || Self.isStale(lastValidatedAt: value.lastValidatedAt, now: now)
                )
            }
            .sorted { lhs, rhs in
                if lhs.requiresRevalidation != rhs.requiresRevalidation { return !lhs.requiresRevalidation }
                if lhs.knowledge.reliability != rhs.knowledge.reliability { return lhs.knowledge.reliability > rhs.knowledge.reliability }
                return lhs.knowledge.evidenceCount > rhs.knowledge.evidenceCount
            }
    }

    public func semanticTransitionCandidates(
        for bundleID: String,
        fromSurface: String? = nil,
        semanticAction: String? = nil,
        environment: AppActionEnvironment,
        now: Date = Date()
    ) -> [AppSemanticTransitionCandidate] {
        loadIfNeeded()
        guard let knowledge = entries[bundleID] else { return [] }
        let from = fromSurface.map(Self.normalizedSemanticToken)
        let action = semanticAction.map(Self.normalizedAction)
        return (knowledge.semanticTransitions ?? [])
            .filter { transition in
                (from == nil || Self.normalizedSemanticToken(transition.fromSurface) == from)
                    && (action == nil || Self.normalizedAction(transition.semanticAction) == action)
                    && !Self.isInvalidated(lastValidatedAt: transition.lastValidatedAt, reliability: transition.reliability, now: now)
            }
            .map { value in
                AppSemanticTransitionCandidate(
                    knowledge: value,
                    requiresRevalidation: !value.environment.matches(environment)
                        || Self.isStale(lastValidatedAt: value.lastValidatedAt, now: now)
                )
            }
            .sorted { lhs, rhs in
                if lhs.requiresRevalidation != rhs.requiresRevalidation { return !lhs.requiresRevalidation }
                if lhs.knowledge.reliability != rhs.knowledge.reliability { return lhs.knowledge.reliability > rhs.knowledge.reliability }
                return lhs.knowledge.estimatedLatencyMS < rhs.knowledge.estimatedLatencyMS
            }
    }

    /// Record one high-confidence semantic surface observation into the existing AppKnowledge cache.
    /// The cache remains subordinate to current ObservationFrame evidence and stores no coordinates.
    public func recordSemanticSurface(
        bundleID: String,
        semanticSurface: String,
        genericSurface: IOSInteractionSurface,
        landmarks: [String],
        environment: AppActionEnvironment,
        confidence: Double,
        at now: Date = Date()
    ) throws {
        loadIfNeeded()
        let surface = Self.normalizedSemanticToken(semanticSurface)
        guard !surface.isEmpty, surface.utf8.count <= 128,
              confidence.isFinite, confidence >= 0.70, confidence <= 1.0,
              var knowledge = entries[bundleID] else {
            if entries[bundleID] == nil { throw AppKnowledgeRegistryError.missingApp(bundleID) }
            throw AppKnowledgeRegistryError.invalidSemanticKnowledge
        }
        let boundedLandmarks = Self.boundedSemanticLandmarks(landmarks)
        var values = knowledge.semanticSurfaces ?? []
        if let index = values.firstIndex(where: {
            Self.normalizedSemanticToken($0.semanticSurface) == surface && $0.environment.matches(environment)
        }) {
            var value = values[index]
            value.genericSurface = genericSurface
            value.landmarks = Self.mergeLandmarks(value.landmarks, boundedLandmarks)
            value.evidenceCount += 1
            value.reliability = min(0.99, value.reliability * 0.80 + confidence * 0.20)
            value.lastValidatedAt = now
            values[index] = value
        } else {
            values.append(AppSemanticSurfaceKnowledge(
                semanticSurface: surface,
                genericSurface: genericSurface,
                landmarks: boundedLandmarks,
                environment: environment,
                reliability: min(0.95, max(0.50, confidence)),
                evidenceCount: 1,
                lastValidatedAt: now
            ))
        }
        values = Array(values.sorted {
            ($0.lastValidatedAt ?? .distantPast) > ($1.lastValidatedAt ?? .distantPast)
        }.prefix(128))
        knowledge.semanticSurfaces = values
        try upsert(knowledge)
    }

    /// Record an explicitly semantically verified transition. A failed transition decays the edge;
    /// pixel/hash movement alone must never call this method as success.
    public func recordSemanticTransition(
        bundleID: String,
        fromSurface: String,
        toSurface: String,
        semanticAction: String,
        landmarks: [String] = [],
        environment: AppActionEnvironment,
        success: Bool,
        confidence: Double,
        latencyMS: Int,
        at now: Date = Date()
    ) throws {
        loadIfNeeded()
        let from = Self.normalizedSemanticToken(fromSurface)
        let to = Self.normalizedSemanticToken(toSurface)
        let action = Self.normalizedAction(semanticAction)
        guard !from.isEmpty, !to.isEmpty, !action.isEmpty,
              from.utf8.count <= 128, to.utf8.count <= 128, action.utf8.count <= 128,
              confidence.isFinite, confidence >= 0.70, confidence <= 1.0,
              var knowledge = entries[bundleID] else {
            if entries[bundleID] == nil { throw AppKnowledgeRegistryError.missingApp(bundleID) }
            throw AppKnowledgeRegistryError.invalidSemanticKnowledge
        }
        let boundedLatency = min(max(latencyMS, 0), 10 * 60 * 1_000)
        let boundedLandmarks = Self.boundedSemanticLandmarks(landmarks)
        var values = knowledge.semanticTransitions ?? []
        if let index = values.firstIndex(where: {
            Self.normalizedSemanticToken($0.fromSurface) == from
                && Self.normalizedSemanticToken($0.toSurface) == to
                && Self.normalizedAction($0.semanticAction) == action
                && $0.environment.matches(environment)
        }) {
            var value = values[index]
            value.landmarks = Self.mergeLandmarks(value.landmarks, boundedLandmarks)
            if success {
                value.evidenceCount += 1
                value.reliability = min(0.99, value.reliability * 0.75 + confidence * 0.25)
                value.estimatedLatencyMS = value.estimatedLatencyMS == 0
                    ? boundedLatency
                    : Int((Double(value.estimatedLatencyMS) * 0.7 + Double(boundedLatency) * 0.3).rounded())
                value.lastValidatedAt = now
            } else {
                value.reliability = max(0.02, value.reliability * 0.55)
                value.lastFailureAt = now
            }
            values[index] = value
        } else {
            values.append(AppSemanticTransitionKnowledge(
                fromSurface: from,
                toSurface: to,
                semanticAction: action,
                landmarks: boundedLandmarks,
                environment: environment,
                reliability: success ? min(0.90, max(0.55, confidence)) : 0.20,
                estimatedLatencyMS: boundedLatency,
                evidenceCount: success ? 1 : 0,
                lastValidatedAt: success ? now : nil,
                lastFailureAt: success ? nil : now
            ))
        }
        values = Array(values.sorted {
            let lhsDate = max($0.lastValidatedAt ?? .distantPast, $0.lastFailureAt ?? .distantPast)
            let rhsDate = max($1.lastValidatedAt ?? .distantPast, $1.lastFailureAt ?? .distantPast)
            return lhsDate > rhsDate
        }.prefix(256))
        knowledge.semanticTransitions = values
        if success {
            var surfaces = knowledge.semanticSurfaces ?? []
            for surface in [from, to] {
                if let index = surfaces.firstIndex(where: {
                    Self.normalizedSemanticToken($0.semanticSurface) == surface && $0.environment.matches(environment)
                }) {
                    var value = surfaces[index]
                    value.evidenceCount += 1
                    value.reliability = min(0.99, value.reliability * 0.80 + confidence * 0.20)
                    value.lastValidatedAt = now
                    surfaces[index] = value
                } else {
                    surfaces.append(AppSemanticSurfaceKnowledge(
                        semanticSurface: surface,
                        genericSurface: IOSInteractionSurface(rawValue: surface) ?? .unknown,
                        landmarks: [],
                        environment: environment,
                        reliability: min(0.90, max(0.55, confidence)),
                        evidenceCount: 1,
                        lastValidatedAt: now
                    ))
                }
            }
            knowledge.semanticSurfaces = Array(surfaces.sorted {
                ($0.lastValidatedAt ?? .distantPast) > ($1.lastValidatedAt ?? .distantPast)
            }.prefix(128))
        }
        try upsert(knowledge)
    }

    /// Record only performance evidence for an already-known App. This never promotes a route into
    /// a capability: ToolRouter/CapabilityProfile/PolicyEngine still decide whether an execution is
    /// legal and available when the next request actually runs.
    public func recordActionOutcome(
        bundleID: String,
        semanticAction: String,
        route: AppExecutionRoute,
        environment: AppActionEnvironment,
        success: Bool,
        latencyMS: Int,
        at now: Date = Date()
    ) throws {
        loadIfNeeded()
        let action = Self.normalizedAction(semanticAction)
        guard !action.isEmpty, action.utf8.count <= 128 else { throw AppKnowledgeRegistryError.invalidAction }
        guard var knowledge = entries[bundleID] else { throw AppKnowledgeRegistryError.missingApp(bundleID) }
        var map = knowledge.actionMap ?? []
        let boundedLatency = min(max(latencyMS, 0), 10 * 60 * 1_000)
        if let index = map.firstIndex(where: {
            Self.normalizedAction($0.semanticAction) == action
                && $0.route == route
                && $0.environment.matches(environment)
        }) {
            var hint = map[index]
            if success {
                hint.successCount += 1
                hint.reliability = min(0.99, (hint.reliability * 0.75) + 0.25)
                hint.estimatedLatencyMS = hint.estimatedLatencyMS == 0
                    ? boundedLatency
                    : Int((Double(hint.estimatedLatencyMS) * 0.7 + Double(boundedLatency) * 0.3).rounded())
                hint.lastValidatedAt = now
            } else {
                hint.failureCount += 1
                hint.reliability = max(0.02, hint.reliability * 0.55)
                hint.lastFailureAt = now
            }
            map[index] = hint
        } else {
            map.append(AppActionRouteHint(
                semanticAction: action,
                route: route,
                environment: environment,
                reliability: success ? 0.65 : 0.2,
                estimatedLatencyMS: boundedLatency,
                successCount: success ? 1 : 0,
                failureCount: success ? 0 : 1,
                lastValidatedAt: success ? now : nil,
                lastFailureAt: success ? nil : now
            ))
        }
        // ActionMap is a rebuildable cache, not an append-only audit log. Bound it aggressively.
        map = Array(map.sorted { lhs, rhs in
            let lhsDate = max(lhs.lastValidatedAt ?? .distantPast, lhs.lastFailureAt ?? .distantPast)
            let rhsDate = max(rhs.lastValidatedAt ?? .distantPast, rhs.lastFailureAt ?? .distantPast)
            return lhsDate > rhsDate
        }.prefix(256))
        knowledge.actionMap = map
        try upsert(knowledge)
    }

    private static let semanticRevalidationAge: TimeInterval = 30 * 24 * 60 * 60
    private static let semanticInvalidationAge: TimeInterval = 180 * 24 * 60 * 60

    private static func normalizedAction(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedSemanticToken(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    }

    private static func boundedSemanticLandmarks(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
            if result.count >= 24 { break }
        }
        return result
    }

    private static func mergeLandmarks(_ lhs: [String], _ rhs: [String]) -> [String] {
        boundedSemanticLandmarks(lhs + rhs)
    }

    private static func isStale(lastValidatedAt: Date?, now: Date) -> Bool {
        guard let lastValidatedAt else { return true }
        return now.timeIntervalSince(lastValidatedAt) > semanticRevalidationAge
    }

    private static func isInvalidated(lastValidatedAt: Date?, reliability: Double, now: Date) -> Bool {
        guard reliability >= 0.10, let lastValidatedAt else { return true }
        return now.timeIntervalSince(lastValidatedAt) > semanticInvalidationAge
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > Self.maxSerializedBytes {
            entries = [:]
            return
        }
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([String: AppKnowledge].self, from: data) {
                entries = decoded
            } else {
                entries = [:]
            }
        } else {
            entries = [:]
        }
    }
}

public struct FileEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modificationDate: Date?

    public init(path: String, name: String, isDirectory: Bool, size: Int64, modificationDate: Date?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }
}

public struct FileSearchQuery: Sendable {
    public var nameContains: String?
    public var extensions: Set<String>
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var maxDepth: Int
    public var maxResults: Int
    public var maxVisited: Int

    public init(
        nameContains: String? = nil,
        extensions: Set<String> = [],
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        maxDepth: Int = 4,
        maxResults: Int = 500,
        maxVisited: Int = 20_000
    ) {
        self.nameContains = nameContains
        self.extensions = extensions
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        // Preserve the existing query semantics for depth/result budgets. Public/Agent callers
        // already apply their own bounds; maxVisited is the new independent traversal circuit breaker.
        self.maxDepth = maxDepth
        self.maxResults = maxResults
        self.maxVisited = min(max(maxVisited, 128), 100_000)
    }
}

public struct FileMetadataSnapshot: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isRegularFile: Bool
    public var size: Int64
    public var creationDate: Date?
    public var modificationDate: Date?
    public var contentType: String?
    public var fileProtection: String?
    public var isReadable: Bool
    public var isWritable: Bool

    public init(path: String, name: String, isDirectory: Bool, isRegularFile: Bool, size: Int64, creationDate: Date?, modificationDate: Date?, contentType: String?, fileProtection: String?, isReadable: Bool, isWritable: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.contentType = contentType
        self.fileProtection = fileProtection
        self.isReadable = isReadable
        self.isWritable = isWritable
    }
}

public struct FileTextDiffSummary: Codable, Equatable, Sendable {
    public var leftPath: String
    public var rightPath: String
    public var identical: Bool
    public var addedLineCount: Int
    public var removedLineCount: Int
    public var firstDifferences: [String]
}

public struct FileService: @unchecked Sendable {
    public let fileManager: FileManager
    public let pathGuard: PathGuard
    public let secureFileMutation: SecureFileMutation

    public init(
        fileManager: FileManager = .default,
        pathGuard: PathGuard = PathGuard(),
        secureFileMutation: SecureFileMutation = SecureFileMutation()
    ) {
        self.fileManager = fileManager
        self.pathGuard = pathGuard
        self.secureFileMutation = secureFileMutation
    }

    public func list(directory: URL, allowedRoot: URL? = nil) throws -> [FileEntry] {
        let safe = try pathGuard.validate(target: directory, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let urls = try fileManager.contentsOfDirectory(at: safe, includingPropertiesForKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        return urls.compactMap(entry(for:)).sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func search(root: URL, query: FileSearchQuery, allowedRoot: URL? = nil) throws -> [FileEntry] {
        let safe = try pathGuard.validate(target: root, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let baseDepth = safe.pathComponents.count
        guard let enumerator = fileManager.enumerator(at: safe, includingPropertiesForKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [FileEntry] = []
        var visitedCount = 0

        for case let url as URL in enumerator {
            visitedCount += 1
            if visitedCount % 128 == 0 { try Task.checkCancellation() }
            if visitedCount > query.maxVisited { break }
            let depth = url.pathComponents.count - baseDepth
            if depth > query.maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard let item = entry(for: url) else { continue }

            if let needle = query.nameContains?.lowercased(), !item.name.lowercased().contains(needle) { continue }
            if !query.extensions.isEmpty, !item.isDirectory {
                let ext = url.pathExtension.lowercased()
                if !query.extensions.contains(ext) { continue }
            }
            if let modifiedAfter = query.modifiedAfter {
                guard let modificationDate = item.modificationDate, modificationDate >= modifiedAfter else { continue }
            }
            if let modifiedBefore = query.modifiedBefore {
                guard let modificationDate = item.modificationDate, modificationDate <= modifiedBefore else { continue }
            }
            results.append(item)
            if results.count >= query.maxResults { break }
        }
        return results
    }

    public func analyzeStorage(root: URL, allowedRoot: URL? = nil, top: Int = 50) throws -> [FileEntry] {
        var query = FileSearchQuery(maxDepth: 16, maxResults: 20_000, maxVisited: 100_000)
        query.extensions = []
        let files = try search(root: root, query: query, allowedRoot: allowedRoot).filter { !$0.isDirectory }
        return files.sorted { $0.size > $1.size }.prefix(top).map { $0 }
    }

    public func readText(_ url: URL, allowedRoot: URL? = nil, maxBytes: Int = 1_000_000) throws -> String {
        let safe = try pathGuard.validate(target: url, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let identity = try secureFileMutation.identity(of: safe, allowedRoot: allowedRoot)
        let data = try secureFileMutation.readFile(at: safe, allowedRoot: allowedRoot, expectedIdentity: identity, maxBytes: maxBytes)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return value
    }

    public func stat(_ url: URL, allowedRoot: URL? = nil) throws -> FileMetadataSnapshot {
        let safe = try pathGuard.validate(target: url, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let values = try safe.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .creationDateKey, .contentModificationDateKey, .typeIdentifierKey
        ])
        let attributes = try? fileManager.attributesOfItem(atPath: safe.path)
        let protection = attributes?[.protectionKey].map { String(describing: $0) }
        let logicalSize = Int64(values.fileSize ?? 0)
        let allocatedSize = Int64(values.totalFileAllocatedSize ?? 0)
        return FileMetadataSnapshot(
            path: safe.path,
            name: safe.lastPathComponent,
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true,
            size: max(logicalSize, allocatedSize),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            contentType: values.typeIdentifier,
            fileProtection: protection,
            isReadable: fileManager.isReadableFile(atPath: safe.path),
            isWritable: fileManager.isWritableFile(atPath: safe.path)
        )
    }

    public func sha256(_ url: URL, allowedRoot: URL? = nil, maxBytes: Int = 64 * 1024 * 1024) throws -> String {
        let safe = try pathGuard.validate(target: url, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let identity = try secureFileMutation.identity(of: safe, allowedRoot: allowedRoot)
        let data = try secureFileMutation.readFile(at: safe, allowedRoot: allowedRoot, expectedIdentity: identity, maxBytes: maxBytes)
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    public func diffText(_ left: URL, _ right: URL, allowedRoot: URL? = nil, maxBytesPerFile: Int = 1_000_000) throws -> FileTextDiffSummary {
        let leftText = try readText(left, allowedRoot: allowedRoot, maxBytes: maxBytesPerFile)
        let rightText = try readText(right, allowedRoot: allowedRoot, maxBytes: maxBytesPerFile)
        let leftLines = leftText.components(separatedBy: .newlines)
        let rightLines = rightText.components(separatedBy: .newlines)
        let difference = rightLines.difference(from: leftLines)
        var added = 0
        var removed = 0
        var firstDifferences: [String] = []
        firstDifferences.reserveCapacity(32)
        for change in difference {
            switch change {
            case .insert(let offset, let element, _):
                added += 1
                if firstDifferences.count < 32 { firstDifferences.append("+\(offset + 1): \(String(element.prefix(240)))") }
            case .remove(let offset, let element, _):
                removed += 1
                if firstDifferences.count < 32 { firstDifferences.append("-\(offset + 1): \(String(element.prefix(240)))") }
            }
        }
        return FileTextDiffSummary(
            leftPath: left.standardizedFileURL.path,
            rightPath: right.standardizedFileURL.path,
            identical: difference.isEmpty,
            addedLineCount: added,
            removedLineCount: removed,
            firstDifferences: firstDifferences
        )
    }

    private func entry(for url: URL) -> FileEntry? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]) else { return nil }
        let isDirectory = values.isDirectory == true
        // Directory listing must remain shallow. Recursively calculating every child folder size
        // makes a single `files.list` or Resource Explorer directory open behave like a deep scan.
        // Folder size is therefore unknown/omitted at list time (represented as 0 by FileEntry's
        // existing non-optional field); explicit storage analysis remains the separate deep path.
        let size = isDirectory ? 0 : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        return FileEntry(path: url.path, name: url.lastPathComponent, isDirectory: isDirectory, size: size, modificationDate: values.contentModificationDate)
    }
}

public enum TrashServiceError: Error, Equatable {
    case oversizedJournal
}

public actor TrashService {
    private let root: URL
    private let journalURL: URL
    private let fileManager: FileManager
    private let pathGuard: PathGuard
    private let secureFileMutation: SecureFileMutation
    private static let maxJournalBytes: Int64 = 8 * 1024 * 1024

    public init(
        root: URL,
        fileManager: FileManager = .default,
        pathGuard: PathGuard = PathGuard(),
        secureFileMutation: SecureFileMutation = SecureFileMutation()
    ) {
        self.root = root
        self.journalURL = root.appendingPathComponent("trash-index.json")
        self.fileManager = fileManager
        self.pathGuard = pathGuard
        self.secureFileMutation = secureFileMutation
    }

    public func records() throws -> [TrashRecord] {
        var all = try loadRecords()
        guard fileManager.fileExists(atPath: root.path) else { return all }
        var journalChanged = false
        var removeIDs = Set<UUID>()

        for record in all {
            let trashURL = URL(fileURLWithPath: record.trashPath)
            let recordDirectory = trashURL.deletingLastPathComponent()
            let quarantine = root.appendingPathComponent(".purging-\(record.id.uuidString)", isDirectory: true)
            let original = URL(fileURLWithPath: record.originalPath)
            let recoveryAllowedRoot = record.allowedRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }

            if fileManager.fileExists(atPath: quarantine.path), !fileManager.fileExists(atPath: recordDirectory.path) {
                try secureFileMutation.moveItem(
                    from: quarantine,
                    sourceAllowedRoot: root,
                    to: recordDirectory,
                    destinationAllowedRoot: root,
                    createDestinationIntermediates: true
                )
            }

            let backups = ((try? fileManager.contentsOfDirectory(at: recordDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(".restore-overwrite-") }
            let sourceExists = fileManager.fileExists(atPath: trashURL.path)
            let targetExists = fileManager.fileExists(atPath: original.path)
            let expectedOriginalPath = original.standardizedFileURL.path
            let safeOriginal = recoveryAllowedRoot.flatMap { recoveryRoot -> URL? in
                guard let validated = try? pathGuard.validate(target: original, allowedRoot: recoveryRoot, rejectSymlink: true, fileManager: fileManager),
                      validated.path == expectedOriginalPath else { return nil }
                return validated
            }

            // Legacy records that predate allowedRoot persistence are never allowed to write back
            // into a user path during automatic recovery. They remain visible for explicit repair.
            if sourceExists, !targetExists, let backup = backups.first, let safeOriginal, let recoveryAllowedRoot {
                try secureFileMutation.moveItem(
                    from: backup,
                    sourceAllowedRoot: root,
                    to: safeOriginal,
                    destinationAllowedRoot: recoveryAllowedRoot,
                    createDestinationIntermediates: true
                )
                for extra in backups.dropFirst() { try? fileManager.removeItem(at: extra) }
                continue
            }

            if !sourceExists, targetExists, let backup = backups.first, let safeOriginal, let recoveryAllowedRoot {
                let targetMatchesTrash = Self.hashFileOrMetadata(url: safeOriginal, fileManager: fileManager) == record.hash
                if targetMatchesTrash {
                    try secureFileMutation.moveItem(
                        from: safeOriginal,
                        sourceAllowedRoot: recoveryAllowedRoot,
                        to: trashURL,
                        destinationAllowedRoot: root,
                        createDestinationIntermediates: true
                    )
                    try secureFileMutation.moveItem(
                        from: backup,
                        sourceAllowedRoot: root,
                        to: safeOriginal,
                        destinationAllowedRoot: recoveryAllowedRoot,
                        createDestinationIntermediates: true
                    )
                    for extra in backups.dropFirst() { try? fileManager.removeItem(at: extra) }
                }
                continue
            }

            if !sourceExists, !targetExists, let backup = backups.first, let safeOriginal, let recoveryAllowedRoot {
                try secureFileMutation.moveItem(
                    from: backup,
                    sourceAllowedRoot: root,
                    to: safeOriginal,
                    destinationAllowedRoot: recoveryAllowedRoot,
                    createDestinationIntermediates: true
                )
                for extra in backups.dropFirst() { try? fileManager.removeItem(at: extra) }
                removeIDs.insert(record.id)
                journalChanged = true
                continue
            }

            if !sourceExists, targetExists, backups.isEmpty, let safeOriginal,
               Self.hashFileOrMetadata(url: safeOriginal, fileManager: fileManager) == record.hash {
                removeIDs.insert(record.id)
                journalChanged = true
            }
        }

        if !removeIDs.isEmpty { all.removeAll { removeIDs.contains($0.id) } }
        let activeIDs = Set(all.map(\.id))
        let rootItems = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in rootItems where item.lastPathComponent.hasPrefix(".purging-") {
            let rawID = String(item.lastPathComponent.dropFirst(".purging-".count))
            if let id = UUID(uuidString: rawID), !activeIDs.contains(id) {
                try? fileManager.removeItem(at: item)
            }
        }

        if journalChanged { try writeRecords(all) }
        return all
    }

    private func loadRecords() throws -> [TrashRecord] {
        guard fileManager.fileExists(atPath: journalURL.path) else { return [] }
        let attributes = try fileManager.attributesOfItem(atPath: journalURL.path)
        guard let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        guard size.int64Value <= Self.maxJournalBytes else { throw TrashServiceError.oversizedJournal }
        let data = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TrashRecord].self, from: data)
    }

    public func moveToTrash(
        target: URL,
        logicalResourceID: String,
        sessionID: UUID,
        toolCallID: UUID,
        reason: String,
        sourceApp: String?,
        allowedRoot: URL? = nil,
        expectedResolvedTarget: URL? = nil,
        expectedSourceIdentity: SecureFileIdentity? = nil
    ) throws -> TrashRecord {
        var all = try records()
        if let existing = all.first(where: { $0.toolCallID == toolCallID }), fileManager.fileExists(atPath: existing.trashPath) {
            return existing
        }

        let safe = try pathGuard.validate(target: target, allowedRoot: allowedRoot, rejectSymlink: true, recursiveDelete: fileManager.directoryExists(at: target), fileManager: fileManager)
        if let expectedResolvedTarget, safe.path != expectedResolvedTarget.standardizedFileURL.path {
            throw PathSafetyError.targetChangedAfterApproval
        }
        let currentSourceIdentity = try secureFileMutation.identity(of: safe, allowedRoot: allowedRoot)
        if let expectedSourceIdentity, currentSourceIdentity != expectedSourceIdentity {
            throw PathSafetyError.targetChangedAfterApproval
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let identifier = UUID().uuidString
        let targetDirectory = root.appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let trashTarget = targetDirectory.appendingPathComponent(safe.lastPathComponent)

        let size = (try? fileManager.allocatedSizeOfItem(at: safe)) ?? 0
        let hash = Self.hashFileOrMetadata(url: safe, fileManager: fileManager)

        let record = TrashRecord(
            originalPath: safe.path,
            logicalResourceID: logicalResourceID,
            trashPath: trashTarget.path,
            filename: safe.lastPathComponent,
            size: size,
            hash: hash,
            sessionID: sessionID,
            toolCallID: toolCallID,
            reason: reason,
            sourceApp: sourceApp,
            allowedRootPath: allowedRoot?.standardizedFileURL.resolvingSymlinksInPath().path ?? "/"
        )
        all.append(record)
        try writeRecords(all)
        do {
            try secureFileMutation.moveItem(
                from: safe,
                sourceAllowedRoot: allowedRoot,
                to: trashTarget,
                destinationAllowedRoot: root,
                createDestinationIntermediates: true,
                expectedSourceIdentity: currentSourceIdentity
            )
            return record
        } catch {
            all.removeAll(where: { $0.id == record.id })
            try? writeRecords(all)
            try? fileManager.removeItem(at: targetDirectory)
            throw error
        }
    }

    public func restore(
        _ id: UUID,
        overwrite: Bool = false,
        allowedRoot: URL? = nil,
        expectedResolvedTarget: URL? = nil,
        expectedDestinationParentIdentity: SecureFileIdentity? = nil
    ) throws -> TrashRecord {
        var all = try records()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let record = all[index]
        let source = URL(fileURLWithPath: record.trashPath)
        let sourceIdentity = try secureFileMutation.identity(of: source, allowedRoot: root)
        let target = try pathGuard.validate(
            target: URL(fileURLWithPath: record.originalPath),
            allowedRoot: allowedRoot,
            rejectSymlink: true,
            fileManager: fileManager
        )
        if let expectedResolvedTarget,
           target.path != expectedResolvedTarget.standardizedFileURL.path {
            throw PathSafetyError.targetChangedAfterApproval
        }

        var overwrittenBackup: URL?
        var overwrittenIdentity: SecureFileIdentity?
        if fileManager.fileExists(atPath: target.path) {
            guard overwrite else { throw CocoaError(.fileWriteFileExists) }
            let targetIdentity = try secureFileMutation.identity(of: target, allowedRoot: allowedRoot)
            let backup = source.deletingLastPathComponent().appendingPathComponent(".restore-overwrite-\(UUID().uuidString)")
            try secureFileMutation.moveItem(
                from: target,
                sourceAllowedRoot: allowedRoot,
                to: backup,
                destinationAllowedRoot: root,
                createDestinationIntermediates: true,
                expectedSourceIdentity: targetIdentity
            )
            overwrittenBackup = backup
            overwrittenIdentity = targetIdentity
        }
        do {
            try secureFileMutation.moveItem(
                from: source,
                sourceAllowedRoot: root,
                to: target,
                destinationAllowedRoot: allowedRoot,
                createDestinationIntermediates: true,
                expectedSourceIdentity: sourceIdentity,
                expectedDestinationParentIdentity: expectedDestinationParentIdentity
            )
        } catch {
            if let overwrittenBackup, fileManager.fileExists(atPath: overwrittenBackup.path) {
                try? secureFileMutation.moveItem(
                    from: overwrittenBackup,
                    sourceAllowedRoot: root,
                    to: target,
                    destinationAllowedRoot: allowedRoot,
                    createDestinationIntermediates: true,
                    expectedSourceIdentity: overwrittenIdentity
                )
            }
            throw error
        }
        all.remove(at: index)
        do {
            try writeRecords(all)
            if let overwrittenBackup { try? fileManager.removeItem(at: overwrittenBackup) }
            return record
        } catch {
            if fileManager.fileExists(atPath: target.path), !fileManager.fileExists(atPath: source.path) {
                try? secureFileMutation.moveItem(
                    from: target,
                    sourceAllowedRoot: allowedRoot,
                    to: source,
                    destinationAllowedRoot: root,
                    createDestinationIntermediates: true,
                    expectedSourceIdentity: sourceIdentity
                )
            }
            if let overwrittenBackup, fileManager.fileExists(atPath: overwrittenBackup.path), !fileManager.fileExists(atPath: target.path) {
                try? secureFileMutation.moveItem(
                    from: overwrittenBackup,
                    sourceAllowedRoot: root,
                    to: target,
                    destinationAllowedRoot: allowedRoot,
                    createDestinationIntermediates: true,
                    expectedSourceIdentity: overwrittenIdentity
                )
            }
            throw error
        }
    }

    public func verifyTrashed(_ record: TrashRecord) -> Bool {
        let target = URL(fileURLWithPath: record.trashPath)
        guard fileManager.fileExists(atPath: target.path) else { return false }
        return Self.hashFileOrMetadata(url: target, fileManager: fileManager) == record.hash
    }

    public func verifyRestored(_ record: TrashRecord) -> Bool {
        let target = URL(fileURLWithPath: record.originalPath)
        guard fileManager.fileExists(atPath: target.path) else { return false }
        return Self.hashFileOrMetadata(url: target, fileManager: fileManager) == record.hash
    }

    public func permanentlyDelete(_ id: UUID) throws {
        var all = try records()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let record = all[index]
        let trashURL = URL(fileURLWithPath: record.trashPath)
        let recordDirectory = trashURL.deletingLastPathComponent()
        let quarantine = root.appendingPathComponent(".purging-\(id.uuidString)", isDirectory: true)

        if fileManager.fileExists(atPath: quarantine.path) { try fileManager.removeItem(at: quarantine) }
        var quarantinedIdentity: SecureFileIdentity?
        if fileManager.fileExists(atPath: recordDirectory.path) {
            let recordDirectoryIdentity = try secureFileMutation.identity(of: recordDirectory, allowedRoot: root)
            try secureFileMutation.moveItem(
                from: recordDirectory,
                sourceAllowedRoot: root,
                to: quarantine,
                destinationAllowedRoot: root,
                createDestinationIntermediates: true,
                expectedSourceIdentity: recordDirectoryIdentity
            )
            quarantinedIdentity = recordDirectoryIdentity
        }

        all.remove(at: index)
        do {
            try writeRecords(all)
        } catch {
            if fileManager.fileExists(atPath: quarantine.path), !fileManager.fileExists(atPath: recordDirectory.path) {
                try? secureFileMutation.moveItem(
                    from: quarantine,
                    sourceAllowedRoot: root,
                    to: recordDirectory,
                    destinationAllowedRoot: root,
                    createDestinationIntermediates: true,
                    expectedSourceIdentity: quarantinedIdentity
                )
            }
            throw error
        }

        if fileManager.fileExists(atPath: quarantine.path) {
            try fileManager.removeItem(at: quarantine)
        }
    }

    private func writeRecords(_ records: [TrashRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: journalURL, options: .atomic)
    }

    private static func hashFileOrMetadata(url: URL, fileManager: FileManager) -> String {
        #if canImport(CryptoKit)
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        #endif
        let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
        let seed = "\(url.lastPathComponent)|\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? Date.distantPast)"
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return String(seed.hashValue)
        #endif
    }
}

public enum DocumentInspectionError: Error, Equatable {
    case notRegularFile
    case unsupportedType(String)
    case invalidArchive
    case missingWordDocument
    case entryTooLarge(String)
    case fileTooLarge(Int64)
}

public struct DocumentInspection: Codable, Equatable, Sendable {
    public var kind: String
    public var filename: String
    public var byteSize: Int64
    public var text: String
    public var entries: [String]
    public var truncated: Bool
    public var detail: String

    public init(kind: String, filename: String, byteSize: Int64, text: String = "", entries: [String] = [], truncated: Bool = false, detail: String) {
        self.kind = kind
        self.filename = filename
        self.byteSize = byteSize
        self.text = text
        self.entries = entries
        self.truncated = truncated
        self.detail = detail
    }
}

/// Bounded local inspection for common user documents. Binary files are understood locally first;
/// only extracted text or metadata is exposed to the Agent instead of uploading the whole file.
public struct DocumentInspectionService: Sendable {
    private let maxFileBytes: Int64 = 128 * 1024 * 1024
    private let maxExtractedEntryBytes: UInt32 = 4 * 1024 * 1024
    private let maxTextCharacters = 100_000
    private let maxArchiveEntries = 400

    public init() {}

    public func inspect(_ url: URL, allowedRoot: URL? = nil) throws -> DocumentInspection {
        let safe = try PathGuard().validate(target: url, allowedRoot: allowedRoot, rejectSymlink: true)
        let values = try safe.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw DocumentInspectionError.notRegularFile }
        let size = Int64(values.fileSize ?? 0)
        guard size <= maxFileBytes else { throw DocumentInspectionError.fileTooLarge(size) }
        let ext = safe.pathExtension.lowercased()

        switch ext {
        case "docx": return try inspectDOCX(safe, size: size)
        case "zip": return try inspectZIP(safe, size: size)
        case "pdf": return try inspectPDF(safe, size: size)
        case "txt", "md", "markdown", "csv", "json", "xml", "html", "htm", "log", "rtf":
            return try inspectText(safe, size: size, kind: ext.isEmpty ? "text" : ext)
        default:
            throw DocumentInspectionError.unsupportedType(ext.isEmpty ? "unknown" : ext)
        }
    }

    private func inspectText(_ url: URL, size: Int64, kind: String) throws -> DocumentInspection {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let prefix = data.prefix(2 * 1024 * 1024)
        let decoded = String(data: prefix, encoding: .utf8)
            ?? String(data: prefix, encoding: .utf16)
            ?? ""
        let bounded = boundedText(decoded)
        return DocumentInspection(
            kind: kind,
            filename: url.lastPathComponent,
            byteSize: size,
            text: bounded.text,
            truncated: bounded.truncated || data.count > 2 * 1024 * 1024,
            detail: "Bounded local text inspection"
        )
    }

    private func inspectZIP(_ url: URL, size: Int64) throws -> DocumentInspection {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw DocumentInspectionError.invalidArchive }
        let entries = Array(archive.prefix(maxArchiveEntries + 1))
        let truncated = entries.count > maxArchiveEntries
        let names = entries.prefix(maxArchiveEntries).map { "\($0.path)\t\($0.uncompressedSize)" }
        return DocumentInspection(
            kind: "zip",
            filename: url.lastPathComponent,
            byteSize: size,
            entries: names,
            truncated: truncated,
            detail: "ZIP directory inspected locally; entry paths and uncompressed sizes are bounded"
        )
    }

    private func inspectDOCX(_ url: URL, size: Int64) throws -> DocumentInspection {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw DocumentInspectionError.invalidArchive }
        guard let entry = archive["word/document.xml"] else { throw DocumentInspectionError.missingWordDocument }
        guard entry.uncompressedSize <= maxExtractedEntryBytes else {
            throw DocumentInspectionError.entryTooLarge(entry.path)
        }
        var xmlData = Data()
        _ = try archive.extract(entry) { xmlData.append($0) }
        let bounded = boundedText(extractWordXMLText(String(data: xmlData, encoding: .utf8) ?? ""))
        return DocumentInspection(
            kind: "docx",
            filename: url.lastPathComponent,
            byteSize: size,
            text: bounded.text,
            truncated: bounded.truncated,
            detail: "DOCX word/document.xml extracted locally with ZIPFoundation"
        )
    }

    private func inspectPDF(_ url: URL, size: Int64) throws -> DocumentInspection {
#if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw DocumentInspectionError.unsupportedType("pdf_unreadable")
        }
        let pageLimit = min(document.pageCount, 30)
        var parts: [String] = []
        var count = 0
        var truncated = document.pageCount > pageLimit
        for index in 0..<pageLimit {
            guard let pageText = document.page(at: index)?.string, !pageText.isEmpty else { continue }
            let remaining = maxTextCharacters - count
            if remaining <= 0 { truncated = true; break }
            let boundedPage = String(pageText.prefix(remaining))
            parts.append("[Page \(index + 1)]\n\(boundedPage)")
            count += boundedPage.count
            if boundedPage.count < pageText.count { truncated = true; break }
        }
        return DocumentInspection(
            kind: "pdf",
            filename: url.lastPathComponent,
            byteSize: size,
            text: parts.joined(separator: "\n\n"),
            truncated: truncated,
            detail: "PDFKit local text extraction; pages=\(document.pageCount), inspected=\(pageLimit)"
        )
#else
        throw DocumentInspectionError.unsupportedType("pdf_runtime_unavailable")
#endif
    }

    private func boundedText(_ text: String) -> (text: String, truncated: Bool) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let bounded = String(normalized.prefix(maxTextCharacters))
        return (bounded, bounded.count < normalized.count)
    }

    private func extractWordXMLText(_ xml: String) -> String {
        guard !xml.isEmpty else { return "" }
        let normalized = xml
            .replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "<w:tab/>", with: "\t")
            .replacingOccurrences(of: "<w:br/>", with: "\n")
        let pattern = #"<w:t(?:\s[^>]*)?>(.*?)</w:t>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return "" }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        var pieces: [String] = []
        for match in regex.matches(in: normalized, options: [], range: range) {
            guard let capture = Range(match.range(at: 1), in: normalized) else { continue }
            pieces.append(decodeXML(String(normalized[capture])))
            if pieces.reduce(0, { $0 + $1.count }) >= maxTextCharacters { break }
        }
        return pieces.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

public extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
