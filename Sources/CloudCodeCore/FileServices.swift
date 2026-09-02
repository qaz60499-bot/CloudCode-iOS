import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public actor AuditLogStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let fileManager: FileManager

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
}

public actor AppKnowledgeRegistry {
    private let fileURL: URL
    private var entries: [String: AppKnowledge] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: AppKnowledge].self, from: data) {
            self.entries = decoded
        }
    }

    public func all() -> [AppKnowledge] {
        entries.values.sorted { lhs, rhs in
            if lhs.estimatedCost == rhs.estimatedCost { return lhs.successRate > rhs.successRate }
            return lhs.estimatedCost < rhs.estimatedCost
        }
    }

    public func knowledge(for bundleID: String) -> AppKnowledge? { entries[bundleID] }

    public func upsert(_ value: AppKnowledge) throws {
        entries[value.bundleID] = value
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(entries)
        try data.write(to: fileURL, options: .atomic)
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
    public var maxDepth: Int
    public var maxResults: Int

    public init(nameContains: String? = nil, extensions: Set<String> = [], maxDepth: Int = 4, maxResults: Int = 500) {
        self.nameContains = nameContains
        self.extensions = extensions
        self.maxDepth = maxDepth
        self.maxResults = maxResults
    }
}

public struct FileService: @unchecked Sendable {
    public let fileManager: FileManager
    public let pathGuard: PathGuard

    public init(fileManager: FileManager = .default, pathGuard: PathGuard = PathGuard()) {
        self.fileManager = fileManager
        self.pathGuard = pathGuard
    }

