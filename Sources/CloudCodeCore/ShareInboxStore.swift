import Foundation

public enum CloudCodeShareInboxError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case invalidSource
    case fileTooLarge
    case malformedTransaction
}

public struct CloudCodeShareManifest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var originalFilename: String
    public var storedFilename: String
    public var mimeType: String
    public var typeIdentifier: String
    public var byteSize: Int64
    public var createdAt: Date
    public var sourceType: String

    public init(
        id: UUID,
        originalFilename: String,
        storedFilename: String,
        mimeType: String,
        typeIdentifier: String,
        byteSize: Int64,
        createdAt: Date = Date(),
        sourceType: String
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.mimeType = mimeType
        self.typeIdentifier = typeIdentifier
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.sourceType = sourceType
    }
}

public struct CloudCodeShareTransaction: Equatable, Sendable, Identifiable {
    public var id: UUID { manifest.id }
    public var manifest: CloudCodeShareManifest
    public var directoryURL: URL
    public var fileURL: URL

    public init(manifest: CloudCodeShareManifest, directoryURL: URL, fileURL: URL) {
        self.manifest = manifest
        self.directoryURL = directoryURL
        self.fileURL = fileURL
    }
}

public struct CloudCodeShareImportReceipt: Codable, Equatable, Sendable {
    public var transactionID: UUID
    public var sessionID: UUID
    public var attachment: ChatAttachment
    public var inspection: DocumentInspection?
    public var inspectionError: String?
    public var importedAt: Date

    public init(
        transactionID: UUID,
        sessionID: UUID,
        attachment: ChatAttachment,
        inspection: DocumentInspection?,
        inspectionError: String?,
        importedAt: Date = Date()
    ) {
        self.transactionID = transactionID
        self.sessionID = sessionID
        self.attachment = attachment
        self.inspection = inspection
        self.inspectionError = inspectionError
        self.importedAt = importedAt
    }
}

public struct CloudCodeShareInboxStore: Sendable {
    public static let appGroupIdentifier = "group.com.cloudcode.ios.share"
    public static let inboxDirectoryName = "ShareInbox"
    public static let maximumFileBytes: Int64 = 512 * 1024 * 1024

