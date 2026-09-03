import Foundation
import ZIPFoundation

public enum DiagnosticLogLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct DiagnosticLogRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var sessionID: UUID?
    public var toolCallID: UUID?
    public var level: DiagnosticLogLevel
    public var subsystem: String
    public var action: String
    public var result: String
    public var errorDomain: String?
    public var errorCode: Int?
    public var diagnostic: String?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID? = nil,
        toolCallID: UUID? = nil,
        level: DiagnosticLogLevel,
        subsystem: String,
        action: String,
        result: String,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        diagnostic: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.level = level
        self.subsystem = subsystem
        self.action = action
        self.result = result
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.diagnostic = diagnostic
        self.metadata = metadata
    }
}

public enum DiagnosticContext {
    @TaskLocal public static var sessionID: UUID?
    @TaskLocal public static var toolCallID: UUID?
}

public enum DiagnosticRedactor {
    private static let sensitiveKeyFragments = [
        "authorization", "api_key", "apikey", "api-key", "token", "cookie", "secret", "password", "credential", "x-api-key"
    ]

    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"(?i)\bBearer\s+[A-Za-z0-9._~+\-/=]{8,}"#,
            #"(?i)\bsk-[A-Za-z0-9_-]{12,}"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)(authorization|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|cookie|secret|password)\s*[:=]\s*[^\s,;\}\]]+"#,
            #"(?i)\"(authorization|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|cookie|secret|password)\"\s*:\s*\"[^\"]*\""#,
            #"(?i)([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|auth)=)[^&#\s]+"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static func redact(_ value: String) -> String {
        var output = value
        for regex in patterns {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "<redacted>")
        }
        return output
    }

    public static func redact(metadata: [String: String]) -> [String: String] {
        var safe: [String: String] = [:]
        for (key, value) in metadata {
            let normalized = key.lowercased()
            if sensitiveKeyFragments.contains(where: { normalized.contains($0) }) {
                safe[key] = "<redacted>"
            } else {
                safe[key] = redact(value)
            }
        }
        return safe
    }

    public static func redact(record: DiagnosticLogRecord) -> DiagnosticLogRecord {
        var safe = record
        safe.subsystem = truncated(redact(safe.subsystem), limit: 256)
        safe.action = truncated(redact(safe.action), limit: 512)
        safe.result = truncated(redact(safe.result), limit: 512)
        safe.errorDomain = safe.errorDomain.map { truncated(redact($0), limit: 256) }
        safe.diagnostic = safe.diagnostic.map { truncated(redact($0), limit: 32 * 1024) }
        let redactedMetadata = redact(metadata: safe.metadata)
        var boundedMetadata: [String: String] = [:]
        for key in redactedMetadata.keys.sorted().prefix(64) {
            boundedMetadata[truncated(key, limit: 256)] = truncated(redactedMetadata[key] ?? "", limit: 8 * 1024)
        }
        safe.metadata = boundedMetadata
        return safe
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…<truncated>"
    }

    public static func redact(data: Data) -> Data {
        if let object = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(object),
           let encoded = try? JSONSerialization.data(withJSONObject: redactJSONObject(object), options: [.prettyPrinted, .sortedKeys]) {
            return encoded
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return Data("<non-text diagnostic source omitted>".utf8)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            var output: [String] = []
            output.reserveCapacity(lines.count)
            var parsedAnyJSON = false
            for rawLine in lines {
                let line = String(rawLine)
                guard !line.isEmpty else {
                    output.append("")
                    continue
                }
                if let lineData = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: lineData),
                   JSONSerialization.isValidJSONObject(object),
                   let encoded = try? JSONSerialization.data(withJSONObject: redactJSONObject(object), options: [.sortedKeys]),
                   let safeLine = String(data: encoded, encoding: .utf8) {
                    parsedAnyJSON = true
                    output.append(safeLine)
                } else {
                    output.append(redact(line))
                }
            }
            if parsedAnyJSON { return Data(output.joined(separator: "\n").utf8) }
        }
        return Data(redact(text).utf8)
    }

    private static func redactJSONObject(_ value: Any, key: String? = nil) -> Any {
        if let key {
            let normalized = key.lowercased()
            if sensitiveKeyFragments.contains(where: { normalized.contains($0) }) {
                return "<redacted>"
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { partial, entry in
                partial[entry.key] = redactJSONObject(entry.value, key: entry.key)
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSONObject($0) }
        }
        if let string = value as? String {
            return redact(string)
        }
        return value
    }
}

