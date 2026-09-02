import Foundation
import ZIPFoundation

public struct MachOInspection: Codable, Equatable, Sendable {
    public var file: String
    public var architectures: [String]
    public var encryptedLikely: Bool?

    public init(file: String, architectures: [String], encryptedLikely: Bool?) {
        self.file = file
        self.architectures = architectures
        self.encryptedLikely = encryptedLikely
    }
}

public struct IPAInspection: Codable, Equatable, Sendable {
    public var path: String
    public var bundleIdentifier: String?
    public var displayName: String?
    public var version: String?
    public var build: String?
    public var minimumOSVersion: String?
    public var executableName: String?
    public var architectures: [String]
    public var frameworks: [String]
    public var extensions: [String]
    public var hasCodeSignature: Bool
    public var hasEmbeddedProvision: Bool
    public var entitlementXML: String?
    public var machO: [MachOInspection]
    public var warnings: [String]

    public init(path: String, bundleIdentifier: String?, displayName: String?, version: String?, build: String?, minimumOSVersion: String?, executableName: String?, architectures: [String], frameworks: [String], extensions: [String], hasCodeSignature: Bool, hasEmbeddedProvision: Bool, entitlementXML: String?, machO: [MachOInspection], warnings: [String]) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.build = build
        self.minimumOSVersion = minimumOSVersion
        self.executableName = executableName
        self.architectures = architectures
        self.frameworks = frameworks
        self.extensions = extensions
        self.hasCodeSignature = hasCodeSignature
        self.hasEmbeddedProvision = hasEmbeddedProvision
        self.entitlementXML = entitlementXML
        self.machO = machO
        self.warnings = warnings
    }
}

public enum IPAServiceError: Error, Equatable {
    case invalidArchive
    case missingPayloadApp
    case missingInfoPlist
    case unsafeEntry(String)
    case entryTooLarge(String)
    case archiveTooLarge
    case destinationExists
    case invalidRepackSource
}

public struct IPAService: Sendable {
    public let maxMetadataEntryBytes: Int64
    public let maxExtractedBytes: UInt64

    public init(maxMetadataEntryBytes: Int64 = 64 * 1024 * 1024, maxExtractedBytes: UInt64 = 4 * 1024 * 1024 * 1024) {
        self.maxMetadataEntryBytes = maxMetadataEntryBytes
        self.maxExtractedBytes = maxExtractedBytes
    }

    public func locate(root: URL, fileService: FileService = FileService()) throws -> [FileEntry] {
        try fileService.search(root: root, query: FileSearchQuery(extensions: ["ipa"], maxDepth: 8, maxResults: 200))
            .filter { !$0.isDirectory }
    }

    public func inspect(_ ipaURL: URL) throws -> IPAInspection {
        let archive: Archive
        do { archive = try Archive(url: ipaURL, accessMode: .read) }
        catch { throw IPAServiceError.invalidArchive }
        let entries = Array(archive)
        for entry in entries { try validate(entry.path) }

        guard let appPrefix = detectPrimaryAppPrefix(entries: entries) else { throw IPAServiceError.missingPayloadApp }
        guard let infoEntry = entries.first(where: { $0.path == appPrefix + "Info.plist" }) else { throw IPAServiceError.missingInfoPlist }
        let infoData = try data(for: infoEntry, archive: archive)
        let plist = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)
        let info = plist as? [String: Any] ?? [:]

        let executableName = info["CFBundleExecutable"] as? String
        var executablePaths: [String] = []
        if let executableName { executablePaths.append(appPrefix + executableName) }
        executablePaths += entries
            .filter { $0.path.hasPrefix(appPrefix + "Frameworks/") && !$0.path.hasSuffix("/") }
            .map(\.path)
            .filter { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return !name.contains(".") || name.hasSuffix(".dylib")
            }
        executablePaths += entries
            .filter { $0.path.contains(".appex/") && !$0.path.hasSuffix("/") }
            .map(\.path)
            .filter { path in
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                return path.hasSuffix("/" + parent.replacingOccurrences(of: ".appex", with: ""))
            }