    public func list(directory: URL, allowedRoot: URL? = nil) throws -> [FileEntry] {
        let safe = try pathGuard.validate(target: directory, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let urls = try fileManager.contentsOfDirectory(at: safe, includingPropertiesForKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        return urls.compactMap(entry(for:)).sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func search(root: URL, query: FileSearchQuery, allowedRoot: URL? = nil) throws -> [FileEntry] {
        let safe = try pathGuard.validate(target: root, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let baseDepth = safe.pathComponents.count
        guard let enumerator = fileManager.enumerator(at: safe, includingPropertiesForKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [FileEntry] = []

        for case let url as URL in enumerator {
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
            results.append(item)
            if results.count >= query.maxResults { break }
        }
        return results
    }

    public func analyzeStorage(root: URL, allowedRoot: URL? = nil, top: Int = 50) throws -> [FileEntry] {
        var query = FileSearchQuery(maxDepth: 16, maxResults: 20_000)
        query.extensions = []
        let files = try search(root: root, query: query, allowedRoot: allowedRoot).filter { !$0.isDirectory }
        return files.sorted { $0.size > $1.size }.prefix(top).map { $0 }
    }

    public func readText(_ url: URL, allowedRoot: URL? = nil, maxBytes: Int = 1_000_000) throws -> String {
        let safe = try pathGuard.validate(target: url, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let data = try Data(contentsOf: safe, options: [.mappedIfSafe])
        let slice = data.prefix(maxBytes)
        guard let value = String(data: slice, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return value
    }

    private func entry(for url: URL) -> FileEntry? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]) else { return nil }
        let isDirectory = values.isDirectory == true
        let size = isDirectory ? (try? fileManager.allocatedSizeOfItem(at: url)) ?? 0 : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        return FileEntry(path: url.path, name: url.lastPathComponent, isDirectory: isDirectory, size: size, modificationDate: values.contentModificationDate)
    }
}

public actor TrashService {
    private let root: URL
    private let journalURL: URL
    private let fileManager: FileManager
    private let pathGuard: PathGuard

    public init(root: URL, fileManager: FileManager = .default, pathGuard: PathGuard = PathGuard()) {
        self.root = root
        self.journalURL = root.appendingPathComponent("trash-index.json")
        self.fileManager = fileManager
        self.pathGuard = pathGuard
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

            if fileManager.fileExists(atPath: quarantine.path), !fileManager.fileExists(atPath: recordDirectory.path) {
                try fileManager.moveItem(at: quarantine, to: recordDirectory)
            }

            let backups = ((try? fileManager.contentsOfDirectory(at: recordDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(".restore-overwrite-") }
            let sourceExists = fileManager.fileExists(atPath: trashURL.path)
            let targetExists = fileManager.fileExists(atPath: original.path)

            if sourceExists, !targetExists, let backup = backups.first {
                try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: backup, to: original)
                for extra in backups.dropFirst() { try? fileManager.removeItem(at: extra) }
                continue
            }

            if !sourceExists, targetExists, let backup = backups.first {
                let targetMatchesTrash = Self.hashFileOrMetadata(url: original, fileManager: fileManager) == record.hash
                if targetMatchesTrash {
                    try fileManager.createDirectory(at: trashURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: original, to: trashURL)
                    try fileManager.moveItem(at: backup, to: original)
                    for extra in backups.dropFirst() { try? fileManager.removeItem(at: extra) }
                }
                continue
            }

            if !sourceExists, !targetExists, let backup = backups.first {
                try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: backup, to: original)
                for extra in backups.dropFirst() { try? fileManager.removeItem(at: extra) }
                removeIDs.insert(record.id)
                journalChanged = true
                continue
            }

            if !sourceExists, targetExists, backups.isEmpty,
               Self.hashFileOrMetadata(url: original, fileManager: fileManager) == record.hash {
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
        let data = try Data(contentsOf: journalURL)
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
        allowedRoot: URL? = nil
    ) throws -> TrashRecord {
        var all = try records()
        if let existing = all.first(where: { $0.toolCallID == toolCallID }), fileManager.fileExists(atPath: existing.trashPath) {
            return existing
        }

        let safe = try pathGuard.validate(target: target, allowedRoot: allowedRoot, rejectSymlink: true, recursiveDelete: fileManager.directoryExists(at: target), fileManager: fileManager)
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
            sourceApp: sourceApp
        )
        all.append(record)
        try writeRecords(all)
        do {
            try fileManager.moveItem(at: safe, to: trashTarget)
            return record
        } catch {
            all.removeAll(where: { $0.id == record.id })
            try? writeRecords(all)
            try? fileManager.removeItem(at: targetDirectory)
            throw error
        }
    }

    public func restore(_ id: UUID, overwrite: Bool = false) throws -> TrashRecord {
        var all = try records()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let record = all[index]
        let source = URL(fileURLWithPath: record.trashPath)
        let target = URL(fileURLWithPath: record.originalPath)

        var overwrittenBackup: URL?
        if fileManager.fileExists(atPath: target.path) {
            guard overwrite else { throw CocoaError(.fileWriteFileExists) }
            let backup = source.deletingLastPathComponent().appendingPathComponent(".restore-overwrite-\(UUID().uuidString)")
            try fileManager.moveItem(at: target, to: backup)
            overwrittenBackup = backup
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            if let overwrittenBackup, fileManager.fileExists(atPath: overwrittenBackup.path) {
                try? fileManager.moveItem(at: overwrittenBackup, to: target)
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
                try? fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.moveItem(at: target, to: source)
            }
            if let overwrittenBackup, fileManager.fileExists(atPath: overwrittenBackup.path), !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: overwrittenBackup, to: target)
            }
            throw error
        }
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
        if fileManager.fileExists(atPath: recordDirectory.path) {
            try fileManager.moveItem(at: recordDirectory, to: quarantine)
        }

        all.remove(at: index)
        do {
            try writeRecords(all)
        } catch {
            if fileManager.fileExists(atPath: quarantine.path), !fileManager.fileExists(atPath: recordDirectory.path) {
                try? fileManager.moveItem(at: quarantine, to: recordDirectory)
            }
            throw error
        }

        try? fileManager.removeItem(at: quarantine)
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

public extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
