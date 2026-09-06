import Foundation
import SQLite3

public struct ResourceIndexStatistics: Sendable, Equatable {
    public var resourceCount: Int
    public var sidecarBytes: Int64
    public var generation: Int64
    public var fts5Available: Bool
    public var rebuiltCorruptSidecar: Bool

    public init(resourceCount: Int, sidecarBytes: Int64, generation: Int64, fts5Available: Bool, rebuiltCorruptSidecar: Bool) {
        self.resourceCount = resourceCount
        self.sidecarBytes = sidecarBytes
        self.generation = generation
        self.fts5Available = fts5Available
        self.rebuiltCorruptSidecar = rebuiltCorruptSidecar
    }
}

final class ResourceIndexSQLiteStore {
    private let url: URL
    private var database: OpaquePointer?
    private(set) var fts5Available = false
    var rebuiltCorruptSidecar = false

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let pointer { sqlite3_close(pointer) }
            throw NSError(domain: "CloudCode.ResourceIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        database = pointer
        sqlite3_busy_timeout(pointer, 2_000)
        do {
            try verifyIntegrity()
            try execute("PRAGMA journal_mode=TRUNCATE")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("""
            CREATE TABLE IF NOT EXISTS resource_index_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
            try execute("INSERT OR IGNORE INTO resource_index_meta(key, value) VALUES ('generation', '0')")
            try execute("""
            CREATE TABLE IF NOT EXISTS resources (
                resource_id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                logical_location TEXT NOT NULL,
                real_path TEXT,
                normalized_path TEXT,
                owner_bundle_id TEXT,
                resource_kind TEXT NOT NULL,
                file_extension TEXT,
                content_type TEXT,
                byte_size INTEGER,
                mtime REAL,
                last_validated REAL NOT NULL,
                generation INTEGER NOT NULL,
                source TEXT NOT NULL,
                metadata_json BLOB
            )
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_resources_name ON resources(normalized_name)")
            try execute("CREATE INDEX IF NOT EXISTS idx_resources_owner_name ON resources(owner_bundle_id, normalized_name)")
            try execute("CREATE INDEX IF NOT EXISTS idx_resources_path ON resources(normalized_path)")
            try execute("CREATE INDEX IF NOT EXISTS idx_resources_owner_path ON resources(owner_bundle_id, normalized_path)")
            try execute("CREATE INDEX IF NOT EXISTS idx_resources_kind ON resources(resource_kind)")
            try execute("CREATE INDEX IF NOT EXISTS idx_resources_extension ON resources(file_extension)")
            try execute("CREATE INDEX IF NOT EXISTS idx_resources_validated ON resources(last_validated)")
            try execute("""
            CREATE TABLE IF NOT EXISTS deep_index_roots (
                resource_id TEXT PRIMARY KEY NOT NULL,
                completed_at REAL NOT NULL
            )
            """)
            fts5Available = try Self.sqliteCompileOptionEnabled(pointer, option: "ENABLE_FTS5")
        } catch {
            sqlite3_close(pointer)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func nextGeneration() throws -> Int64 {
        try execute("UPDATE resource_index_meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'generation'")
        return try scalarInt64("SELECT CAST(value AS INTEGER) FROM resource_index_meta WHERE key = 'generation'")
    }

    func currentGeneration() throws -> Int64 {
        try scalarInt64("SELECT CAST(value AS INTEGER) FROM resource_index_meta WHERE key = 'generation'")
    }

    func upsert(nodes: [ResourceNode], generation: Int64, source: String, validatedAt: Date = Date()) throws {
        guard !nodes.isEmpty, let database else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let sql = """
            INSERT INTO resources(
                resource_id, display_name, normalized_name, logical_location, real_path, normalized_path,
                owner_bundle_id, resource_kind, file_extension, content_type, byte_size, mtime,
                last_validated, generation, source, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(resource_id) DO UPDATE SET
                display_name=excluded.display_name,
                normalized_name=excluded.normalized_name,
                logical_location=excluded.logical_location,
                real_path=excluded.real_path,
                normalized_path=excluded.normalized_path,
                owner_bundle_id=excluded.owner_bundle_id,
                resource_kind=excluded.resource_kind,
                file_extension=excluded.file_extension,
                content_type=excluded.content_type,
                byte_size=excluded.byte_size,
                mtime=excluded.mtime,
                last_validated=excluded.last_validated,
                generation=excluded.generation,
                source=excluded.source,
                metadata_json=excluded.metadata_json
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw sqliteError()
            }
            defer { sqlite3_finalize(statement) }
            let encoder = JSONEncoder()
            for node in nodes {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                let standardizedPath = node.resolvedPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                let fileExtension = standardizedPath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
                let contentType = node.metadata["contentType"].flatMap { $0.isEmpty ? nil : $0 }
                let modifiedAt = node.metadata["modifiedAt"].flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }
                let metadataData = try? encoder.encode(node.metadata)
                try bindText(node.id.rawValue, to: statement, index: 1)
                try bindText(node.displayName, to: statement, index: 2)
                try bindText(Self.normalize(node.displayName), to: statement, index: 3)
                try bindText(node.logicalLocation, to: statement, index: 4)
                try bindOptionalText(standardizedPath, to: statement, index: 5)
                try bindOptionalText(standardizedPath.map(Self.normalize), to: statement, index: 6)
                try bindOptionalText(node.ownerBundleID, to: statement, index: 7)
                try bindText(node.kind.rawValue, to: statement, index: 8)
                try bindOptionalText(fileExtension, to: statement, index: 9)
                try bindOptionalText(contentType, to: statement, index: 10)
                if let byteSize = node.byteSize { sqlite3_bind_int64(statement, 11, byteSize) } else { sqlite3_bind_null(statement, 11) }
                if let modifiedAt { sqlite3_bind_double(statement, 12, modifiedAt) } else { sqlite3_bind_null(statement, 12) }
                sqlite3_bind_double(statement, 13, validatedAt.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 14, generation)
                try bindText(source, to: statement, index: 15)
                if let metadataData {
                    metadataData.withUnsafeBytes { bytes in
                        _ = sqlite3_bind_blob(statement, 16, bytes.baseAddress, Int32(bytes.count), RESOURCE_INDEX_SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(statement, 16)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func search(
        normalizedNeedle: String,
        extensions: Set<String>,
        ownerBundleID: String?,
        pathPrefix: String?,
        kinds: Set<ResourceKind>,
        limit: Int
    ) throws -> [ResourceNode] {
        guard let database else { return [] }
        var clauses: [String] = []
        var bindings: [SQLiteIndexBinding] = []
        let prefixPattern = Self.escapeLike(normalizedNeedle) + "%"
        clauses.append("(normalized_name = ? OR normalized_name LIKE ? ESCAPE '\\' OR instr(normalized_name, ?) > 0 OR instr(COALESCE(normalized_path, ''), ?) > 0)")
        bindings += [.text(normalizedNeedle), .text(prefixPattern), .text(normalizedNeedle), .text(normalizedNeedle)]
        if let ownerBundleID {
            clauses.append("owner_bundle_id = ?")
            bindings.append(.text(ownerBundleID))
        }
        if let pathPrefix {
            let standardized = URL(fileURLWithPath: pathPrefix).standardizedFileURL.path
            let rootWithSlash = standardized.hasSuffix("/") ? standardized : standardized + "/"
            clauses.append("(real_path = ? OR substr(real_path, 1, length(?)) = ?)")
            bindings += [.text(standardized), .text(rootWithSlash), .text(rootWithSlash)]
        }
        if !kinds.isEmpty {
            clauses.append("resource_kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))")
            bindings += kinds.map { .text($0.rawValue) }
        }
        if !extensions.isEmpty {
            clauses.append("(resource_kind = 'directory' OR file_extension IN (\(Array(repeating: "?", count: extensions.count).joined(separator: ","))))")
            bindings += extensions.sorted().map { .text($0.lowercased()) }
        }
        let sql = """
        SELECT resource_id, display_name, logical_location, real_path, owner_bundle_id, resource_kind,
               byte_size, metadata_json,
               CASE
                   WHEN normalized_name = ? THEN 0
                   WHEN normalized_name LIKE ? ESCAPE '\\' THEN 1
                   WHEN instr(normalized_name, ?) > 0 THEN 2
                   ELSE 3
               END AS rank_score
        FROM resources
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY rank_score ASC, normalized_name ASC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        var orderedBindings: [SQLiteIndexBinding] = [
            .text(normalizedNeedle), .text(prefixPattern), .text(normalizedNeedle)
        ]
        orderedBindings += bindings
        orderedBindings.append(.int64(Int64(limit)))
        try bind(orderedBindings, to: statement)
        var nodes: [ResourceNode] = []
        let decoder = JSONDecoder()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw sqliteError() }
            let rawID = text(statement, 0) ?? ""
            let kind = ResourceKind(rawValue: text(statement, 5) ?? "") ?? .file
            var metadata: [String: String] = [:]
            if sqlite3_column_type(statement, 7) != SQLITE_NULL,
               let blob = sqlite3_column_blob(statement, 7) {
                let count = Int(sqlite3_column_bytes(statement, 7))
                let data = Data(bytes: blob, count: max(0, count))
                metadata = (try? decoder.decode([String: String].self, from: data)) ?? [:]
            }
            nodes.append(ResourceNode(
                id: ResourceID(rawID),
                kind: kind,
                displayName: text(statement, 1) ?? rawID,
                logicalLocation: text(statement, 2) ?? rawID,
                resolvedPath: optionalText(statement, 3),
                ownerBundleID: optionalText(statement, 4),
                byteSize: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6),
                metadata: metadata
            ))
        }
        return nodes
    }

