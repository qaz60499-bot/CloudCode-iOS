import Foundation

public struct StartupBreadcrumbEntry: Codable, Equatable, Sendable {
    public var runID: UUID
    public var timestamp: Date
    public var stage: String

    public init(runID: UUID, timestamp: Date = Date(), stage: String) {
        self.runID = runID
        self.timestamp = timestamp
        self.stage = stage
    }
}

public struct StartupBreadcrumbRunSummary: Equatable, Sendable {
    public var runID: UUID
    public var startedAt: Date
    public var lastTimestamp: Date
    public var lastStage: String
    public var entryCount: Int

    public init(runID: UUID, startedAt: Date, lastTimestamp: Date, lastStage: String, entryCount: Int) {
        self.runID = runID
        self.startedAt = startedAt
        self.lastTimestamp = lastTimestamp
        self.lastStage = lastStage
        self.entryCount = entryCount
    }
}

/// Minimal crash-survivable startup tracing that intentionally does not depend on
/// DiagnosticLogStore, Keychain, Hermes, private APIs, or any cross-container path.
/// Every launch gets its own tiny JSONL file so the next launch can report the last
/// stage reached by the previous process even when the previous process terminated
/// before the normal diagnostics stack was ready.
public struct StartupBreadcrumbStore: Sendable {
    private let directory: URL
    private let fileManager: FileManager
    private let retainedRunCount: Int

    public init(
        directory: URL = StartupBreadcrumbStore.defaultDirectory(),
        fileManager: FileManager = .default,
        retainedRunCount: Int = 8
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.retainedRunCount = max(2, retainedRunCount)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("CloudCode", isDirectory: true)
            .appendingPathComponent("StartupBreadcrumbs", isDirectory: true)
    }

    @discardableResult
    public func beginRun(initialStage: String = "app.main.enter", at timestamp: Date = Date()) -> UUID {
        let runID = UUID()
        append(runID: runID, stage: initialStage, at: timestamp)
        pruneOldRuns(keeping: runID)
        return runID
    }

    public func append(runID: UUID, stage: String, at timestamp: Date = Date()) {
        let boundedStage = Self.sanitizeStage(stage)
        guard !boundedStage.isEmpty else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(for: runID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(StartupBreadcrumbEntry(runID: runID, timestamp: timestamp, stage: boundedStage))
            line.append(0x0A)
            if !fileManager.fileExists(atPath: url.path) {
                try line.write(to: url, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try? handle.synchronize()
            }
        } catch {
            // Startup breadcrumbs are best-effort by design. A logging failure must
            // never prevent the app from presenting its first scene.
        }
    }

    public func previousRun(excluding runID: UUID) -> StartupBreadcrumbRunSummary? {
        recentRuns(limit: retainedRunCount + 1).first { $0.runID != runID }
    }

    public func recentRuns(limit: Int = 8) -> [StartupBreadcrumbRunSummary] {
        guard limit > 0,
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        let summaries = urls.compactMap(summary(for:))
        return Array(summaries.sorted { lhs, rhs in
            if lhs.lastTimestamp == rhs.lastTimestamp { return lhs.runID.uuidString > rhs.runID.uuidString }
            return lhs.lastTimestamp > rhs.lastTimestamp
        }.prefix(limit))
    }

    public func exportText(limitRuns: Int = 8) -> String {
        recentRuns(limit: limitRuns).map { summary in
            "run=\(summary.runID.uuidString) started=\(Self.iso8601(summary.startedAt)) last=\(Self.iso8601(summary.lastTimestamp)) stage=\(summary.lastStage) entries=\(summary.entryCount)"
        }.joined(separator: "\n")
    }

    private func summary(for url: URL) -> StartupBreadcrumbRunSummary? {
        guard url.pathExtension == "jsonl",
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw -> StartupBreadcrumbEntry? in
            guard let line = String(raw).data(using: .utf8) else { return nil }
            return try? decoder.decode(StartupBreadcrumbEntry.self, from: line)
        }
        guard let first = entries.first, let last = entries.last else { return nil }
        return StartupBreadcrumbRunSummary(
            runID: first.runID,
            startedAt: first.timestamp,
            lastTimestamp: last.timestamp,
            lastStage: last.stage,
            entryCount: entries.count
        )
    }

    private func pruneOldRuns(keeping currentRunID: UUID) {
        let summaries = recentRuns(limit: Int.max)
        guard summaries.count > retainedRunCount else { return }
        for summary in summaries.dropFirst(retainedRunCount) where summary.runID != currentRunID {
            try? fileManager.removeItem(at: fileURL(for: summary.runID))
        }
    }

    private func fileURL(for runID: UUID) -> URL {
        directory.appendingPathComponent("run-\(runID.uuidString).jsonl", isDirectory: false)
    }

    private static func sanitizeStage(_ stage: String) -> String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let allowed = trimmed.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar)
        }
        return String(allowed.map(String.init).joined().prefix(160))
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
