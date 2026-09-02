import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#endif

public protocol CapabilityProbing: Sendable {
    func probe() async -> CapabilityProfile
}

public struct CapabilityProbe: CapabilityProbing, Sendable {
    private let appResolver: AppContainerResolving
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        appResolver: AppContainerResolving,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.appResolver = appResolver
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    public func probe() async -> CapabilityProfile {
        var records: [CapabilityRecord] = []

        records.append(record("filesystem.own_container", .filesystem, canReadAndWrite(homeDirectory) ? .available : .unavailable,
                              "Read/write probe against the app's home directory."))

        let sharedCandidate = URL(fileURLWithPath: "/var/mobile/Media", isDirectory: true)
        records.append(record("filesystem.shared_user_files", .filesystem, fileManager.isReadableFile(atPath: sharedCandidate.path) ? .available : .unavailable,
                              "Best-effort read probe for the user media area; exact access depends on entitlement and device."))

        let mobileRoot = URL(fileURLWithPath: "/var/mobile", isDirectory: true)
        records.append(record("filesystem.unrestricted", .filesystem, unrestrictedFilesystemProbe(root: mobileRoot) ? .available : .unavailable,
                              "Conservative direct filesystem probe. This does not imply root identity."))

        let apps = await appResolver.installedApps()
        let enumerationProven: Bool
        if let provider = appResolver as? any AppEnumerationCapabilityProviding {
            enumerationProven = await provider.canEnumerateInstalledApps()
        } else {
            enumerationProven = !apps.isEmpty
        }
        records.append(record("apps.enumerate", .apps, enumerationProven ? .available : .unavailable,
                              enumerationProven ? "Installed-app enumeration backend returned \(apps.count) apps." : "Only fallback/own-app visibility is available; installed-app enumeration is not proven."))

        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let ownBundlePath = ownBundle.isEmpty ? nil : await appResolver.bundlePath(for: ownBundle)
        records.append(record("apps.resolve_own_bundle_path", .apps, ownBundlePath == nil ? .unknown : .available,
                              "Resolution of Cloud Code's own bundle path."))

        let ownDataPath = ownBundle.isEmpty ? nil : await appResolver.dataContainerPath(for: ownBundle)
        records.append(record("apps.resolve_own_data_container", .apps, ownDataPath == nil ? .unknown : .available,
                              "Resolution of Cloud Code's own data container."))

        var otherBundleResolved = false
        var otherContainerResolved = false
        if enumerationProven {
            for app in apps where app.ownerBundleID != ownBundle {
                guard let bundleID = app.ownerBundleID else { continue }
                if await appResolver.bundlePath(for: bundleID) != nil { otherBundleResolved = true }
                if await appResolver.dataContainerPath(for: bundleID) != nil { otherContainerResolved = true }
                if otherBundleResolved && otherContainerResolved { break }
            }
        }
        records.append(record("apps.resolve_bundle_path", .apps, otherBundleResolved ? .available : .deviceValidationRequired,
                              otherBundleResolved ? "Resolved at least one non-own installed-app bundle path." : "Cross-app bundle path resolution is not proven on this runtime."))
        records.append(record("apps.resolve_data_container", .apps, otherContainerResolved ? .available : .deviceValidationRequired,
                              otherContainerResolved ? "Resolved at least one non-own installed-app data container; paths are resolved dynamically." : "Cross-app data-container resolution is not proven on this runtime; container UUIDs are never cached as identity."))

        records.append(record("execution.ios_system", .execution, Self.hasDynamicSymbol("ios_system") ? .available : .unavailable,
                              "Detected dynamically. Core tools do not require ios_system."))
        records.append(record("execution.posix_spawn_symbol", .execution, Self.hasDynamicSymbol("posix_spawn") ? .available : .unavailable,
                              "Only reports symbol presence; it does not prove sandbox escape or helper privilege."))
        records.append(record("execution.spawn_helper", .execution, .deviceValidationRequired,
                              "A bundled helper and device signing/entitlement path must prove helper spawn before use."))
        records.append(record("execution.root_helper", .execution, .deviceValidationRequired,
                              "Requires TrollStore/high-privilege device validation and a bundled helper. Root is never inferred from TrollStore alone."))
        records.append(record("execution.jit_wasm", .execution, .deviceValidationRequired,
                              "WASM/JIT availability varies by device, signing path and entitlement."))

        records.append(record("apps.launch", .apps, .deviceValidationRequired,
                              "Private LaunchServices/UIApplication launch behavior must be verified on device."))
        records.append(record("apps.terminate", .apps, .deviceValidationRequired,
                              "Termination is privileged/system-changing and must be verified on device."))

        records.append(record("data.photos", .data, .deviceValidationRequired,
                              "PhotoKit authorization is user-controlled; app layer probes PHPhotoLibrary at runtime."))
        records.append(record("data.contacts", .data, .deviceValidationRequired,
                              "Contacts access is authorization-gated and not automatically requested by the core."))
        records.append(record("data.calendar", .data, .deviceValidationRequired,
                              "Calendar access is authorization-gated and not automatically requested by the core."))
        records.append(record("data.keychain_scope", .data, .available,
                              "The app can use its own Keychain scope; cross-app Keychain access is not assumed."))

        records.append(record("automation.url_scheme", .automation, .available,
                              "URL opening is available through the app adapter, subject to iOS policy."))
        records.append(record("automation.xctest_wda", .automation, .deviceValidationRequired,
                              "XCTest/WDA requires a separate runtime/backend and is never assumed."))
        records.append(record("automation.gui", .automation, .deviceValidationRequired,
                              "GUI fallback is adapter-based and unavailable unless a backend proves readiness."))

        records.append(record("ipa.inspect", .ipa, .available,
                              "ZIP/Info.plist inspection is implemented in-process."))
        records.append(record("ipa.decrypt", .ipa, .deviceValidationRequired,
                              "Decryption requires a compatible privileged runtime and running target process."))
        records.append(record("ipa.install", .ipa, .deviceValidationRequired,
                              "Installation depends on TrollStore/privileged device capability."))

        return CapabilityProfile(records: records)
    }

