import Foundation
import CloudCodeCore

public struct PendingSharedSkillPackage: Equatable, Sendable, Identifiable {
    public var id: UUID { transactionID }
    public var transactionID: UUID
    public var sourceURL: URL
    public var originalFilename: String

    public init(transactionID: UUID, sourceURL: URL, originalFilename: String) {
        self.transactionID = transactionID
        self.sourceURL = sourceURL
        self.originalFilename = originalFilename
    }
}

public struct PendingSharedChatDocument: Equatable, Sendable {
    public var transactionID: UUID
    public var document: ImportedChatDocument

    public init(transactionID: UUID, document: ImportedChatDocument) {
        self.transactionID = transactionID
        self.document = document
    }
}

extension CloudCodeViewModel {
    public func nextPendingSharedSkillPackageCandidate() throws -> PendingSharedSkillPackage? {
        let store: CloudCodeShareInboxStore
        do {
            store = try CloudCodeShareInboxStore.appGroupStore()
        } catch CloudCodeShareInboxError.appGroupUnavailable {
            return nil
        }
        guard let transaction = try store.pendingTransactions().first,
              transaction.fileURL.pathExtension.lowercased() == "zip",
              isSkillPackageArchive(transaction.fileURL) else { return nil }
        return PendingSharedSkillPackage(
            transactionID: transaction.id,
            sourceURL: transaction.fileURL,
            originalFilename: transaction.manifest.originalFilename
        )
    }

    @discardableResult
    public func importPendingSharedSkillPackage(_ pending: PendingSharedSkillPackage) async throws -> SpecializedSkillPackageSummary {
        let package = try await importSpecializedSkillPackage(from: pending.sourceURL)
        try completeSharedDocument(transactionID: pending.transactionID)
        return package
    }

    public func nextPendingSharedDocument() async throws -> PendingSharedChatDocument? {
        let store: CloudCodeShareInboxStore
        do {
            store = try CloudCodeShareInboxStore.appGroupStore()
        } catch CloudCodeShareInboxError.appGroupUnavailable {
            // An unsigned simulator build may not materialize an App Group container. Treat that as
            // an empty inbox so ordinary launch/CI stays usable; the extension itself still fails
            // visibly if the signed device build cannot open the shared container.
            return nil
        }
        guard let transaction = try store.pendingTransactions().first else { return nil }

        if let receipt = try store.receipt(for: transaction) {
            if receipt.sessionID == session.id {
                return PendingSharedChatDocument(
                    transactionID: transaction.id,
                    document: ImportedChatDocument(
                        attachment: receipt.attachment,
                        inspection: receipt.inspection,
                        inspectionError: receipt.inspectionError
                    )
                )
            }
            discardImportedChatDocument(
                ImportedChatDocument(
                    attachment: receipt.attachment,
                    inspection: receipt.inspection,
                    inspectionError: receipt.inspectionError
                )
            )
            try store.removeReceipt(for: transaction)
        }

        let imported = try await importChatDocument(
            from: transaction.fileURL,
            mimeType: transaction.manifest.mimeType
        )
        let receipt = CloudCodeShareImportReceipt(
            transactionID: transaction.id,
            sessionID: session.id,
            attachment: imported.attachment,
            inspection: imported.inspection,
            inspectionError: imported.inspectionError
        )
        do {
            try store.writeReceipt(receipt, for: transaction)
        } catch {
            discardImportedChatDocument(imported)
            throw error
        }
        return PendingSharedChatDocument(transactionID: transaction.id, document: imported)
    }

    public func completeSharedDocument(transactionID: UUID) throws {
        let store = try CloudCodeShareInboxStore.appGroupStore()
        try store.complete(transactionID: transactionID)
    }
}