        var inspections: [MachOInspection] = []
        var allArchitectures = Set<String>()
        var entitlementXML: String?
        for path in executablePaths.uniqued() {
            guard let entry = archive[path], Int64(entry.uncompressedSize) <= maxMetadataEntryBytes else { continue }
            let bytes = try data(for: entry, archive: archive)
            let architectures = MachOParser.architectures(in: bytes)
            if !architectures.isEmpty {
                inspections.append(MachOInspection(file: path, architectures: architectures, encryptedLikely: MachOParser.hasCryptID(in: bytes)))
                allArchitectures.formUnion(architectures)
                if entitlementXML == nil { entitlementXML = MachOParser.extractXMLPlist(in: bytes) }
            }
        }

        let frameworks = entries
            .filter { $0.path.hasPrefix(appPrefix + "Frameworks/") && $0.path.contains(".framework/") }
            .map { pathToFrameworkName($0.path) }
            .compactMap { $0 }
            .uniqued()
            .sorted()

        let extensions = entries
            .filter { $0.path.contains(".appex/") }
            .map { pathToExtensionName($0.path) }
            .compactMap { $0 }
            .uniqued()
            .sorted()

        let hasSignature = entries.contains { $0.path.hasPrefix(appPrefix + "_CodeSignature/") }
        let hasProvision = entries.contains { $0.path == appPrefix + "embedded.mobileprovision" }
        var warnings: [String] = []
        if entitlementXML == nil { warnings.append("Entitlements were not recoverable as embedded XML; DER-only entitlements require device/toolchain validation.") }
        if !hasSignature { warnings.append("No _CodeSignature directory found in archive.") }