    func recentNodes(limit: Int) throws -> [ResourceNode] {
        guard let database else { return [] }
        let sql = """
        SELECT resource_id, display_name, logical_location, real_path, owner_bundle_id, resource_kind, byte_size, metadata_json
        FROM resources
        ORDER BY last_validated DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var result: [ResourceNode] = []
        let decoder = JSONDecoder()
        while sqlite3_step(statement) == SQLITE_ROW {
            var metadata: [String: String] = [:]
            if sqlite3_column_type(statement, 7) != SQLITE_NULL, let blob = sqlite3_column_blob(statement, 7) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 7)))
                metadata = (try? decoder.decode([String: String].self, from: data)) ?? [:]
            }
            result.append(ResourceNode(
                id: ResourceID(text(statement, 0) ?? ""),
                kind: ResourceKind(rawValue: text(statement, 5) ?? "") ?? .file,
                displayName: text(statement, 1) ?? "",
                logicalLocation: text(statement, 2) ?? "",
                resolvedPath: optionalText(statement, 3),
                ownerBundleID: optionalText(statement, 4),
                byteSize: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6),
                metadata: metadata
            ))
        }
        return result
    }

    func remove(ids: Set<ResourceID>) throws {
        guard !ids.isEmpty, let database else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM resources WHERE resource_id = ?", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bindText(id.rawValue, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func removeOwner(bundleID: String) throws {
        guard let database else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            var deepStatement: OpaquePointer?
            let deepSQL = "DELETE FROM deep_index_roots WHERE resource_id IN (SELECT resource_id FROM resources WHERE owner_bundle_id = ?)"
            guard sqlite3_prepare_v2(database, deepSQL, -1, &deepStatement, nil) == SQLITE_OK, let deepStatement else { throw sqliteError() }
            try bindText(bundleID, to: deepStatement, index: 1)
            guard sqlite3_step(deepStatement) == SQLITE_DONE else {
                sqlite3_finalize(deepStatement)
                throw sqliteError()
            }
            sqlite3_finalize(deepStatement)

            var resourceStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM resources WHERE owner_bundle_id = ?", -1, &resourceStatement, nil) == SQLITE_OK, let resourceStatement else { throw sqliteError() }
            try bindText(bundleID, to: resourceStatement, index: 1)
            guard sqlite3_step(resourceStatement) == SQLITE_DONE else {
                sqlite3_finalize(resourceStatement)
                throw sqliteError()
            }
            sqlite3_finalize(resourceStatement)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func invalidateOwnerPathsOutside(bundleID: String, rootPath: String) throws {
        guard let database else { return }
        let standardized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let rootWithSlash = standardized.hasSuffix("/") ? standardized : standardized + "/"
        let sql = "DELETE FROM resources WHERE owner_bundle_id = ? AND real_path IS NOT NULL AND NOT (real_path = ? OR substr(real_path, 1, length(?)) = ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        try bind([.text(bundleID), .text(standardized), .text(rootWithSlash), .text(rootWithSlash)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    func markValidated(id: ResourceID, path: String, byteSize: Int64?, modificationDate: Date?) throws {
        guard let database else { return }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let sql = "UPDATE resources SET real_path=?, normalized_path=?, byte_size=?, mtime=?, last_validated=? WHERE resource_id=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        try bindText(standardized, to: statement, index: 1)
        try bindText(Self.normalize(standardized), to: statement, index: 2)
        if let byteSize { sqlite3_bind_int64(statement, 3, byteSize) } else { sqlite3_bind_null(statement, 3) }
        if let modificationDate { sqlite3_bind_double(statement, 4, modificationDate.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 4) }
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        try bindText(id.rawValue, to: statement, index: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    func deepIndexedIDs() throws -> Set<ResourceID> {
        guard let database else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT resource_id FROM deep_index_roots", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        var result: Set<ResourceID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = text(statement, 0) { result.insert(ResourceID(value)) }
        }
        return result
    }

    func setDeepIndexed(_ id: ResourceID) throws {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO deep_index_roots(resource_id, completed_at) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        try bindText(id.rawValue, to: statement, index: 1)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    func removeDeepIndexed(_ ids: Set<ResourceID>) throws {
        guard !ids.isEmpty, let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM deep_index_roots WHERE resource_id = ?", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bindText(id.rawValue, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func statistics() throws -> ResourceIndexStatistics {
        let count = Int(try scalarInt64("SELECT COUNT(*) FROM resources"))
        let generation = try currentGeneration()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ResourceIndexStatistics(resourceCount: count, sidecarBytes: bytes, generation: generation, fts5Available: fts5Available, rebuiltCorruptSidecar: rebuiltCorruptSidecar)
    }

    private func verifyIntegrity() throws {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, text(statement, 0)?.lowercased() == "ok" else {
            throw NSError(domain: "CloudCode.ResourceIndex", code: 2, userInfo: [NSLocalizedDescriptionKey: "resource index sidecar failed quick_check"])
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { return }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { if let message { sqlite3_free(message) } }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            throw NSError(domain: "CloudCode.ResourceIndex", code: Int(result), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private func scalarInt64(_ sql: String) throws -> Int64 {
        guard let database else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(_ bindings: [SQLiteIndexBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): try bindText(value, to: statement, index: index)
            case .int64(let value): sqlite3_bind_int64(statement, index, value)
            }
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, RESOURCE_INDEX_SQLITE_TRANSIENT) }
        guard result == SQLITE_OK else { throw sqliteError() }
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer, index: Int32) throws {
        if let value { try bindText(value, to: statement, index: index) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func sqliteError() -> Error {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable"
        return NSError(domain: "CloudCode.ResourceIndex", code: 3, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    private static func sqliteCompileOptionEnabled(_ database: OpaquePointer, option: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT sqlite_compileoption_used(?)", -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let bindResult = option.withCString { sqlite3_bind_text(statement, 1, $0, -1, RESOURCE_INDEX_SQLITE_TRANSIENT) }
        guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) != 0
    }
}

private enum SQLiteIndexBinding {
    case text(String)
    case int64(Int64)
}

private let RESOURCE_INDEX_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
