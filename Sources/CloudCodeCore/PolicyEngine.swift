import Foundation

public struct SensitivityClassifier: Sendable {
    private let sensitiveExtensions: Set<String> = [
        "plist", "sqlite", "sqlite3", "db", "realm", "mobileconfig", "entitlements", "ipa"
    ]

    private let sensitivePathFragments: [String] = [
        "/Library/Preferences/",
        "/Documents/",
        "/Containers/Data/Application/",
        "/Containers/Shared/AppGroup/",
        "/var/mobile/Library/",
        "/private/var/mobile/Library/"
    ]

    public init() {}

    public func isSensitive(path: String, operation: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let ext = URL(fileURLWithPath: normalized).pathExtension.lowercased()
        if sensitiveExtensions.contains(ext) { return true }
        if sensitivePathFragments.contains(where: { normalized.contains($0) }) { return true }

        let lowered = operation.lowercased()
        if lowered.contains("install") || lowered.contains("uninstall") || lowered.contains("terminate") || lowered.contains("send") || lowered.contains("upload") {
            return true
        }
        return false
    }
}

public struct PolicyEngine: Sendable {
    public let classifier: SensitivityClassifier

    public init(classifier: SensitivityClassifier = SensitivityClassifier()) {
        self.classifier = classifier
    }

    public func decision(
        mode: PermissionMode,
        tool: ToolDescriptor,
        targetPath: String? = nil,
        explicitlyPermanent: Bool = false
    ) -> PolicyDecision {
        if explicitlyPermanent || tool.risk == .permanentDestructive {
            return mode == .full ? .allow : .requireConfirmation
        }

        let sensitive = targetPath.map { classifier.isSensitive(path: $0, operation: tool.name) } ?? false

        switch mode {
        case .safe:
            if tool.risk == .readOnly { return .allow }
            if tool.risk == .safeWrite && !sensitive { return .allow }
            return .requireConfirmation
        case .balanced:
            if tool.risk <= .safeWrite && !sensitive { return .allow }
            if tool.risk == .destructive { return .allow }
            if sensitive || tool.risk >= .sensitiveWrite { return .requireConfirmation }
            return .allow
        case .full:
            return .allow
        }
    }

    public func requiresBackup(tool: ToolDescriptor, targetPath: String?) -> Bool {
        if tool.risk >= .sensitiveWrite { return true }
        if let targetPath, classifier.isSensitive(path: targetPath, operation: tool.name) { return true }
        return false
    }
}

public enum PathSafetyError: Error, Equatable, CustomStringConvertible {
    case emptyPath
    case rootPath
    case traversal
    case symlink
    case targetEscapesAllowedRoot
    case targetChangedAfterApproval
    case recursiveDeleteTooBroad
    case systemManagedApplicationContainer

    public var description: String {
        switch self {
        case .emptyPath: return "Empty path is not allowed"
        case .rootPath: return "Filesystem root cannot be targeted"
        case .traversal: return "Path traversal is not allowed"
        case .symlink: return "Symlink target is not allowed for this operation"
        case .targetEscapesAllowedRoot: return "Resolved target escapes the allowed root"
        case .targetChangedAfterApproval: return "Resolved target changed after approval; re-plan before writing"
        case .recursiveDeleteTooBroad: return "Recursive delete target is too broad"
        case .systemManagedApplicationContainer: return "Installed app bundles and top-level app data containers must be removed through apps.uninstall, not files.delete"
        }
    }
}

public struct PathGuard: Sendable {
    public init() {}

    public func validate(
        target: URL,
        allowedRoot: URL? = nil,
        rejectSymlink: Bool = true,
        recursiveDelete: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        let raw = target.path
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PathSafetyError.emptyPath }
        if raw == "/" { throw PathSafetyError.rootPath }
        if raw.split(separator: "/").contains("..") { throw PathSafetyError.traversal }

        let standardized = target.standardizedFileURL.resolvingSymlinksInPath()
        if standardized.path == "/" { throw PathSafetyError.rootPath }

        if let root = allowedRoot?.standardizedFileURL.resolvingSymlinksInPath() {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard standardized.path == root.path || standardized.path.hasPrefix(prefix) else {
                throw PathSafetyError.targetEscapesAllowedRoot
            }
        }

        if recursiveDelete {
            let componentCount = standardized.pathComponents.filter { $0 != "/" }.count
            if componentCount < 3 { throw PathSafetyError.recursiveDeleteTooBroad }
            if Self.isSystemManagedApplicationContainerTarget(standardized) {
                throw PathSafetyError.systemManagedApplicationContainer
            }
        }

        if rejectSymlink, fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw PathSafetyError.symlink }
        }

        return standardized
    }

    static func isSystemManagedApplicationContainerTarget(_ url: URL) -> Bool {
        let path = url.path.replacingOccurrences(of: "//", with: "/")
        let bundleMarkers = [
            "/private/var/containers/Bundle/Application/",
            "/var/containers/Bundle/Application/"
        ]
        for marker in bundleMarkers {
            guard let range = path.range(of: marker) else { continue }
            let suffix = String(path[range.upperBound...])
            let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
            if components.count == 1 { return true }
            if components.count == 2, components[1].lowercased().hasSuffix(".app") { return true }
        }

        let dataMarkers = [
            "/private/var/mobile/Containers/Data/Application/",
            "/var/mobile/Containers/Data/Application/"
        ]
        for marker in dataMarkers {
            guard let range = path.range(of: marker) else { continue }
            let suffix = String(path[range.upperBound...])
            let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
            if components.count == 1 { return true }
        }
        return false
    }
}

public enum ToolOutputTrust: String, Codable, Sendable {
    case trustedSystem
    case untrustedData
}

public struct ToolOutputEnvelope: Codable, Sendable {
    public var trust: ToolOutputTrust
    public var source: String
    public var content: String

    public init(trust: ToolOutputTrust, source: String, content: String) {
        self.trust = trust
        self.source = source
        self.content = content
    }

    public var promptSafeRepresentation: String {
        switch trust {
        case .trustedSystem:
            return content
        case .untrustedData:
            let object: [String: String] = [
                "trust": "untrusted_data",
                "source": source,
                "content": content
            ]
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let encoded = String(data: data, encoding: .utf8) {
                return encoded
            }
            return "{\"content\":\"unavailable\",\"source\":\"serialization_failed\",\"trust\":\"untrusted_data\"}"
        }
    }
}
