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

public struct CapabilityProbe: CapabilityProbing, @unchecked Sendable {
    private let appResolver: AppContainerResolving
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        appResolver: AppContainerResolving,
        fileManager: FileManager = .default,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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
        let enumerationDetail: String
        if let provider = appResolver as? any AppEnumerationCapabilityProviding {
            enumerationProven = await provider.canEnumerateInstalledApps()
            enumerationDetail = await provider.installedAppEnumerationDetail()
        } else {
            enumerationProven = !apps.isEmpty
            enumerationDetail = enumerationProven
                ? "Resolver returned \(apps.count) app records."
                : "Resolver returned no app records."
        }
        records.append(record("apps.enumerate", .apps, enumerationProven ? .available : .unavailable,
                              enumerationProven ? "Installed-app enumeration verified: \(enumerationDetail)" : "Installed-app enumeration not proven: \(enumerationDetail)"))

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
        let crossBundleStatus: CapabilityStatus = otherBundleResolved ? .available : (enumerationProven ? .deviceValidationRequired : .unavailable)
        let crossContainerStatus: CapabilityStatus = otherContainerResolved ? .available : (enumerationProven ? .deviceValidationRequired : .unavailable)
        records.append(record("apps.resolve_bundle_path", .apps, crossBundleStatus,
                              otherBundleResolved ? "Resolved at least one non-own installed-app bundle path." : (enumerationProven ? "Cross-app bundle path resolution is not proven on this runtime." : "Installed-app enumeration is unavailable, so cross-app bundle-path resolution is currently unavailable.")))
        records.append(record("apps.resolve_data_container", .apps, crossContainerStatus,
                              otherContainerResolved ? "Resolved at least one non-own installed-app data container; paths are resolved dynamically." : (enumerationProven ? "Cross-app data-container resolution is not proven on this runtime; container UUIDs are never cached as identity." : "Installed-app enumeration is unavailable, so cross-app data-container resolution is currently unavailable.")))

        records.append(record("execution.ios_system", .execution, Self.hasDynamicSymbol("ios_system") ? .available : .unavailable,
                              "Detected dynamically. Core tools do not require ios_system."))
        records.append(record("execution.posix_spawn_symbol", .execution, Self.hasDynamicSymbol("posix_spawn") ? .available : .unavailable,
                              "Only reports symbol presence; it does not prove sandbox escape or helper privilege."))
        records.append(record("execution.spawn_helper", .execution, .unavailable,
                              "This build does not bundle a helper executable, so helper spawning is not currently implemented."))
        records.append(record("execution.root_helper", .execution, .unavailable,
                              "This build does not bundle a root helper; TrollStore installation alone does not create one."))
        records.append(record("execution.jit_wasm", .execution, .unavailable,
                              "No WASM/JIT execution backend is connected in the current app build."))

        records.append(record("apps.launch", .apps, .unavailable,
                              "No app-launch executor is connected in the current build."))
        records.append(record("apps.terminate", .apps, .unavailable,
                              "No app-termination executor is connected in the current build."))
        if let provider = appResolver as? any AppUninstallCapabilityProviding {
            let uninstallReady = await provider.canUninstallInstalledApps()
            let uninstallDetail = await provider.installedAppUninstallDetail()
            let uninstallStatus: CapabilityStatus
            if uninstallReady {
                uninstallStatus = .available
            } else if !enumerationProven || uninstallDetail.contains("没有暴露") || uninstallDetail.contains("无法取得") {
                uninstallStatus = .unavailable
            } else {
                uninstallStatus = .deviceValidationRequired
            }
            records.append(record("apps.uninstall", .apps, uninstallStatus,
                                  uninstallReady ? "Private uninstall backend prerequisites are present and postcondition verification is available: \(uninstallDetail)" : "Uninstall backend is not currently executable: \(uninstallDetail)"))
        } else {
            records.append(record("apps.uninstall", .apps, .unavailable,
                                  "No uninstall adapter is connected in the current build."))
        }

        records.append(record("data.photos", .data, .deviceValidationRequired,
                              "PhotoKit authorization is user-controlled; app layer probes PHPhotoLibrary at runtime."))
        records.append(record("data.contacts", .data, .deviceValidationRequired,
                              "Contacts access is authorization-gated and not automatically requested by the core."))
        records.append(record("data.calendar", .data, .deviceValidationRequired,
                              "Calendar access is authorization-gated and not automatically requested by the core."))
        let keychainProbe = Self.probeOwnKeychain()
        records.append(record("data.keychain_scope", .data, keychainProbe.status, keychainProbe.detail))

        records.append(record("automation.url_scheme", .automation, .unavailable,
                              "The current URL-scheme executor is a disabled placeholder and cannot execute app actions."))
        records.append(record("automation.xctest_wda", .automation, .unavailable,
                              "No XCTest/WDA runtime backend is connected in this build."))
        records.append(record("automation.gui", .automation, .unavailable,
                              "The current GUI backend is explicitly unavailable; no automation runtime is connected."))

        records.append(record("ipa.inspect", .ipa, .available,
                              "ZIP/Info.plist inspection is implemented in-process."))
        records.append(record("ipa.decrypt", .ipa, .unavailable,
                              "No IPA decryption executor is connected in the current build."))
        records.append(record("ipa.install", .ipa, .unavailable,
                              "No IPA installation executor is connected in the current build."))

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

    private static func probeOwnKeychain() -> (status: CapabilityStatus, detail: String) {
        #if canImport(Security)
        let service = "CloudCodeIOS.CapabilityProbe"
        let account = UUID().uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = Data([0x43, 0x43])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            if addStatus == errSecMissingEntitlement {
                return (.unavailable, "Keychain runtime probe failed with errSecMissingEntitlement (-34018); the installed signature does not grant the required Keychain identity/access group.")
            }
            if addStatus == errSecInteractionNotAllowed {
                return (.unknown, "Keychain runtime probe could not run because the protected Keychain is currently unavailable (for example while the device is locked).")
            }
            return (.unavailable, "Keychain runtime probe failed with OSStatus \(addStatus).")
        }
        defer { SecItemDelete(query as CFDictionary) }

        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess, let data = result as? Data, data == Data([0x43, 0x43]) else {
            return (.unavailable, "Keychain write succeeded but read-back verification failed with OSStatus \(readStatus).")
        }
        return (.available, "Verified on this runtime by writing, reading and deleting a temporary item in Cloud Code's own Keychain scope.")
        #else
        return (.unknown, "Security framework is unavailable on this runtime, so Keychain capability cannot be proven.")
        #endif
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
