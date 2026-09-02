import Foundation

public enum TransactionError: Error, Equatable, CustomStringConvertible {
    case confirmationDenied
    case targetChangedDuringApproval
    case verificationFailed(String)
    case noBackup

    public var description: String {
        switch self {
        case .confirmationDenied: return "User denied the transaction"
        case .targetChangedDuringApproval: return "Target changed after planning; transaction aborted"
        case .verificationFailed(let value): return "Verification failed: \(value)"
        case .noBackup: return "No rollback backup exists"
        }
    }
}

public struct FileIdentity: Equatable, Sendable {
    public var size: UInt64
    public var modificationDate: Date?
    public var fileNumber: UInt64?

    public init(size: UInt64, modificationDate: Date?, fileNumber: UInt64?) {
        self.size = size
        self.modificationDate = modificationDate
        self.fileNumber = fileNumber
    }
}

public actor TransactionJournal {
    private let fileURL: URL
    private var recordsByID: [UUID: TransactionRecord] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([UUID: TransactionRecord].self, from: data) {
                self.recordsByID = decoded
            }
        }
    }

    public func upsert(_ record: TransactionRecord) throws {
        recordsByID[record.id] = record
        try persist()
    }

    public func record(_ id: UUID) -> TransactionRecord? { recordsByID[id] }

    public func all() -> [TransactionRecord] {
        recordsByID.values.sorted { $0.startedAt > $1.startedAt }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(recordsByID)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct TextDiff: Sendable {
    public init() {}

    public func make(old: String, new: String, maxLines: Int = 300) -> String {
        if old == new { return "(no changes)" }
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = ["--- original", "+++ proposed"]
        let count = max(oldLines.count, newLines.count)
        for index in 0..<count {
            if output.count >= maxLines { output.append("... diff truncated ..."); break }
            let lhs = index < oldLines.count ? oldLines[index] : nil
            let rhs = index < newLines.count ? newLines[index] : nil
            if lhs == rhs { continue }
            if let lhs { output.append("-\(lhs)") }
            if let rhs { output.append("+\(rhs)") }
        }
        return output.joined(separator: "\n")
    }
}

public actor TransactionEngine {
    public typealias ApprovalHandler = @Sendable (ApprovalPreview) async -> Bool
    public typealias VerificationHandler = @Sendable (URL) async throws -> VerificationResult

    private let backupRoot: URL
    private let policy: PolicyEngine
    private let pathGuard: PathGuard
    private let journal: TransactionJournal
    private let audit: AuditLogStore
    private let fileManager: FileManager
    private let diffEngine: TextDiff

    public init(
        backupRoot: URL,
        policy: PolicyEngine,
        journal: TransactionJournal,
        audit: AuditLogStore,
        fileManager: FileManager = .default,
        pathGuard: PathGuard = PathGuard(),
        diffEngine: TextDiff = TextDiff()
    ) {
        self.backupRoot = backupRoot
        self.policy = policy
        self.journal = journal
        self.audit = audit
        self.fileManager = fileManager
        self.pathGuard = pathGuard
        self.diffEngine = diffEngine
    }

    public func replaceFile(
        target: URL,
        proposedData: Data,
        tool: ToolDescriptor,
        sessionID: UUID,
        toolCallID: UUID,
        mode: PermissionMode,
        reason: String,
        allowedRoot: URL? = nil,
        approval: ApprovalHandler,
        verify: VerificationHandler
    ) async throws -> TransactionRecord {
        let safeTarget = try pathGuard.validate(target: target, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        let initialIdentity = try identity(of: safeTarget)
        let originalData = try Data(contentsOf: safeTarget, options: [.mappedIfSafe])
        let originalText = String(data: originalData, encoding: .utf8)
        let proposedText = String(data: proposedData, encoding: .utf8)
        let diff = (originalText != nil && proposedText != nil) ? diffEngine.make(old: originalText!, new: proposedText!) : "Binary replacement: \(originalData.count) bytes → \(proposedData.count) bytes"

        var transaction = TransactionRecord(sessionID: sessionID, toolCallID: toolCallID, targetPath: safeTarget.path, diff: diff)
        try await journal.upsert(transaction)

        let decision = policy.decision(mode: mode, tool: tool, targetPath: safeTarget.path)
        if decision == .deny { throw TransactionError.confirmationDenied }
        if decision == .requireConfirmation {
            transaction.state = .awaitingConfirmation
            try await journal.upsert(transaction)
            let preview = ApprovalPreview(
                title: "Modify important file",
                target: safeTarget.path,
                originalSummary: "\(originalData.count) bytes",
                diff: diff,
                reason: reason,
                plan: ["Revalidate target", "Create backup", "Apply atomically", "Verify postcondition", "Commit or rollback"],
                risk: tool.risk
            )
            guard await approval(preview) else {
                transaction.state = .failed
                transaction.failure = TransactionError.confirmationDenied.description
                transaction.finishedAt = Date()
                try await journal.upsert(transaction)
                try await audit.append(AuditEvent(sessionID: sessionID, toolCallID: toolCallID, action: tool.name, target: safeTarget.path, risk: tool.risk, result: "denied"))
                throw TransactionError.confirmationDenied
            }
        }

        let currentIdentity = try identity(of: safeTarget)
        guard currentIdentity == initialIdentity else {
            transaction.state = .failed
            transaction.failure = TransactionError.targetChangedDuringApproval.description
            transaction.finishedAt = Date()
            try await journal.upsert(transaction)
            throw TransactionError.targetChangedDuringApproval
        }

        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backupDirectory = backupRoot.appendingPathComponent(transaction.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backupURL = backupDirectory.appendingPathComponent(safeTarget.lastPathComponent)
        try fileManager.copyItem(at: safeTarget, to: backupURL)
        transaction.backupPath = backupURL.path
        transaction.state = .backedUp
        try await journal.upsert(transaction)

        do {
            transaction.state = .applying
            try await journal.upsert(transaction)
            let tempURL = safeTarget.deletingLastPathComponent().appendingPathComponent(".cloudcode-\(UUID().uuidString).tmp")
            try proposedData.write(to: tempURL, options: [.atomic])
            _ = try pathGuard.validate(target: safeTarget, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
            _ = try fileManager.replaceItemAt(safeTarget, withItemAt: tempURL, backupItemName: nil, options: [])

            transaction.state = .verifying
            try await journal.upsert(transaction)
            let verification = try await verify(safeTarget)
            guard verification.passed else {
                throw TransactionError.verificationFailed(verification.failures.joined(separator: "; "))
            }

            transaction.state = .committed
            transaction.finishedAt = Date()
            try await journal.upsert(transaction)
            try await audit.append(AuditEvent(sessionID: sessionID, toolCallID: toolCallID, action: tool.name, target: safeTarget.path, risk: tool.risk, result: "committed", detail: ["transactionID": transaction.id.uuidString]))
            return transaction
        } catch {
            try? restoreBackup(transaction: transaction, target: safeTarget)
            transaction.state = .rolledBack
            transaction.failure = String(describing: error)
            transaction.finishedAt = Date()
            try await journal.upsert(transaction)
            try? await audit.append(AuditEvent(sessionID: sessionID, toolCallID: toolCallID, action: tool.name, target: safeTarget.path, risk: tool.risk, result: "rolled_back", detail: ["error": String(describing: error)]))
            throw error
        }
    }

    public func rollback(transactionID: UUID) async throws -> TransactionRecord {
        guard var transaction = await journal.record(transactionID) else { throw TransactionError.noBackup }
        let target = URL(fileURLWithPath: transaction.targetPath)
        try restoreBackup(transaction: transaction, target: target)
        transaction.state = .rolledBack
        transaction.finishedAt = Date()
        try await journal.upsert(transaction)
        try await audit.append(AuditEvent(sessionID: transaction.sessionID, toolCallID: transaction.toolCallID, action: "transaction.rollback", target: target.path, risk: .sensitiveWrite, result: "rolled_back"))
        return transaction
    }

    private func restoreBackup(transaction: TransactionRecord, target: URL) throws {
        guard let backupPath = transaction.backupPath else { throw TransactionError.noBackup }
        let backupURL = URL(fileURLWithPath: backupPath)
        guard fileManager.fileExists(atPath: backupURL.path) else { throw TransactionError.noBackup }
        let safeBackup = try pathGuard.validate(target: backupURL, allowedRoot: backupRoot, rejectSymlink: true, fileManager: fileManager)
        let safeTarget = try pathGuard.validate(target: target, rejectSymlink: true, fileManager: fileManager)
        let temporary = safeTarget.deletingLastPathComponent().appendingPathComponent(".cloudcode-rollback-\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: safeBackup, to: temporary)
        do {
            if fileManager.fileExists(atPath: safeTarget.path) {
                _ = try fileManager.replaceItemAt(safeTarget, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: temporary, to: safeTarget)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func identity(of url: URL) throws -> FileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let date = attributes[.modificationDate] as? Date
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileIdentity(size: size, modificationDate: date, fileNumber: number)
    }
}