        return IPAInspection(
            path: ipaURL.path,
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            displayName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String),
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            executableName: executableName,
            architectures: allArchitectures.sorted(),
            frameworks: frameworks,
            extensions: extensions,
            hasCodeSignature: hasSignature,
            hasEmbeddedProvision: hasProvision,
            entitlementXML: entitlementXML,
            machO: inspections,
            warnings: warnings
        )
    }

    public func extract(_ ipaURL: URL, to destination: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: ipaURL, accessMode: .read) }
        catch { throw IPAServiceError.invalidArchive }
        if FileManager.default.fileExists(atPath: destination.path) { throw IPAServiceError.destinationExists }

        let entries = Array(archive)
        var total: UInt64 = 0
        for entry in entries {
            try validate(entry.path)
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= maxExtractedBytes else { throw IPAServiceError.archiveTooLarge }
            total = next
        }

        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).cloudcode-extract-staging", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let safeRoot = staging.standardizedFileURL
            let prefix = safeRoot.path.hasSuffix("/") ? safeRoot.path : safeRoot.path + "/"
            for entry in entries {
                let target = safeRoot.appendingPathComponent(entry.path).standardizedFileURL
                guard target.path == safeRoot.path || target.path.hasPrefix(prefix) else { throw IPAServiceError.unsafeEntry(entry.path) }
                _ = try archive.extract(entry, to: target)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func repack(sourceRoot: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.directoryExists(at: sourceRoot),
              fileManager.directoryExists(at: sourceRoot.appendingPathComponent("Payload", isDirectory: true)) else {
            throw IPAServiceError.invalidRepackSource
        }
        if fileManager.fileExists(atPath: destination.path) { throw IPAServiceError.destinationExists }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).cloudcode-repack-staging")
        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        do {
            guard let archive = try? Archive(url: staging, accessMode: .create) else { throw IPAServiceError.invalidArchive }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { throw IPAServiceError.invalidRepackSource }

            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw IPAServiceError.unsafeEntry(item.path) }
                let resolvedItem = item.standardizedFileURL.resolvingSymlinksInPath()
                guard resolvedItem.path.hasPrefix(rootPrefix) else { throw IPAServiceError.unsafeEntry(item.path) }
                let relative = String(resolvedItem.path.dropFirst(rootPrefix.count))
                guard !relative.isEmpty else { continue }
                try validate(relative)
                if values.isRegularFile == true {
                    try archive.addEntry(with: relative, fileURL: resolvedItem, compressionMethod: .deflate)
                }
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func data(for entry: Entry, archive: Archive) throws -> Data {
        guard Int64(entry.uncompressedSize) <= maxMetadataEntryBytes else { throw IPAServiceError.entryTooLarge(entry.path) }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return data
    }

    private func validate(_ path: String) throws {
        guard !path.hasPrefix("/") else { throw IPAServiceError.unsafeEntry(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else { throw IPAServiceError.unsafeEntry(path) }
    }

    private func detectPrimaryAppPrefix(entries: [Entry]) -> String? {
        let candidates = entries.map(\.path).filter { $0.hasPrefix("Payload/") && $0.contains(".app/Info.plist") }
        guard let first = candidates.sorted(by: { $0.count < $1.count }).first,
              let range = first.range(of: ".app/Info.plist") else { return nil }
        return String(first[..<range.lowerBound]) + ".app/"
    }

    private func pathToFrameworkName(_ path: String) -> String? {
        guard let range = path.range(of: ".framework/") else { return nil }
        let prefix = String(path[..<range.lowerBound])
        return URL(fileURLWithPath: prefix).lastPathComponent + ".framework"
    }

    private func pathToExtensionName(_ path: String) -> String? {
        guard let range = path.range(of: ".appex/") else { return nil }
        let prefix = String(path[..<range.lowerBound])
        return URL(fileURLWithPath: prefix).lastPathComponent + ".appex"
    }
}

public enum MachOParser {
    private static let mhMagic: UInt32 = 0xfeedface
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf

    public static func architectures(in data: Data) -> [String] {
        guard data.count >= 8 else { return [] }
        let beMagic = readUInt32(data, at: 0, littleEndian: false)
        let leMagic = readUInt32(data, at: 0, littleEndian: true)

        if leMagic == mhMagic || leMagic == mhMagic64 {
            let cpuType = readUInt32(data, at: 4, littleEndian: true)
            return [architectureName(cpuType)]
        }
        if beMagic == fatMagic || beMagic == fatMagic64 {
            let count = Int(readUInt32(data, at: 4, littleEndian: false))
            let stride = beMagic == fatMagic64 ? 32 : 20
            guard count >= 0, count <= 64, data.count >= 8 + count * stride else { return [] }
            return (0..<count).map { index in
                let cpu = readUInt32(data, at: 8 + index * stride, littleEndian: false)
                return architectureName(cpu)
            }.uniqued()
        }
        return []
    }

    public static func hasCryptID(in data: Data) -> Bool? {
        guard data.count >= 32 else { return nil }
        let magic = readUInt32(data, at: 0, littleEndian: true)
        guard magic == mhMagic || magic == mhMagic64 else { return nil }
        let is64 = magic == mhMagic64
        let commandsCount = Int(readUInt32(data, at: 16, littleEndian: true))
        var cursor = is64 ? 32 : 28
        for _ in 0..<min(commandsCount, 4096) {
            guard cursor + 8 <= data.count else { break }
            let cmd = readUInt32(data, at: cursor, littleEndian: true)
            let size = Int(readUInt32(data, at: cursor + 4, littleEndian: true))
            guard size >= 8, cursor + size <= data.count else { break }
            if cmd == 0x21 || cmd == 0x2C {
                guard cursor + 20 <= data.count else { return nil }
                return readUInt32(data, at: cursor + 16, littleEndian: true) != 0
            }
            cursor += size
        }
        return false
    }

    public static func extractXMLPlist(in data: Data) -> String? {
        let prefix = Data("<?xml".utf8)
        let alternate = Data("<plist".utf8)
        let start = data.range(of: prefix)?.lowerBound ?? data.range(of: alternate)?.lowerBound
        guard let start else { return nil }
        let suffix = Data("</plist>".utf8)
        guard let endRange = data.range(of: suffix, in: start..<data.endIndex) else { return nil }
        let end = endRange.upperBound
        return String(data: data[start..<end], encoding: .utf8)
    }

    private static func readUInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let bytes = [UInt8](data[offset..<(offset + 4)])
        if littleEndian {
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
        return UInt32(bytes[3]) | UInt32(bytes[2]) << 8 | UInt32(bytes[1]) << 16 | UInt32(bytes[0]) << 24
    }

    private static func architectureName(_ cpuType: UInt32) -> String {
        switch cpuType {
        case 0x0100000C: return "arm64"
        case 0x0200000C: return "arm64_32"
        case 12: return "arm"
        case 0x01000007: return "x86_64"
        case 7: return "x86"
        default: return String(format: "cpu-0x%08x", cpuType)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
