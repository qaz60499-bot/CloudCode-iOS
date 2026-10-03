import Foundation
import CloudCodeCore

struct ChatAttachmentStore: Sendable {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func save(
        data: Data,
        filename: String,
        mimeType: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        sessionID: UUID
    ) throws -> ChatAttachment {
        let fileManager = FileManager.default
        let sessionRoot = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)

        let displayName = Self.safeDisplayName(filename)
        let fileExtension = Self.safeExtension(from: displayName) ?? Self.defaultExtension(for: mimeType)
        let storedName = fileExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(fileExtension)"
        let url = sessionRoot.appendingPathComponent(storedName, isDirectory: false)
        try data.write(to: url, options: .atomic)

        return ChatAttachment(
            filename: displayName,
            path: url.path,
            mimeType: mimeType,
            byteSize: Int64(data.count),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    func importFile(
        from sourceURL: URL,
        filename: String,
        mimeType: String,
        sessionID: UUID,
        maximumBytes: Int64 = 512 * 1024 * 1024
    ) throws -> ChatAttachment {
        let fileManager = FileManager.default
        let safeSource = try PathGuard().validate(target: sourceURL, allowedRoot: nil, rejectSymlink: true, fileManager: fileManager)
        let values = try safeSource.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let byteSize = Int64(values.fileSize ?? 0)
        guard byteSize <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }

        let sessionRoot = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let displayName = Self.safeDisplayName(filename)
        let fileExtension = Self.safeExtension(from: displayName) ?? Self.defaultExtension(for: mimeType)
        let storedName = fileExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(fileExtension)"
        let destination = sessionRoot.appendingPathComponent(storedName, isDirectory: false)
        try fileManager.copyItem(at: safeSource, to: destination)

        return ChatAttachment(
            filename: displayName,
            path: destination.path,
            mimeType: mimeType,
            byteSize: byteSize,
            pixelWidth: nil,
            pixelHeight: nil
        )
    }

    func remove(_ attachment: ChatAttachment) throws {
        let fileManager = FileManager.default
        let candidate = URL(fileURLWithPath: attachment.path).standardizedFileURL
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        let approved = try PathGuard().validate(
            target: candidate,
            allowedRoot: root,
            rejectSymlink: true,
            fileManager: fileManager
        )
        let secureMutation = SecureFileMutation()
        let identity = try secureMutation.identity(of: approved, allowedRoot: root)
        try secureMutation.removeFile(
            at: approved,
            allowedRoot: root,
            expectedIdentity: identity
        )
    }

    func removeAll(for sessionID: UUID) throws {
        let fileManager = FileManager.default
        let sessionRoot = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: sessionRoot.path) else { return }
        try fileManager.removeItem(at: sessionRoot)
    }

    private static func safeDisplayName(_ filename: String) -> String {
        let component = URL(fileURLWithPath: filename).lastPathComponent
        return component.isEmpty || component == "." ? "attachment" : component
    }

    private static func safeExtension(from filename: String) -> String? {
        let ext = URL(fileURLWithPath: filename).pathExtension
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
        return ext.isEmpty ? nil : ext
    }

    private static func defaultExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/heic": return "heic"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/zip", "application/x-zip-compressed": return "zip"
        case "text/plain": return "txt"
        case "text/markdown": return "md"
        case "text/csv": return "csv"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "text/html": return "html"
        default: return "bin"
        }
    }
}
