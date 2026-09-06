import Foundation
import SQLite3
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum NativeDataServiceError: Error, Equatable {
    case fileTooLarge
    case invalidPath(String)
    case invalidQuery(String)
    case unsupportedValue
    case sqlite(String)
    case queryTimedOut
    case resultTooLarge
}

public struct NativeSQLiteQueryResult: Codable, Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String: String]]
    public var truncated: Bool
    public var elapsedMS: Int

    public init(columns: [String], rows: [[String: String]], truncated: Bool, elapsedMS: Int) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
        self.elapsedMS = elapsedMS
    }
}

public struct NativePropertyListService: Sendable {
    private let fileManager: FileManager
    private let pathGuard: PathGuard
    private let secureFileMutation: SecureFileMutation
    private let maxInputBytes = 4 * 1024 * 1024

    public init(
        fileManager: FileManager = .default,
        pathGuard: PathGuard = PathGuard(),
        secureFileMutation: SecureFileMutation = SecureFileMutation()
    ) {
        self.fileManager = fileManager
        self.pathGuard = pathGuard
        self.secureFileMutation = secureFileMutation
    }

    public func read(path: URL, allowedRoot: URL? = nil) throws -> Any {
        let safe = try pathGuard.validate(target: path, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let identity = try secureFileMutation.identity(of: safe, allowedRoot: allowedRoot)
        let data = try secureFileMutation.readFile(at: safe, allowedRoot: allowedRoot, expectedIdentity: identity, maxBytes: maxInputBytes)
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    public func query(path: URL, keyPath: String, allowedRoot: URL? = nil) throws -> Any {
        let root = try read(path: path, allowedRoot: allowedRoot)
        guard let value = NativeStructuredValue.query(root, keyPath: keyPath) else {
            throw NativeDataServiceError.invalidQuery("plist key path not found")
        }
        return value
    }

    public func metadata(path: URL, allowedRoot: URL? = nil) throws -> [String: String] {
        let safe = try pathGuard.validate(target: path, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let identity = try secureFileMutation.identity(of: safe, allowedRoot: allowedRoot)
        let data = try secureFileMutation.readFile(at: safe, allowedRoot: allowedRoot, expectedIdentity: identity, maxBytes: maxInputBytes)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        var result: [String: String] = [
            "format": Self.formatName(format),
            "byteCount": String(data.count),
            "topLevelType": NativeStructuredValue.typeName(value)
        ]
        if let dict = value as? [String: Any] {
            result["count"] = String(dict.count)
            result["keys"] = dict.keys.sorted().prefix(128).joined(separator: ",")
        } else if let array = value as? [Any] {
            result["count"] = String(array.count)
        }
        return result
    }

    private static func formatName(_ format: PropertyListSerialization.PropertyListFormat) -> String {
        switch format {
        case .openStep: return "openStep"
        case .xml: return "xml"
        case .binary: return "binary"
        @unknown default: return "unknown"
        }
    }
}

public struct NativeJSONService: Sendable {
    private let fileManager: FileManager
    private let pathGuard: PathGuard
    private let secureFileMutation: SecureFileMutation
    private let maxInputBytes = 8 * 1024 * 1024

    public init(
        fileManager: FileManager = .default,
        pathGuard: PathGuard = PathGuard(),
        secureFileMutation: SecureFileMutation = SecureFileMutation()
    ) {
        self.fileManager = fileManager
        self.pathGuard = pathGuard
        self.secureFileMutation = secureFileMutation
    }

    public func read(path: URL, allowedRoot: URL? = nil) throws -> Any {
        let safe = try pathGuard.validate(target: path, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let identity = try secureFileMutation.identity(of: safe, allowedRoot: allowedRoot)
        let data = try secureFileMutation.readFile(at: safe, allowedRoot: allowedRoot, expectedIdentity: identity, maxBytes: maxInputBytes)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public func query(path: URL, keyPath: String, allowedRoot: URL? = nil) throws -> Any {
        let root = try read(path: path, allowedRoot: allowedRoot)
        guard let value = NativeStructuredValue.query(root, keyPath: keyPath) else {
            throw NativeDataServiceError.invalidQuery("json key path not found")
        }
        return value
    }

    public func filter(
        path: URL,
        keyPath: String,
        field: String,
        equals: String,
        limit: Int = 100,
        allowedRoot: URL? = nil
    ) throws -> [Any] {
        let value = try query(path: path, keyPath: keyPath, allowedRoot: allowedRoot)
        guard let array = value as? [Any] else { throw NativeDataServiceError.invalidQuery("json filter target is not an array") }
        let bounded = min(max(limit, 1), 500)
        var output: [Any] = []
        for item in array {
            guard let dictionary = item as? [String: Any], let candidate = dictionary[field] else { continue }
            if NativeStructuredValue.scalarString(candidate) == equals {
                output.append(item)
                if output.count >= bounded { break }
            }
        }
        return output
    }

    public func aggregate(
        path: URL,
        keyPath: String,
        field: String?,
        operation: String,
        allowedRoot: URL? = nil
    ) throws -> [String: String] {
        let value = try query(path: path, keyPath: keyPath, allowedRoot: allowedRoot)
        guard let array = value as? [Any] else { throw NativeDataServiceError.invalidQuery("json aggregate target is not an array") }
        let operation = operation.lowercased()
        if operation == "count" { return ["operation": "count", "value": String(array.count)] }
        guard let field, !field.isEmpty else { throw NativeDataServiceError.invalidQuery("aggregate field missing") }
        let values: [Double] = array.compactMap { item in
            guard let dictionary = item as? [String: Any], let raw = dictionary[field] else { return nil }
            if let number = raw as? NSNumber { return number.doubleValue }
            if let text = raw as? String { return Double(text) }
            return nil
        }
        guard !values.isEmpty else { throw NativeDataServiceError.invalidQuery("aggregate field has no numeric values") }
        let result: Double
        switch operation {
        case "sum": result = values.reduce(0, +)
        case "min": result = values.min() ?? 0
        case "max": result = values.max() ?? 0
        case "avg", "average": result = values.reduce(0, +) / Double(values.count)
        default: throw NativeDataServiceError.invalidQuery("unsupported aggregate operation")
        }
        return ["operation": operation, "field": field, "value": String(result), "count": String(values.count)]
    }
}

public struct NativeSQLiteService: @unchecked Sendable {
    private let fileManager: FileManager
    private let pathGuard: PathGuard
    private let maxRows = 500
    private let maxColumns = 96
    private let maxCellBytes = 16 * 1024
    private let maxSQLBytes = 32 * 1024

    public init(fileManager: FileManager = .default, pathGuard: PathGuard = PathGuard()) {
        self.fileManager = fileManager
        self.pathGuard = pathGuard
    }

    public func tables(path: URL, allowedRoot: URL? = nil) throws -> NativeSQLiteQueryResult {
        try query(
            path: path,
            sql: "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name LIMIT 500",
            parametersJSON: nil,
            rowLimit: 500,
            timeoutMS: 1_500,
            allowedRoot: allowedRoot
        )
    }

    public func schema(path: URL, table: String? = nil, allowedRoot: URL? = nil) throws -> NativeSQLiteQueryResult {
        if let table, !table.isEmpty {
            return try query(
                path: path,
                sql: "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE tbl_name = ? OR name = ? ORDER BY type, name LIMIT 200",
                parametersJSON: try Self.encodeParameters([table, table]),
                rowLimit: 200,
                timeoutMS: 1_500,
                allowedRoot: allowedRoot
            )
        }
        return try query(
            path: path,
            sql: "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE type IN ('table','view','index','trigger') ORDER BY type, name LIMIT 300",
            parametersJSON: nil,
            rowLimit: 300,
            timeoutMS: 1_500,
            allowedRoot: allowedRoot
        )
    }

    public func sample(path: URL, table: String, limit: Int = 20, allowedRoot: URL? = nil) throws -> NativeSQLiteQueryResult {
        guard Self.isValidIdentifier(table) else { throw NativeDataServiceError.invalidQuery("invalid SQLite table identifier") }
        let bounded = min(max(limit, 1), 100)
        return try query(
            path: path,
            sql: "SELECT * FROM \(Self.quotedIdentifier(table)) LIMIT \(bounded)",
            parametersJSON: nil,
            rowLimit: bounded,
            timeoutMS: 1_500,
            allowedRoot: allowedRoot
        )
    }

    public func filter(
        path: URL,
        table: String,
        field: String,
        equals: String,
        limit: Int = 100,
        allowedRoot: URL? = nil
    ) throws -> NativeSQLiteQueryResult {
        guard Self.isValidIdentifier(table), Self.isValidIdentifier(field) else {
            throw NativeDataServiceError.invalidQuery("invalid SQLite table or field identifier")
        }
        let bounded = min(max(limit, 1), 500)
        return try query(
            path: path,
            sql: "SELECT * FROM \(Self.quotedIdentifier(table)) WHERE \(Self.quotedIdentifier(field)) = ? LIMIT \(bounded)",
            parametersJSON: try Self.encodeParameters([equals]),
            rowLimit: bounded,
            timeoutMS: 2_000,
            allowedRoot: allowedRoot
        )
    }

    public func aggregate(
        path: URL,
        table: String,
        field: String?,
        operation: String,
        allowedRoot: URL? = nil
    ) throws -> NativeSQLiteQueryResult {
        guard Self.isValidIdentifier(table) else { throw NativeDataServiceError.invalidQuery("invalid SQLite table identifier") }
        let normalized = operation.lowercased()
        let expression: String
        if normalized == "count" {
            expression = "COUNT(*)"
        } else {
            guard let field, Self.isValidIdentifier(field) else { throw NativeDataServiceError.invalidQuery("aggregate field missing or invalid") }
            switch normalized {
            case "sum": expression = "SUM(\(Self.quotedIdentifier(field)))"
            case "min": expression = "MIN(\(Self.quotedIdentifier(field)))"
            case "max": expression = "MAX(\(Self.quotedIdentifier(field)))"
            case "avg", "average": expression = "AVG(\(Self.quotedIdentifier(field)))"
            default: throw NativeDataServiceError.invalidQuery("unsupported aggregate operation")
            }
        }
        return try query(
            path: path,
            sql: "SELECT \(expression) AS value FROM \(Self.quotedIdentifier(table))",
            parametersJSON: nil,
            rowLimit: 1,
            timeoutMS: 2_000,
            allowedRoot: allowedRoot
        )
    }

    public func query(
        path: URL,
        sql: String,
        parametersJSON: String?,
        rowLimit: Int = 200,
        timeoutMS: Int = 2_000,
        allowedRoot: URL? = nil
    ) throws -> NativeSQLiteQueryResult {
        let safe = try pathGuard.validate(target: path, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        guard fileManager.fileExists(atPath: safe.path) else { throw NativeDataServiceError.invalidPath("SQLite file not found") }
        let normalizedSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSQL.isEmpty, normalizedSQL.utf8.count <= maxSQLBytes else {
            throw NativeDataServiceError.invalidQuery("SQLite query is empty or too large")
        }
        let lower = normalizedSQL.lowercased()
        guard lower.hasPrefix("select") || lower.hasPrefix("with") || lower.hasPrefix("explain query plan") else {
            throw NativeDataServiceError.invalidQuery("only read-only SELECT/WITH/EXPLAIN QUERY PLAN statements are allowed")
        }
        let boundedRows = min(max(rowLimit, 1), maxRows)
        let boundedTimeout = min(max(timeoutMS, 100), 5_000)
        let startedAt = Date()
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(safe.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let database { sqlite3_close(database) }
            throw NativeDataServiceError.sqlite(message)
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_busy_timeout(database, Int32(min(boundedTimeout, 1_000)))
        _ = sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, Int32(maxSQLBytes))
        _ = sqlite3_limit(database, SQLITE_LIMIT_COLUMN, Int32(maxColumns))
        _ = sqlite3_set_authorizer(database, cloudCodeSQLiteReadOnlyAuthorizer, nil)

        let deadline = NativeSQLiteDeadline(deadline: Date().addingTimeInterval(Double(boundedTimeout) / 1_000.0))
        let retainedDeadline = Unmanaged.passRetained(deadline)
        sqlite3_progress_handler(database, 1_000, cloudCodeSQLiteProgressHandler, retainedDeadline.toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            retainedDeadline.release()
        }

        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let prepareCode = normalizedSQL.withCString { pointer in
            sqlite3_prepare_v2(database, pointer, -1, &statement, &tail)
        }
        guard prepareCode == SQLITE_OK, let statement else {
            if prepareCode == SQLITE_INTERRUPT { throw NativeDataServiceError.queryTimedOut }
            throw NativeDataServiceError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        if let tail {
            let remainder = String(cString: tail).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
            guard remainder.isEmpty else { throw NativeDataServiceError.invalidQuery("multiple SQLite statements are not allowed") }
        }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            throw NativeDataServiceError.invalidQuery("SQLite statement is not read-only")
        }
        try Self.bind(parametersJSON: parametersJSON, to: statement, database: database)

        let columnCount = Int(sqlite3_column_count(statement))
        guard columnCount >= 0, columnCount <= maxColumns else { throw NativeDataServiceError.resultTooLarge }
        var columns: [String] = []
        columns.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            columns.append(sqlite3_column_name(statement, Int32(index)).map { String(cString: $0) } ?? "column_\(index)")
        }

        var rows: [[String: String]] = []
        rows.reserveCapacity(min(boundedRows, 64))
        var truncated = false
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            if code == SQLITE_INTERRUPT { throw NativeDataServiceError.queryTimedOut }
            guard code == SQLITE_ROW else { throw NativeDataServiceError.sqlite(String(cString: sqlite3_errmsg(database))) }
            if rows.count >= boundedRows {
                truncated = true
                break
            }
            var row: [String: String] = [:]
            for index in 0..<columnCount {
                row[columns[index]] = Self.columnString(statement, index: Int32(index), maxBytes: maxCellBytes)
            }
            rows.append(row)
        }
        let elapsedMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        return NativeSQLiteQueryResult(columns: columns, rows: rows, truncated: truncated, elapsedMS: elapsedMS)
    }

    private static func bind(parametersJSON: String?, to statement: OpaquePointer, database: OpaquePointer) throws {
        guard let parametersJSON, !parametersJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = parametersJSON.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] else {
            throw NativeDataServiceError.invalidQuery("SQLite params must be a JSON array")
        }
        guard values.count == Int(sqlite3_bind_parameter_count(statement)) else {
            throw NativeDataServiceError.invalidQuery("SQLite parameter count mismatch")
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case is NSNull:
                result = sqlite3_bind_null(statement, index)
            case let string as String:
                result = string.withCString { sqlite3_bind_text(statement, index, $0, -1, SQLITE_TRANSIENT_NATIVE) }
            case let number as NSNumber:
                let type = String(cString: number.objCType)
                if type == "f" || type == "d" {
                    result = sqlite3_bind_double(statement, index, number.doubleValue)
                } else {
                    result = sqlite3_bind_int64(statement, index, number.int64Value)
                }
            default:
                throw NativeDataServiceError.unsupportedValue
            }
            guard result == SQLITE_OK else { throw NativeDataServiceError.sqlite(String(cString: sqlite3_errmsg(database))) }
        }
    }

    private static func columnString(_ statement: OpaquePointer, index: Int32, maxBytes: Int) -> String {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return "null"
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return "" }
            let bytes = max(0, Int(sqlite3_column_bytes(statement, index)))
            if bytes <= maxBytes { return String(cString: pointer) }
            return String(String(cString: pointer).prefix(maxBytes)) + "…<truncated>"
        case SQLITE_BLOB:
            let bytes = max(0, Int(sqlite3_column_bytes(statement, index)))
            return "<blob \(bytes) bytes>"
        default:
            return "<unknown>"
        }
    }