public actor DiagnosticLogStore {
    public struct Policy: Sendable, Equatable {
        public var retentionSeconds: TimeInterval
        public var maxTotalBytes: Int64
        public var maxFileBytes: Int64

        public init(
            retentionSeconds: TimeInterval = 72 * 60 * 60,
            maxTotalBytes: Int64 = 100 * 1024 * 1024,
            maxFileBytes: Int64 = 8 * 1024 * 1024
        ) {
            self.retentionSeconds = max(60, retentionSeconds)
            self.maxTotalBytes = max(1024 * 1024, maxTotalBytes)
            self.maxFileBytes = max(256 * 1024, min(maxFileBytes, self.maxTotalBytes))
        }
    }

    private let directory: URL
    private let policy: Policy
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var lastCleanupAt: Date?

    public init(directory: URL, policy: Policy = Policy(), fileManager: FileManager = .default) {
        self.directory = directory
        self.policy = policy
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ record: DiagnosticLogRecord) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = DiagnosticRedactor.redact(record: record)
        let url = try activeLogURL(at: safe.timestamp)
        var line = try encoder.encode(safe)
        line.append(0x0A)
        if !fileManager.fileExists(atPath: url.path) {
            try line.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
        if lastCleanupAt == nil || Date().timeIntervalSince(lastCleanupAt ?? .distantPast) >= 60 {
            try cleanup(now: Date())
        }
    }

    public func log(
        level: DiagnosticLogLevel,
        subsystem: String,
        action: String,
        result: String,
        sessionID: UUID? = DiagnosticContext.sessionID,
        toolCallID: UUID? = DiagnosticContext.toolCallID,
        error: Error? = nil,
        diagnostic: String? = nil,
        metadata: [String: String] = [:]
    ) throws {
        let nsError = error.map { $0 as NSError }
        try append(DiagnosticLogRecord(
            sessionID: sessionID,
            toolCallID: toolCallID,
            level: level,
            subsystem: subsystem,
            action: action,
            result: result,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            diagnostic: diagnostic ?? error.map { String(describing: $0) },
            metadata: metadata
        ))
    }

    public func readAll(limit: Int = 10_000) throws -> [DiagnosticLogRecord] {
        try readNewest(sessionID: nil, limit: limit)
    }

    public func recent(sessionID: UUID?, limit: Int = 1_500) throws -> [DiagnosticLogRecord] {
        try readNewest(sessionID: sessionID, limit: max(1, limit))
    }

    private func readNewest(sessionID: UUID?, limit: Int) throws -> [DiagnosticLogRecord] {
        try cleanup(now: Date())
        let bounded = limit > 0 ? limit : Int.max
        let urls = try logFileURLs().sorted { $0.lastPathComponent > $1.lastPathComponent }
        var records: [DiagnosticLogRecord] = []
        records.reserveCapacity(min(bounded, 12_000))
        outer: for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                guard let decoded = try? decoder.decode(DiagnosticLogRecord.self, from: Data(line)) else { continue }
                let safe = DiagnosticRedactor.redact(record: decoded)
                if let sessionID, safe.sessionID != sessionID { continue }
                records.append(safe)
                if records.count >= bounded { break outer }
            }
        }
        return records.sorted { $0.timestamp < $1.timestamp }
    }

    public func text(sessionID: UUID? = nil, limit: Int = 1_500) throws -> String {
        let records = try recent(sessionID: sessionID, limit: limit)
        return try records.map { record in
            let safe = DiagnosticRedactor.redact(record: record)
            return String(data: try encoder.encode(safe), encoding: .utf8) ?? ""
        }.joined(separator: "\n")
    }

    public func snapshotForExport(to destinationDirectory: URL) throws {
        try cleanup(now: Date())
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let urls = try logFileURLs().sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let safe = DiagnosticRedactor.redact(data: data)
            try safe.write(to: destinationDirectory.appendingPathComponent(url.lastPathComponent), options: .atomic)
        }
    }

    public func cleanup(now: Date = Date()) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = now.addingTimeInterval(-policy.retentionSeconds)
        var files = try logFileURLsWithMetadata()
        for file in files where file.modifiedAt < cutoff {
            try? fileManager.removeItem(at: file.url)
        }

        files = try logFileURLsWithMetadata().sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt { return lhs.url.lastPathComponent < rhs.url.lastPathComponent }
            return lhs.modifiedAt < rhs.modifiedAt
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        for file in files where total > policy.maxTotalBytes {
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.size
            } catch {
                continue
            }
        }
        lastCleanupAt = now
    }

    public func totalBytes() throws -> Int64 {
        try cleanup(now: Date())
        return try logFileURLsWithMetadata().reduce(Int64(0)) { $0 + $1.size }
    }

    private func activeLogURL(at date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HH"
        let prefix = "runtime-\(formatter.string(from: date))-"

        let candidates = (try? logFileURLs())?.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        if let last = candidates.last,
           let attrs = try? fileManager.attributesOfItem(atPath: last.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value,
           size < policy.maxFileBytes {
            return last
        }
        let nextIndex: Int
        if let last = candidates.last {
            let stem = last.deletingPathExtension().lastPathComponent
            nextIndex = (Int(stem.split(separator: "-").last ?? "-1") ?? -1) + 1
        } else {
            nextIndex = 0
        }
        return directory.appendingPathComponent(String(format: "%@%03d.jsonl", prefix, nextIndex))
    }

    private func logFileURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("runtime-") }
    }

    private func logFileURLsWithMetadata() throws -> [(url: URL, modifiedAt: Date, size: Int64)] {
        try logFileURLs().compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let logicalDate = Self.logicalDate(from: url.lastPathComponent)
            return (url, logicalDate ?? values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
        }
    }

    private static func logicalDate(from filename: String) -> Date? {
        guard filename.hasPrefix("runtime-"), filename.count >= 19 else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: 8)
        let end = filename.index(start, offsetBy: 11)
        let value = String(filename[start..<end])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HH"
        return formatter.date(from: value)
    }
}

