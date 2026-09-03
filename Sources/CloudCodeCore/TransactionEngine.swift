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

public enum TransactionJournalError: Error, Equatable {
    case corruptJournal
}

public actor TransactionJournal {
    private let fileURL: URL
    private var recordsByID: [UUID: TransactionRecord] = [:]
    private var loadFailed = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? decoder.decode([UUID: TransactionRecord].self, from: data) {
                self.recordsByID = decoded
            } else {
                loadFailed = true
            }
        }
    }

    public func assertHealthy() throws {
        guard !loadFailed else { throw TransactionJournalError.corruptJournal }
    }

    public func upsert(_ record: TransactionRecord) throws {
        try assertHealthy()
        recordsByID[record.id] = record
        try persist()
    }

    public func record(_ id: UUID) -> TransactionRecord? { recordsByID[id] }

    public func all() -> [TransactionRecord] {
        recordsByID.values.sorted { $0.startedAt > $1.startedAt }
    }

    public func exportSnapshotData() throws -> Data {
        if loadFailed, FileManager.default.fileExists(atPath: fileURL.path) {
            return try Data(contentsOf: fileURL)
        }
        return try JSONEncoder.pretty.encode(recordsByID)
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
    private let secureFileMutation: SecureFileMutation

    public init(
        backupRoot: URL,
        policy: PolicyEngine,
        journal: TransactionJournal,
        audit: AuditLogStore,
        fileManager: FileManager = .default,
        pathGuard: PathGuard = PathGuard(),
        diffEngine: TextDiff = TextDiff(),
        secureFileMutation: SecureFileMutation = SecureFileMutation()
    ) {
        self.backupRoot = backupRoot
        self.policy = policy
        self.journal = journal
        self.audit = audit
        self.fileManager = fileManager
        self.pathGuard = pathGuard
        self.diffEngine = diffEngine
        self.secureFileMutation = secureFileMutation
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
        let initialSecureIdentity = try secureFileMutation.identity(of: safeTarget, allowedRoot: allowedRoot)
        let originalData = try Data(contentsOf: safeTarget, options: [.mappedIfSafe])
        let originalText = String(data: originalData, encoding: .utf8)
        let proposedText = String(data: proposedData, encoding: .utf8)
        let diff = (originalText != nil && proposedText != nil) ? diffEngine.make(old: originalText!, new: proposedText!) : "二进制替换：\(originalData.count) 字节 → \(proposedData.count) 字节"

        var transaction = TransactionRecord(
            sessionID: sessionID,
            toolCallID: toolCallID,
            targetPath: safeTarget.path,
            allowedRootPath: allowedRoot?.standardizedFileURL.resolvingSymlinksInPath().path ?? "/",
            originalIdentity: initialSecureIdentity,
            diff: diff
        )
        try await journal.upsert(transaction)

        let decision = policy.decision(mode: mode, tool: tool, targetPath: safeTarget.path)
        if decision == .deny { throw TransactionError.confirmationDenied }
        if decision == .requireConfirmation {
            transaction.state = .awaitingConfirmation
            try await journal.upsert(transaction)
            let preview = ApprovalPreview(
                title: "修改重要文件",
                target: safeTarget.path,
                originalSummary: "\(originalData.count) bytes",
                diff: diff,
                reason: reason,
                plan: ["重新验证目标", "创建备份", "原子写入", "验证最终状态", "提交或回滚"],
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
        let currentSecureIdentity = try secureFileMutation.identity(of: safeTarget, allowedRoot: allowedRoot)
        guard currentIdentity == initialIdentity, currentSecureIdentity == initialSecureIdentity else {
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
        try secureFileMutation.copyFile(
            from: safeTarget,
            sourceAllowedRoot: allowedRoot,
            to: backupURL,
            destinationAllowedRoot: backupRoot,
            createDestinationIntermediates: true,
            expectedSourceIdentity: initialSecureIdentity
        )
        transaction.backupPath = backupURL.path
        transaction.state = .backedUp
        try await journal.upsert(transaction)

        do {
            transaction.state = .applying
            try await journal.upsert(transaction)
            let finalTarget = try pathGuard.validate(target: target, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
            guard finalTarget.path == safeTarget.path else { throw TransactionError.targetChangedDuringApproval }
            try secureFileMutation.replaceFile(
                at: finalTarget,
                data: proposedData,
                allowedRoot: allowedRoot,
                expectedTargetIdentity: initialSecureIdentity
            )
            transaction.appliedIdentity = try secureFileMutation.identity(of: finalTarget, allowedRoot: allowedRoot)
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
            let applyError = error
            do {
                try restoreBackup(transaction: transaction, target: safeTarget, allowedRoot: allowedRoot)
                transaction.state = .rolledBack
                transaction.failure = String(describing: applyError)
                transaction.finishedAt = Date()
                try await journal.upsert(transaction)
                try? await audit.append(AuditEvent(sessionID: sessionID, toolCallID: toolCallID, action: tool.name, target: safeTarget.path, risk: tool.risk, result: "rolled_back", detail: ["error": String(describing: applyError)]))
            } catch {
                transaction.state = .failed
                transaction.failure = "Apply failed: \(applyError); rollback failed: \(error)"
                transaction.finishedAt = Date()
                try await journal.upsert(transaction)
                try? await audit.append(AuditEvent(sessionID: sessionID, toolCallID: toolCallID, action: tool.name, target: safeTarget.path, risk: tool.risk, result: "rollback_failed", detail: ["applyError": String(describing: applyError), "rollbackError": String(describing: error)]))
            }
            throw applyError
        }
    }

    public func recoverInterruptedTransactions() async throws -> [TransactionRecord] {
        try await journal.assertHealthy()
        let candidates = await journal.all()
        var recovered: [TransactionRecord] = []
        for var transaction in candidates {
            let target = URL(fileURLWithPath: transaction.targetPath)
            switch transaction.state {
            case .planned, .awaitingConfirmation:
                transaction.state = .failed
                transaction.failure = "Abandoned after app restart before mutation"
                transaction.finishedAt = Date()
                try await journal.upsert(transaction)
                try await audit.append(AuditEvent(
                    sessionID: transaction.sessionID,
                    toolCallID: transaction.toolCallID,
                    action: "transaction.recover",
                    target: target.path,
                    risk: .sensitiveWrite,
                    result: "abandoned_before_mutation",
                    detail: ["transactionID": transaction.id.uuidString]
                ))
                recovered.append(transaction)
            case .backedUp, .applying, .verifying:
                guard transaction.backupPath != nil else { continue }
                let transactionAllowedRoot = transaction.allowedRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                do {
                    try restoreBackup(transaction: transaction, target: target, allowedRoot: transactionAllowedRoot)
                    transaction.state = .rolledBack
                    transaction.failure = "Recovered after interrupted transaction"
                    transaction.finishedAt = Date()
                    try await journal.upsert(transaction)
                    try await audit.append(AuditEvent(
                        sessionID: transaction.sessionID,
                        toolCallID: transaction.toolCallID,
                        action: "transaction.recover",
                        target: target.path,
                        risk: .sensitiveWrite,
                        result: "rolled_back_after_restart",
                        detail: ["transactionID": transaction.id.uuidString]
                    ))
                } catch {
                    transaction.state = .failed
                    transaction.failure = "Recovery blocked because target identity could not be proven: \(error)"
                    transaction.finishedAt = Date()
                    try await journal.upsert(transaction)
                    try await audit.append(AuditEvent(
                        sessionID: transaction.sessionID,
                        toolCallID: transaction.toolCallID,
                        action: "transaction.recover",
                        target: target.path,
                        risk: .sensitiveWrite,
                        result: "recovery_identity_uncertain",
                        detail: ["transactionID": transaction.id.uuidString, "error": String(describing: error)]
                    ))
                }
                recovered.append(transaction)
            case .committed, .rolledBack, .failed:
                continue
            }
        }
        return recovered
    }

    public func rollback(transactionID: UUID) async throws -> TransactionRecord {
        try await journal.assertHealthy()
        guard var transaction = await journal.record(transactionID) else { throw TransactionError.noBackup }
        if transaction.state == .rolledBack { return transaction }
        let target = URL(fileURLWithPath: transaction.targetPath)
        let transactionAllowedRoot = transaction.allowedRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        try restoreBackup(transaction: transaction, target: target, allowedRoot: transactionAllowedRoot)
        transaction.state = .rolledBack
        transaction.finishedAt = Date()
        try await journal.upsert(transaction)
        try await audit.append(AuditEvent(sessionID: transaction.sessionID, toolCallID: transaction.toolCallID, action: "transaction.rollback", target: target.path, risk: .sensitiveWrite, result: "rolled_back"))
        return transaction
    }

    private func restoreBackup(transaction: TransactionRecord, target: URL, allowedRoot: URL?) throws {
        guard transaction.allowedRootPath != nil,
              let originalIdentity = transaction.originalIdentity,
              let backupPath = transaction.backupPath else {
            throw TransactionError.targetChangedDuringApproval
        }
        let backupURL = URL(fileURLWithPath: backupPath)
        guard fileManager.fileExists(atPath: backupURL.path) else { throw TransactionError.noBackup }
        let safeBackup = try pathGuard.validate(target: backupURL, allowedRoot: backupRoot, rejectSymlink: true, fileManager: fileManager)
        let backupIdentity = try secureFileMutation.identity(of: safeBackup, allowedRoot: backupRoot)
        let backupData = try secureFileMutation.readFile(at: safeBackup, allowedRoot: backupRoot, expectedIdentity: backupIdentity)
        let safeTarget = try pathGuard.validate(target: target, allowedRoot: allowedRoot, rejectSymlink: true, fileManager: fileManager)
        guard safeTarget.path == transaction.targetPath,
              fileManager.fileExists(atPath: safeTarget.path) else {
            throw TransactionError.targetChangedDuringApproval
        }

        let currentIdentity = try secureFileMutation.identity(of: safeTarget, allowedRoot: allowedRoot)
        if currentIdentity == originalIdentity {
            return
        }
        guard let appliedIdentity = transaction.appliedIdentity,
              currentIdentity == appliedIdentity else {
            throw TransactionError.targetChangedDuringApproval
        }
        try secureFileMutation.replaceFile(
            at: safeTarget,
            data: backupData,
            allowedRoot: allowedRoot,
            expectedTargetIdentity: appliedIdentity
        )
        let restoredIdentity = try secureFileMutation.identity(of: safeTarget, allowedRoot: allowedRoot)
        guard restoredIdentity != appliedIdentity else {
            throw TransactionError.verificationFailed("Rollback did not replace the applied inode")
        }
        let restoredData = try secureFileMutation.readFile(at: safeTarget, allowedRoot: allowedRoot, expectedIdentity: restoredIdentity)
        guard restoredData == backupData else {
            throw TransactionError.verificationFailed("Rollback bytes do not match the persisted backup")
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
