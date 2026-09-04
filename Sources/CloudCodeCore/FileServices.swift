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

    public func exportSnapshotData() throws -> Data {
        guard fileManager.fileExists(atPath: fileURL.path) else { return Data() }
        return try Data(contentsOf: fileURL)
    }
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
        entries[value.bundleID] = value
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(entries)
        try data.write(to: fileURL, options: .atomic)
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
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: AppKnowledge].self, from: data) {
            entries = decoded
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
        let identity = try secureFileMutation.identity(of: safe, allowedRoot: allowedRoot)
        let data = try secureFileMutation.readFile(at: safe, allowedRoot: allowedRoot, expectedIdentity: identity, maxBytes: maxBytes)
        guard let value = String(data: data, encoding: .utf8) else {
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
    private let secureFileMutation: SecureFileMutation

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

public extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