public struct DiagnosticBundleSource: Sendable {
    public var archivePath: String
    public var fileURL: URL

    public init(archivePath: String, fileURL: URL) {
        self.archivePath = archivePath
        self.fileURL = fileURL
    }
}

public actor DiagnosticBundleExporter {
    private let logStore: DiagnosticLogStore
    private let fileManager: FileManager

    public init(logStore: DiagnosticLogStore, fileManager: FileManager = .default) {
        self.logStore = logStore
        self.fileManager = fileManager
    }

    public func export(
        destinationDirectory: URL,
        sources: [DiagnosticBundleSource],
        generatedFiles: [String: Data]
    ) async throws -> URL {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let working = destinationDirectory.appendingPathComponent(".diagnostic-\(identifier)", isDirectory: true)
        let output = destinationDirectory.appendingPathComponent("CloudCode-Diagnostics-\(identifier).zip")
        if fileManager.fileExists(atPath: working.path) { try fileManager.removeItem(at: working) }
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        try fileManager.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: working) }

        let runtimeDirectory = working.appendingPathComponent("runtime", isDirectory: true)
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try await logStore.snapshotForExport(to: runtimeDirectory)

        for source in sources {
            guard fileManager.fileExists(atPath: source.fileURL.path),
                  let data = try? Data(contentsOf: source.fileURL) else { continue }
            let target = working.appendingPathComponent(source.archivePath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DiagnosticRedactor.redact(data: data).write(to: target, options: .atomic)
        }

        for (path, data) in generatedFiles {
            let target = working.appendingPathComponent(path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DiagnosticRedactor.redact(data: data).write(to: target, options: .atomic)
        }

        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "redacted": true,
            "localOnly": true,
            "retentionHours": 72,
            "logCapacityBytes": 100 * 1024 * 1024
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: working.appendingPathComponent("manifest.json"), options: .atomic)

        try Self.createArchive(from: working, to: output, fileManager: fileManager)
        return output
    }

    private static func createArchive(from working: URL, to output: URL, fileManager: FileManager) throws {
        let archive = try Archive(url: output, accessMode: .create)
        let root = working.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            throw CocoaError(.fileReadUnknown)
        }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let rawItem as URL in enumerator {
            let item = rawItem.standardizedFileURL.resolvingSymlinksInPath()
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, item.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(item.path.dropFirst(rootPrefix.count))
            guard !relative.isEmpty, !relative.contains("../") else { continue }
            try archive.addEntry(with: relative, fileURL: item, compressionMethod: .deflate)
        }
    }
}