    private func record(_ id: String, _ domain: CapabilityDomain, _ status: CapabilityStatus, _ detail: String) -> CapabilityRecord {
        CapabilityRecord(id: id, domain: domain, status: status, detail: detail)
    }

    private func canReadAndWrite(_ directory: URL) -> Bool {
        guard fileManager.isReadableFile(atPath: directory.path), fileManager.isWritableFile(atPath: directory.path) else { return false }
        return true
    }

    private func unrestrictedFilesystemProbe(root: URL) -> Bool {
        guard fileManager.isReadableFile(atPath: root.path) else { return false }
        let sensitiveProbe = root.appendingPathComponent("Library/Preferences", isDirectory: true)
        return fileManager.isReadableFile(atPath: sensitiveProbe.path)
    }

    private static func hasDynamicSymbol(_ name: String) -> Bool {
        #if canImport(Darwin)
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        return name.withCString { dlsym(handle, $0) != nil }
        #else
        return false
        #endif
    }
}

public struct StaticAppResolver: AppContainerResolving, Sendable {
    public var apps: [ResourceNode]
    public var bundlePaths: [String: String]
    public var containerPaths: [String: String]

    public init(apps: [ResourceNode] = [], bundlePaths: [String: String] = [:], containerPaths: [String: String] = [:]) {
        self.apps = apps
        self.bundlePaths = bundlePaths
        self.containerPaths = containerPaths
    }

    public func installedApps() async -> [ResourceNode] { apps }
    public func bundlePath(for bundleID: String) async -> String? { bundlePaths[bundleID] }
    public func dataContainerPath(for bundleID: String) async -> String? { containerPaths[bundleID] }
}
