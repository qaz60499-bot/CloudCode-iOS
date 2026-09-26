import Foundation
import ZIPFoundation

public enum SpecializedSkillPackageError: Error, Equatable, Sendable {
    case unsupportedSource
    case invalidArchive
    case unsafeArchiveEntry(String)
    case archiveTooLarge
    case manifestMissing
    case manifestInvalid
    case reservedSkillID(String)
    case resourceMissing(String)
    case resourceTooLarge(String)
    case packageNotFound(String)
}

public struct SpecializedSkillPackageManifest: Codable, Equatable, Sendable {
    public struct TargetApp: Codable, Equatable, Sendable {
        public var name: String?
        public var bundleID: String?

        public init(name: String? = nil, bundleID: String? = nil) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    public struct Semantic: Codable, Equatable, Sendable {
        public var goal: String
        public var requiredSurface: String
        public var requiredCapabilities: [String]
        public var landmarks: [String]
        public var transitions: [SemanticSkillTransition]
        public var verificationObligations: [String]
        public var allowedLocalRecovery: [String]
        public var exactlyOnce: Bool

        public init(
            goal: String,
            requiredSurface: String,
            requiredCapabilities: [String],
            landmarks: [String] = [],
            transitions: [SemanticSkillTransition] = [],
            verificationObligations: [String] = [],
            allowedLocalRecovery: [String] = [],
            exactlyOnce: Bool = false
        ) {
            self.goal = goal
            self.requiredSurface = requiredSurface
            self.requiredCapabilities = requiredCapabilities
            self.landmarks = landmarks
            self.transitions = transitions
            self.verificationObligations = verificationObligations
            self.allowedLocalRecovery = allowedLocalRecovery
            self.exactlyOnce = exactlyOnce
        }
    }

    public struct Resources: Codable, Equatable, Sendable {
        public var instructions: String
        public var workflow: String?
        public var policy: String?
        public var agentConfig: String?

        public init(
            instructions: String = "SKILL.md",
            workflow: String? = "WORKFLOW.md",
            policy: String? = nil,
            agentConfig: String? = nil
        ) {
            self.instructions = instructions
            self.workflow = workflow
            self.policy = policy
            self.agentConfig = agentConfig
        }
    }

    public var schemaVersion: Int
    public var revision: String
    public var id: String
    public var displayName: String
    public var userSelectable: Bool
    public var targetApp: TargetApp?
    public var semantic: Semantic
    public var resources: Resources

    public init(
        schemaVersion: Int = 1,
        revision: String,
        id: String,
        displayName: String,
        userSelectable: Bool = true,
        targetApp: TargetApp? = nil,
        semantic: Semantic,
        resources: Resources = Resources()
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.id = id
        self.displayName = displayName
        self.userSelectable = userSelectable
        self.targetApp = targetApp
        self.semantic = semantic
        self.resources = resources
    }
}

public struct SpecializedSkillPackageSummary: Identifiable, Equatable, Sendable {
    public var id: String { manifest.id }
    public var manifest: SpecializedSkillPackageManifest
    public var directoryURL: URL

    public init(manifest: SpecializedSkillPackageManifest, directoryURL: URL) {
        self.manifest = manifest
        self.directoryURL = directoryURL
    }

    public var semanticSkill: SemanticSkillDefinition {
        SemanticSkillDefinition(
            id: manifest.id,
            displayName: manifest.displayName,
            semanticGoal: manifest.semantic.goal,
            bundleID: manifest.targetApp?.bundleID,
            requiredSemanticSurface: manifest.semantic.requiredSurface,
            requiredCapabilities: manifest.semantic.requiredCapabilities,
            landmarks: manifest.semantic.landmarks,
            transitions: manifest.semantic.transitions,
            verificationObligations: manifest.semantic.verificationObligations,
            allowedLocalRecovery: manifest.semantic.allowedLocalRecovery,
            exactlyOnce: manifest.semantic.exactlyOnce,
            userSelectable: manifest.userSelectable,
            origin: .installed
        )
    }
}

public actor SpecializedSkillPackageStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private let reservedSkillIDs: Set<String>
    private static let maxArchiveEntries = 96
    private static let maxPackageBytes: UInt64 = 8 * 1024 * 1024
    private static let maxManifestBytes = 256 * 1024
    private static let maxTextResourceBytes = 1024 * 1024

    public init(
        rootURL: URL,
        reservedSkillIDs: Set<String> = Set(SemanticSkillCatalog.predefined.map(\.id)),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.reservedSkillIDs = reservedSkillIDs
        self.fileManager = fileManager
    }

