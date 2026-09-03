import Foundation

public enum ResourceResolverError: Error, Equatable {
    case invalidResourceID
    case unsupportedScheme(String)
    case appUnavailable(String)
    case containerUnavailable(String)
}

public protocol AppContainerResolving: Sendable {
    func installedApps() async -> [ResourceNode]
    func bundlePath(for bundleID: String) async -> String?
    func dataContainerPath(for bundleID: String) async -> String?
}

public protocol AppEnumerationCapabilityProviding: Sendable {
    func canEnumerateInstalledApps() async -> Bool
    func installedAppEnumerationDetail() async -> String
}

public extension AppEnumerationCapabilityProviding {
    func installedAppEnumerationDetail() async -> String { "Installed-app enumeration detail is unavailable." }
}

public protocol AppUninstallCapabilityProviding: Sendable {
    func canUninstallInstalledApps() async -> Bool
    func installedAppUninstallDetail() async -> String
}

public struct RootHelperCapabilitySnapshot: Sendable, Equatable {
    public var available: Bool
    public var detail: String

    public init(available: Bool, detail: String) {
        self.available = available
        self.detail = detail
    }
}

public protocol RootHelperCapabilityProviding: Sendable {
    func rootHelperCapability() async -> RootHelperCapabilitySnapshot
}

public actor ResourceResolver {
    private let appResolver: AppContainerResolving
    private let fileManager: FileManager

    public init(appResolver: AppContainerResolving, fileManager: FileManager = .default) {
        self.appResolver = appResolver
        self.fileManager = fileManager
    }

    public func resolve(_ id: ResourceID) async throws -> ResourceNode {
        guard let components = URLComponents(string: id.rawValue), let scheme = components.scheme else {
            throw ResourceResolverError.invalidResourceID
        }

        switch scheme {
        case "app":
            guard let bundleID = logicalHostAndPath(components) else { throw ResourceResolverError.invalidResourceID }
            guard let path = await appResolver.bundlePath(for: bundleID) else {
                throw ResourceResolverError.appUnavailable(bundleID)
            }
            return ResourceNode(
                id: id,
                kind: .app,
                displayName: bundleID,
                logicalLocation: id.rawValue,
                resolvedPath: path,
                ownerBundleID: bundleID
            )

        case "container":
            guard let bundleID = components.host, !bundleID.isEmpty else { throw ResourceResolverError.invalidResourceID }
            guard let basePath = await appResolver.dataContainerPath(for: bundleID) else {
                throw ResourceResolverError.containerUnavailable(bundleID)
            }
            let suffix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = URL(fileURLWithPath: basePath, isDirectory: true)
            let target = suffix.isEmpty ? root : root.appendingPathComponent(suffix)
            let resolved = target.standardizedFileURL.path
            return ResourceNode(
                id: id,
                kind: fileManager.directoryExists(at: target) ? .directory : .container,
                displayName: target.lastPathComponent.isEmpty ? bundleID : target.lastPathComponent,
                logicalLocation: id.rawValue,
                resolvedPath: resolved,
                ownerBundleID: bundleID,
                byteSize: try? fileManager.allocatedSizeOfItem(at: target)
            )

        case "file":
            let decoded = components.path.removingPercentEncoding ?? components.path
            let url = URL(fileURLWithPath: decoded)
            return ResourceNode(
                id: id,
                kind: fileManager.directoryExists(at: url) ? .directory : .file,
                displayName: url.lastPathComponent,
                logicalLocation: id.rawValue,
                resolvedPath: url.standardizedFileURL.path,
                byteSize: try? fileManager.allocatedSizeOfItem(at: url)
            )

        case "ipa":
            let decoded = components.path.removingPercentEncoding ?? components.path
            let url = URL(fileURLWithPath: decoded)
            return ResourceNode(
                id: id,
                kind: .ipa,
                displayName: url.lastPathComponent,
                logicalLocation: id.rawValue,
                resolvedPath: url.standardizedFileURL.path,
                byteSize: try? fileManager.allocatedSizeOfItem(at: url)
            )

        default:
            throw ResourceResolverError.unsupportedScheme(scheme)
        }
    }

    private func logicalHostAndPath(_ components: URLComponents) -> String? {
        if let host = components.host, !host.isEmpty { return host }
        let value = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.isEmpty ? nil : value
    }
}

public extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func allocatedSizeOfItem(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
