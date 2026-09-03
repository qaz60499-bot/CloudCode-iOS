import Foundation
import CryptoKit

public enum ToolExecutionLedgerError: Error, Equatable, CustomStringConvertible {
    case idempotencyConflict(UUID)
    case priorExecutionUncertain(UUID)
    case corruptLedger

    public var description: String {
        switch self {
        case .idempotencyConflict(let id):
            return "Tool call \(id) was replayed with different arguments"
        case .priorExecutionUncertain(let id):
            return "Tool call \(id) has a persisted pending execution; verify final state before retrying"
        case .corruptLedger:
            return "Tool execution ledger is unreadable; state-changing tools are fail-closed until the ledger is repaired"
        }
    }
}

public enum ToolExecutionRecordState: String, Codable, Sendable {
    case pending
    case completed
}

public struct ToolExecutionRecord: Codable, Equatable, Sendable {
    public var toolCallID: UUID
    public var toolName: String
    public var fingerprint: String
    public var state: ToolExecutionRecordState
    public var result: ToolResult?
    public var startedAt: Date
    public var completedAt: Date?

    public init(
        toolCallID: UUID,
        toolName: String,
        fingerprint: String,
        state: ToolExecutionRecordState,
        result: ToolResult? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.fingerprint = fingerprint
        self.state = state
        self.result = result
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public actor ToolExecutionLedger {
    private let fileURL: URL
    private var records: [UUID: ToolExecutionRecord]
    private var loadFailed: Bool

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? decoder.decode([UUID: ToolExecutionRecord].self, from: data) {
                records = decoded
                loadFailed = false
            } else {
                records = [:]
                loadFailed = true
            }
        } else {
            records = [:]
            loadFailed = false
        }
    }

    /// Returns a previously committed result, or persists a pending marker before a new write executes.
    /// A pending marker from a previous process is treated conservatively as an uncertain prior execution.
    public func prepare(_ call: ToolCall) throws -> ToolResult? {
        guard !loadFailed else { throw ToolExecutionLedgerError.corruptLedger }
        let fingerprint = Self.fingerprint(call)
        if let record = records[call.id] {
            guard record.toolName == call.name, record.fingerprint == fingerprint else {
                throw ToolExecutionLedgerError.idempotencyConflict(call.id)
            }
            switch record.state {
            case .completed:
                return record.result
            case .pending:
                throw ToolExecutionLedgerError.priorExecutionUncertain(call.id)
            }
        }

        records[call.id] = ToolExecutionRecord(
            toolCallID: call.id,
            toolName: call.name,
            fingerprint: fingerprint,
            state: .pending
        )
        try persist()
        return nil
    }

    public func complete(_ result: ToolResult, for call: ToolCall) throws {
        guard !loadFailed else { throw ToolExecutionLedgerError.corruptLedger }
        let fingerprint = Self.fingerprint(call)
        if let existing = records[call.id] {
            guard existing.toolName == call.name, existing.fingerprint == fingerprint else {
                throw ToolExecutionLedgerError.idempotencyConflict(call.id)
            }
        }
        records[call.id] = ToolExecutionRecord(
            toolCallID: call.id,
            toolName: call.name,
            fingerprint: fingerprint,
            state: .completed,
            result: result,
            startedAt: records[call.id]?.startedAt ?? Date(),
            completedAt: Date()
        )
        try persist()
    }

    public func record(for id: UUID) -> ToolExecutionRecord? { records[id] }

    public func all() -> [ToolExecutionRecord] {
        records.values.sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
    }

    public func exportSnapshotData() throws -> Data {
        if loadFailed, FileManager.default.fileExists(atPath: fileURL.path) {
            return try Data(contentsOf: fileURL)
        }
        return try JSONEncoder.pretty.encode(records)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(records).write(to: fileURL, options: .atomic)
    }

    private static func fingerprint(_ call: ToolCall) -> String {
        var parts = [call.name]
        for key in call.arguments.keys.sorted() {
            parts.append("\(key)=\(call.arguments[key] ?? "")")
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