    public func all() throws -> [SpecializedSkillPackageSummary] {
        try ensureRoot()
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var packages: [SpecializedSkillPackageSummary] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            guard let summary = try? loadPackage(at: url) else { continue }
            packages.append(summary)
        }
        return packages.sorted { lhs, rhs in
            if lhs.manifest.displayName != rhs.manifest.displayName {
                return lhs.manifest.displayName.localizedStandardCompare(rhs.manifest.displayName) == .orderedAscending
            }
            return lhs.manifest.id < rhs.manifest.id
        }
    }

    public func definitions() throws -> [SemanticSkillDefinition] {
        try all().map(\.semanticSkill)
    }

    public func runtimeContext(skillID: String) throws -> String? {
        let packageURL = rootURL.appendingPathComponent(Self.directoryName(for: skillID), isDirectory: true)
        guard fileManager.fileExists(atPath: packageURL.path) else { return nil }
        let package = try loadPackage(at: packageURL)
        guard package.manifest.id == skillID else { throw SpecializedSkillPackageError.manifestInvalid }

        var parts: [String] = [
            "Installed specialist skill package: \(package.manifest.id)",
            "revision=\(package.manifest.revision)",
            "displayName=\(package.manifest.displayName)"
        ]
        let resources = package.manifest.resources
        let instructions = try readTextResource(resources.instructions, packageRoot: packageURL)
        parts.append("Selected Codex-style SKILL.md instructions:\n\(instructions)")
        if let workflow = resources.workflow, !workflow.isEmpty {
            parts.append("Selected specialist workflow reference:\n\(try readTextResource(workflow, packageRoot: packageURL))")
        }
        if let policy = resources.policy, !policy.isEmpty {
            parts.append("Selected specialist policy reference:\n\(try readTextResource(policy, packageRoot: packageURL))")
        }
        return parts.joined(separator: "\n\n")
    }

    @discardableResult
    public func install(from sourceURL: URL) throws -> SpecializedSkillPackageSummary {
        try ensureRoot()
        let staging = rootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let packageRoot: URL
        if sourceURL.pathExtension.lowercased() == "zip" {
            let extracted = staging.appendingPathComponent("archive", isDirectory: true)
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            try extractArchive(sourceURL, to: extracted)
            packageRoot = try resolvePackageRoot(in: extracted)
        } else {
            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SpecializedSkillPackageError.unsupportedSource
            }
            let copied = staging.appendingPathComponent("folder", isDirectory: true)
            try copyDirectoryBounded(from: sourceURL, to: copied)
            packageRoot = try resolvePackageRoot(in: copied)
        }

        let package = try loadPackage(at: packageRoot)
        if reservedSkillIDs.contains(package.manifest.id) {
            throw SpecializedSkillPackageError.reservedSkillID(package.manifest.id)
        }

        let target = rootURL.appendingPathComponent(Self.directoryName(for: package.manifest.id), isDirectory: true)
        let incoming = rootURL.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: packageRoot, to: incoming)
        let backup = rootURL.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        var movedOld = false
        do {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: target, to: backup)
                movedOld = true
            }
            try fileManager.moveItem(at: incoming, to: target)
            if movedOld { try? fileManager.removeItem(at: backup) }
        } catch {
            try? fileManager.removeItem(at: incoming)
            if movedOld, !fileManager.fileExists(atPath: target.path), fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
        return try loadPackage(at: target)
    }

    @discardableResult
    public func createTemplate(
        id: String,
        displayName: String,
        targetBundleID: String?,
        semanticGoal: String,
        instructions: String,
        workflow: String
    ) throws -> SpecializedSkillPackageSummary {
        try ensureRoot()
        let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = SpecializedSkillPackageManifest(
            revision: ISO8601DateFormatter().string(from: Date()),
            id: safeID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            targetApp: .init(bundleID: targetBundleID?.trimmingCharacters(in: .whitespacesAndNewlines)),
            semantic: .init(
                goal: semanticGoal.trimmingCharacters(in: .whitespacesAndNewlines),
                requiredSurface: "specialist.task",
                requiredCapabilities: [],
                verificationObligations: ["postcondition_verified"],
                allowedLocalRecovery: ["fresh_observation"]
            )
        )
        try validate(manifest)
        if reservedSkillIDs.contains(manifest.id) {
            throw SpecializedSkillPackageError.reservedSkillID(manifest.id)
        }

        let staging = rootURL.appendingPathComponent(".template-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("skill.json"), options: .atomic)
        try String(instructions.prefix(200_000)).write(to: staging.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try String(workflow.prefix(200_000)).write(to: staging.appendingPathComponent("WORKFLOW.md"), atomically: true, encoding: .utf8)

        let target = rootURL.appendingPathComponent(Self.directoryName(for: manifest.id), isDirectory: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: staging, to: target)
        return try loadPackage(at: target)
    }

    public func remove(skillID: String) throws {
        guard !reservedSkillIDs.contains(skillID) else {
            throw SpecializedSkillPackageError.reservedSkillID(skillID)
        }
        let target = rootURL.appendingPathComponent(Self.directoryName(for: skillID), isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else {
            throw SpecializedSkillPackageError.packageNotFound(skillID)
        }
        try fileManager.removeItem(at: target)
    }

    public func export(skillID: String, to destinationURL: URL) throws -> URL {
        let packageURL = rootURL.appendingPathComponent(Self.directoryName(for: skillID), isDirectory: true)
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw SpecializedSkillPackageError.packageNotFound(skillID)
        }
        _ = try loadPackage(at: packageURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = try Archive(url: destinationURL, accessMode: .create)
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw SpecializedSkillPackageError.invalidArchive }
        let root = packageURL.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var count = 0
        for case let item as URL in enumerator {
            count += 1
            guard count <= Self.maxArchiveEntries else { throw SpecializedSkillPackageError.archiveTooLarge }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SpecializedSkillPackageError.unsafeArchiveEntry(item.lastPathComponent) }
            guard values.isRegularFile == true else { continue }
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else { throw SpecializedSkillPackageError.unsafeArchiveEntry(item.path) }
            let relative = String(standardized.path.dropFirst(prefix.count)).replacingOccurrences(of: "\\", with: "/")
            guard Self.validArchiveEntryPath(relative) else { throw SpecializedSkillPackageError.unsafeArchiveEntry(relative) }
            try archive.addEntry(with: relative, fileURL: standardized, compressionMethod: .deflate)
        }
        return destinationURL
    }

    public static func archiveContainsSkillManifest(_ sourceURL: URL) throws -> Bool {
        guard sourceURL.pathExtension.lowercased() == "zip" else { return false }
        let archive = try Archive(url: sourceURL, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= maxArchiveEntries else { throw SpecializedSkillPackageError.archiveTooLarge }
        var total: UInt64 = 0
        var skillManifestPaths: [String] = []
        for entry in entries {
            guard validArchiveEntryPath(entry.path), entry.type != .symlink else {
                throw SpecializedSkillPackageError.unsafeArchiveEntry(entry.path)
            }
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= maxPackageBytes else { throw SpecializedSkillPackageError.archiveTooLarge }
            total = next
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            if normalized == "skill.json" || normalized.hasSuffix("/skill.json") {
                skillManifestPaths.append(normalized)
            }
        }
        guard skillManifestPaths.count == 1, let manifestPath = skillManifestPaths.first else { return false }
        let components = manifestPath.split(separator: "/")
        return components.count == 1 || components.count == 2
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func loadPackage(at packageURL: URL) throws -> SpecializedSkillPackageSummary {
        let manifestURL = packageURL.appendingPathComponent("skill.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw SpecializedSkillPackageError.manifestMissing
        }
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        guard data.count <= Self.maxManifestBytes else {
            throw SpecializedSkillPackageError.resourceTooLarge("skill.json")
        }
        let manifest: SpecializedSkillPackageManifest
        do { manifest = try JSONDecoder().decode(SpecializedSkillPackageManifest.self, from: data) }
        catch { throw SpecializedSkillPackageError.manifestInvalid }
        try validate(manifest)
        _ = try readTextResource(manifest.resources.instructions, packageRoot: packageURL)
        if let workflow = manifest.resources.workflow, !workflow.isEmpty {
            _ = try readTextResource(workflow, packageRoot: packageURL)
        }
        if let policy = manifest.resources.policy, !policy.isEmpty {
            _ = try readTextResource(policy, packageRoot: packageURL)
        }
        return SpecializedSkillPackageSummary(manifest: manifest, directoryURL: packageURL)
    }

    private func validate(_ manifest: SpecializedSkillPackageManifest) throws {
        guard manifest.schemaVersion == 1,
              Self.validSkillID(manifest.id),
              !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.displayName.count <= 128,
              manifest.userSelectable,
              !manifest.semantic.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.semantic.goal.count <= 128,
              !manifest.semantic.requiredSurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.semantic.requiredSurface.count <= 128,
              manifest.semantic.requiredCapabilities.count <= 16,
              manifest.semantic.landmarks.count <= 24,
              manifest.semantic.transitions.count <= 12,
              manifest.semantic.verificationObligations.count <= 12,
              manifest.semantic.allowedLocalRecovery.count <= 12,
              Self.validRelativeResourcePath(manifest.resources.instructions) else {
            throw SpecializedSkillPackageError.manifestInvalid
        }
        for path in [manifest.resources.workflow, manifest.resources.policy, manifest.resources.agentConfig].compactMap({ $0 }) where !path.isEmpty {
            guard Self.validRelativeResourcePath(path) else { throw SpecializedSkillPackageError.manifestInvalid }
        }
    }

    private func readTextResource(_ relativePath: String, packageRoot: URL) throws -> String {
        let url = try safeResourceURL(relativePath, packageRoot: packageRoot)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SpecializedSkillPackageError.resourceMissing(relativePath)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SpecializedSkillPackageError.resourceMissing(relativePath)
        }
        let size = values.fileSize ?? 0
        guard size >= 0, size <= Self.maxTextResourceBytes else {
            throw SpecializedSkillPackageError.resourceTooLarge(relativePath)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            throw SpecializedSkillPackageError.resourceMissing(relativePath)
        }
        return text
    }

    private func safeResourceURL(_ relativePath: String, packageRoot: URL) throws -> URL {
        guard Self.validRelativeResourcePath(relativePath) else {
            throw SpecializedSkillPackageError.manifestInvalid
        }
        let root = packageRoot.standardizedFileURL
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else { throw SpecializedSkillPackageError.manifestInvalid }
        return target
    }

    private func resolvePackageRoot(in container: URL) throws -> URL {
        let direct = container.appendingPathComponent("skill.json")
        if fileManager.fileExists(atPath: direct.path) { return container }
        let children = try fileManager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.filter { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return false }
            return fileManager.fileExists(atPath: child.appendingPathComponent("skill.json").path)
        }
        guard candidates.count == 1, let only = candidates.first else {
            throw SpecializedSkillPackageError.manifestMissing
        }
        return only
    }

    private func extractArchive(_ source: URL, to destination: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) }
        catch { throw SpecializedSkillPackageError.invalidArchive }
        let entries = Array(archive)
        guard entries.count <= Self.maxArchiveEntries else { throw SpecializedSkillPackageError.archiveTooLarge }
        var total: UInt64 = 0
        let root = destination.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for entry in entries {
            guard Self.validArchiveEntryPath(entry.path), entry.type != .symlink else {
                throw SpecializedSkillPackageError.unsafeArchiveEntry(entry.path)
            }
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= Self.maxPackageBytes else { throw SpecializedSkillPackageError.archiveTooLarge }
            total = next
            let target = root.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path == root.path || target.path.hasPrefix(prefix) else {
                throw SpecializedSkillPackageError.unsafeArchiveEntry(entry.path)
            }
            _ = try archive.extract(entry, to: target)
        }
    }

    private func copyDirectoryBounded(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw SpecializedSkillPackageError.unsupportedSource }
        var count = 0
        var total: UInt64 = 0
        let sourceRoot = source.standardizedFileURL
        let sourcePrefix = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
        for case let item as URL in enumerator {
            count += 1
            guard count <= Self.maxArchiveEntries else { throw SpecializedSkillPackageError.archiveTooLarge }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw SpecializedSkillPackageError.unsafeArchiveEntry(item.lastPathComponent) }
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(sourcePrefix) else { throw SpecializedSkillPackageError.unsafeArchiveEntry(item.path) }
            let relative = String(standardized.path.dropFirst(sourcePrefix.count)).replacingOccurrences(of: "\\", with: "/")
            guard Self.validArchiveEntryPath(relative) else { throw SpecializedSkillPackageError.unsafeArchiveEntry(relative) }
            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                let size = UInt64(max(0, values.fileSize ?? 0))
                let (next, overflow) = total.addingReportingOverflow(size)
                guard !overflow, next <= Self.maxPackageBytes else { throw SpecializedSkillPackageError.archiveTooLarge }
                total = next
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }

    private static func validSkillID(_ value: String) -> Bool {
        guard value.hasPrefix("skill."), value.count <= 128, value.count > "skill.".count else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    private static func validRelativeResourcePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 240, !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains(":") else { return false }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func validArchiveEntryPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 512, !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains(":") else { return false }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    private static func directoryName(for skillID: String) -> String {
        Data(skillID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