    private static let manifestFilename = "manifest.json"
    private static let receiptFilename = "receipt.json"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public static func appGroupStore(fileManager: FileManager = .default) throws -> CloudCodeShareInboxStore {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CloudCodeShareInboxError.appGroupUnavailable
        }
        return CloudCodeShareInboxStore(
            rootURL: container.appendingPathComponent(inboxDirectoryName, isDirectory: true)
        )
    }

    @discardableResult
    public func enqueueFile(
        from sourceURL: URL,
        originalFilename: String,
        mimeType: String,
        typeIdentifier: String,
        sourceType: String,
        maximumBytes: Int64 = CloudCodeShareInboxStore.maximumFileBytes
    ) throws -> CloudCodeShareTransaction {
        let fileManager = FileManager.default
        let source = sourceURL.standardizedFileURL
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CloudCodeShareInboxError.invalidSource
        }
        let byteSize = Int64(values.fileSize ?? 0)
        guard byteSize >= 0, byteSize <= maximumBytes else {
            throw CloudCodeShareInboxError.fileTooLarge
        }

        let id = UUID()
        let names = Self.safeNames(originalFilename)
        let transaction = try prepareTransaction(id: id, storedFilename: names.storedFilename) { destination in
            try fileManager.copyItem(at: source, to: destination)
        }
        let manifest = CloudCodeShareManifest(
            id: id,
            originalFilename: names.displayName,
            storedFilename: names.storedFilename,
            mimeType: Self.safeMetadataValue(mimeType, fallback: "application/octet-stream"),
            typeIdentifier: Self.safeMetadataValue(typeIdentifier, fallback: "public.data"),
            byteSize: byteSize,
            sourceType: Self.safeMetadataValue(sourceType, fallback: "share-extension")
        )
        return try commit(transaction: transaction, manifest: manifest)
    }

    @discardableResult
    public func enqueueData(
        _ data: Data,
        originalFilename: String,
        mimeType: String,
        typeIdentifier: String,
        sourceType: String,
        maximumBytes: Int64 = CloudCodeShareInboxStore.maximumFileBytes
    ) throws -> CloudCodeShareTransaction {
        guard Int64(data.count) <= maximumBytes else {
            throw CloudCodeShareInboxError.fileTooLarge
        }
        let id = UUID()
        let names = Self.safeNames(originalFilename)
        let transaction = try prepareTransaction(id: id, storedFilename: names.storedFilename) { destination in
            try data.write(to: destination, options: .atomic)
        }
        let manifest = CloudCodeShareManifest(
            id: id,
            originalFilename: names.displayName,
            storedFilename: names.storedFilename,
            mimeType: Self.safeMetadataValue(mimeType, fallback: "application/octet-stream"),
            typeIdentifier: Self.safeMetadataValue(typeIdentifier, fallback: "public.data"),
            byteSize: Int64(data.count),
            sourceType: Self.safeMetadataValue(sourceType, fallback: "share-extension")
        )
        return try commit(transaction: transaction, manifest: manifest)
    }

    public func pendingTransactions() throws -> [CloudCodeShareTransaction] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let candidates = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var transactions: [CloudCodeShareTransaction] = []
        for directory in candidates {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, UUID(uuidString: directory.lastPathComponent) != nil else {
                continue
            }
            if let transaction = try? transaction(at: directory) {
                transactions.append(transaction)
            }
        }
        return transactions.sorted {
            if $0.manifest.createdAt == $1.manifest.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.manifest.createdAt < $1.manifest.createdAt
        }
    }

    public func receipt(for transaction: CloudCodeShareTransaction) throws -> CloudCodeShareImportReceipt? {
        let url = transaction.directoryURL.appendingPathComponent(Self.receiptFilename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try JSONDecoder().decode(CloudCodeShareImportReceipt.self, from: Data(contentsOf: url))
        guard receipt.transactionID == transaction.id else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        let attachmentURL = URL(fileURLWithPath: receipt.attachment.path).standardizedFileURL
        let values = try? attachmentURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              Int64(values?.fileSize ?? -1) == receipt.attachment.byteSize else {
            return nil
        }
        return receipt
    }

    public func writeReceipt(_ receipt: CloudCodeShareImportReceipt, for transaction: CloudCodeShareTransaction) throws {
        guard receipt.transactionID == transaction.id else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let destination = transaction.directoryURL.appendingPathComponent(Self.receiptFilename, isDirectory: false)
        let temporary = transaction.directoryURL.appendingPathComponent(".receipt-\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temporary, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func removeReceipt(for transaction: CloudCodeShareTransaction) throws {
        let url = transaction.directoryURL.appendingPathComponent(Self.receiptFilename, isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func complete(transactionID: UUID) throws {
        let candidate = rootURL.appendingPathComponent(transactionID.uuidString, isDirectory: true).standardizedFileURL
        guard Self.isDescendant(candidate, of: rootURL) else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private func transaction(at directory: URL) throws -> CloudCodeShareTransaction {
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        let manifest = try JSONDecoder().decode(CloudCodeShareManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.id.uuidString == directory.lastPathComponent else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        let storedName = URL(fileURLWithPath: manifest.storedFilename).lastPathComponent
        guard storedName == manifest.storedFilename, !storedName.isEmpty else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        let fileURL = directory.appendingPathComponent(storedName, isDirectory: false).standardizedFileURL
        guard Self.isDescendant(fileURL, of: directory) else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == manifest.byteSize,
              manifest.byteSize <= Self.maximumFileBytes else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        return CloudCodeShareTransaction(manifest: manifest, directoryURL: directory, fileURL: fileURL)
    }

    private func prepareTransaction(
        id: UUID,
        storedFilename: String,
        writer: (URL) throws -> Void
    ) throws -> (staging: URL, final: URL, file: URL) {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let staging = rootURL.appendingPathComponent(".staging-\(id.uuidString)", isDirectory: true)
        let final = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard Self.isDescendant(staging, of: rootURL), Self.isDescendant(final, of: rootURL) else {
            throw CloudCodeShareInboxError.malformedTransaction
        }
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let destination = staging.appendingPathComponent(storedFilename, isDirectory: false)
            try writer(destination)
            return (staging, final, destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func commit(
        transaction: (staging: URL, final: URL, file: URL),
        manifest: CloudCodeShareManifest
    ) throws -> CloudCodeShareTransaction {
        let fileManager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let temporaryManifest = transaction.staging.appendingPathComponent(".manifest.tmp", isDirectory: false)
        let finalManifest = transaction.staging.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        do {
            try data.write(to: temporaryManifest, options: .atomic)
            try fileManager.moveItem(at: temporaryManifest, to: finalManifest)
            try fileManager.moveItem(at: transaction.staging, to: transaction.final)
            let finalFile = transaction.final.appendingPathComponent(manifest.storedFilename, isDirectory: false)
            return CloudCodeShareTransaction(manifest: manifest, directoryURL: transaction.final, fileURL: finalFile)
        } catch {
            try? fileManager.removeItem(at: transaction.staging)
            throw error
        }
    }

    private static func safeNames(_ originalFilename: String) -> (displayName: String, storedFilename: String) {
        var display = URL(fileURLWithPath: originalFilename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        display = display.replacingOccurrences(of: "\u{0000}", with: "")
        if display.isEmpty || display == "." || display == ".." {
            display = "attachment"
        }
        if display.count > 180 {
            display = String(display.prefix(180))
        }
        let ext = URL(fileURLWithPath: display).pathExtension
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
        let stored = ext.isEmpty ? "payload" : "payload.\(String(ext.prefix(16)))"
        return (display, stored)
    }

    private static func safeMetadataValue(_ value: String, fallback: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(256))
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return candidate.standardizedFileURL.path.hasPrefix(rootPath)
    }
}
