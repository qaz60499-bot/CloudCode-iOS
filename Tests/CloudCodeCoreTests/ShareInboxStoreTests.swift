import XCTest
@testable import CloudCodeCore

final class ShareInboxStoreTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodeShareInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEnqueueFileCommitsManifestAndSanitizesName() throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("source.pdf")
        try Data("pdf".utf8).write(to: source)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let store = CloudCodeShareInboxStore(rootURL: inbox)

        let transaction = try store.enqueueFile(
            from: source,
            originalFilename: "../../report.pdf",
            mimeType: "application/pdf",
            typeIdentifier: "com.adobe.pdf",
            sourceType: "files"
        )

        XCTAssertEqual(transaction.manifest.originalFilename, "report.pdf")
        XCTAssertEqual(transaction.manifest.storedFilename, "payload.pdf")
        XCTAssertEqual(transaction.manifest.byteSize, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.directoryURL.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(".staging-\(transaction.id.uuidString)").path))

        let pending = try store.pendingTransactions()
        XCTAssertEqual(pending.map(\.id), [transaction.id])
    }

    func testReceiptMakesImportIdempotentUntilTransactionCompletes() throws {
        let root = try temporaryRoot()
        let store = CloudCodeShareInboxStore(rootURL: root.appendingPathComponent("inbox", isDirectory: true))
        let transaction = try store.enqueueData(
            Data("hello".utf8),
            originalFilename: "note.txt",
            mimeType: "text/plain",
            typeIdentifier: "public.plain-text",
            sourceType: "text"
        )
        let imported = root.appendingPathComponent("imported.txt")
        try Data("hello".utf8).write(to: imported)
        let attachment = ChatAttachment(
            filename: "note.txt",
            path: imported.path,
            mimeType: "text/plain",
            byteSize: 5,
            pixelWidth: nil,
            pixelHeight: nil
        )
        let receipt = CloudCodeShareImportReceipt(
            transactionID: transaction.id,
            sessionID: UUID(),
            attachment: attachment,
            inspection: nil,
            inspectionError: nil
        )

        try store.writeReceipt(receipt, for: transaction)
        XCTAssertEqual(try store.receipt(for: transaction), receipt)
        XCTAssertEqual(try store.pendingTransactions().count, 1)

        try store.complete(transactionID: transaction.id)
        XCTAssertTrue(try store.pendingTransactions().isEmpty)
    }

    func testReceiptIsRejectedWhenImportedAttachmentDisappears() throws {
        let root = try temporaryRoot()
        let store = CloudCodeShareInboxStore(rootURL: root.appendingPathComponent("inbox", isDirectory: true))
        let transaction = try store.enqueueData(
            Data("hello".utf8),
            originalFilename: "note.txt",
            mimeType: "text/plain",
            typeIdentifier: "public.plain-text",
            sourceType: "text"
        )
        let missing = root.appendingPathComponent("missing.txt")
        let attachment = ChatAttachment(
            filename: "note.txt",
            path: missing.path,
            mimeType: "text/plain",
            byteSize: 5,
            pixelWidth: nil,
            pixelHeight: nil
        )
        let receipt = CloudCodeShareImportReceipt(
            transactionID: transaction.id,
            sessionID: UUID(),
            attachment: attachment,
            inspection: nil,
            inspectionError: nil
        )
        try store.writeReceipt(receipt, for: transaction)
        XCTAssertNil(try store.receipt(for: transaction))
    }

    func testRejectsSymlinkSourceAndOversizedData() throws {
        let root = try temporaryRoot()
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = CloudCodeShareInboxStore(rootURL: root.appendingPathComponent("inbox", isDirectory: true))

        XCTAssertThrowsError(try store.enqueueFile(
            from: link,
            originalFilename: "link.txt",
            mimeType: "text/plain",
            typeIdentifier: "public.plain-text",
            sourceType: "file",
            maximumBytes: 10
        )) { error in
            XCTAssertEqual(error as? CloudCodeShareInboxError, .invalidSource)
        }

        XCTAssertThrowsError(try store.enqueueData(
            Data(repeating: 0x41, count: 11),
            originalFilename: "large.bin",
            mimeType: "application/octet-stream",
            typeIdentifier: "public.data",
            sourceType: "data",
            maximumBytes: 10
        )) { error in
            XCTAssertEqual(error as? CloudCodeShareInboxError, .fileTooLarge)
        }
    }
}