    private static func encodeParameters(_ values: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values, options: [])
        guard let text = String(data: data, encoding: .utf8) else { throw NativeDataServiceError.unsupportedValue }
        return text
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_ -.$"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum NativeStructuredValue {
    static func query(_ root: Any, keyPath: String) -> Any? {
        let trimmed = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "$" { return root }
        var current: Any = root
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard components.count <= 64 else { return nil }
        for component in components {
            if let dictionary = current as? [String: Any], let next = dictionary[component] {
                current = next
            } else if let dictionary = current as? NSDictionary, let next = dictionary[component] {
                current = next
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else if let array = current as? NSArray, let index = Int(component), index >= 0, index < array.count {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    static func scalarString(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return "null" }
        return nil
    }

    static func typeName(_ value: Any) -> String {
        switch value {
        case is [String: Any], is NSDictionary: return "dictionary"
        case is [Any], is NSArray: return "array"
        case is String: return "string"
        case is NSNumber: return "number"
        case is Data: return "data"
        case is Date: return "date"
        default: return String(describing: type(of: value))
        }
    }

    static func jsonCompatible(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key, jsonCompatible($0.value)) })
        }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, item) in dictionary {
                result[String(describing: key)] = jsonCompatible(item)
            }
            return result
        }
        if let array = value as? [Any] { return array.map(jsonCompatible) }
        if let array = value as? NSArray { return array.map(jsonCompatible) }
        if let data = value as? Data { return ["type": "data", "byteCount": data.count] }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if value is NSNull || value is String || value is NSNumber { return value }
        return String(describing: value)
    }
}

private final class NativeSQLiteDeadline {
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
}

private let SQLITE_TRANSIENT_NATIVE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private typealias SQLiteProgressCallback = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias SQLiteAuthorizerCallback = @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32

private let cloudCodeSQLiteProgressHandler: SQLiteProgressCallback = { opaque in
    guard let opaque else { return 1 }
    let deadline = Unmanaged<NativeSQLiteDeadline>.fromOpaque(opaque).takeUnretainedValue()
    return Date() >= deadline.deadline ? 1 : 0
}

private let cloudCodeSQLiteReadOnlyAuthorizer: SQLiteAuthorizerCallback = { _, action, _, _, _, _ in
    switch action {
    case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE:
        return SQLITE_OK
    default:
        return SQLITE_DENY
    }
}
