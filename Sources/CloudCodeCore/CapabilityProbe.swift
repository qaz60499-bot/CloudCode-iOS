import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#endif

public protocol CapabilityProbing: Sendable {
    func probe() async -> CapabilityProfile
    func probeStartupSafe() async -> CapabilityProfile
    func probeExtendedDevice() async -> CapabilityProfile
    func probePrivileged() async -> CapabilityProfile
}

public extension CapabilityProbing {
    func probeStartupSafe() async -> CapabilityProfile { await probe() }
    func probeExtendedDevice() async -> CapabilityProfile { await probeStartupSafe() }
    func probePrivileged() async -> CapabilityProfile { await probe() }
}

public struct CapabilityProbe: CapabilityProbing, @unchecked Sendable {
    private let appResolver: AppContainerResolving
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let diagnosticLogger: DiagnosticLogStore?
    private let guiCapabilityProvider: (any GUIAutomationCapabilityProviding)?

    public init(
        appResolver: AppContainerResolving,
        fileManager: FileManager = .default,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        diagnosticLogger: DiagnosticLogStore? = nil,
        guiCapabilityProvider: (any GUIAutomationCapabilityProviding)? = nil
    ) {
        self.appResolver = appResolver
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.diagnosticLogger = diagnosticLogger
        self.guiCapabilityProvider = guiCapabilityProvider
    }

    public func probeStartupSafe() async -> CapabilityProfile {
        try? await diagnosticLogger?.log(level: .info, subsystem: "capability", action: "probe.startup-safe.start", result: "running")
        var records: [CapabilityRecord] = []

        records.append(record("filesystem.own_container", .filesystem, canReadAndWrite(homeDirectory) ? .available : .unavailable,
                              "Startup-safe read/write check against the app's own home directory."))
        records.append(record("filesystem.shared_user_files", .filesystem, .deviceValidationRequired,
                              "Deferred during automatic startup. No /var/mobile or cross-container path is touched by the startup-safe probe."))
        records.append(record("filesystem.unrestricted", .filesystem, .deviceValidationRequired,
                              "Deferred during automatic startup. A privileged write outside the app container is never attempted automatically."))

        records.append(record("apps.enumerate", .apps, .deviceValidationRequired,
                              "Cross-app LaunchServices enumeration is deferred until an explicit device-capability validation."))
        records.append(record("apps.resolve_own_bundle_path", .apps, .available,
                              "Cloud Code's own bundle path is available without private API probing."))
        records.append(record("apps.resolve_own_data_container", .apps, .available,
                              "Cloud Code's own data container is available without private API probing."))
        records.append(record("apps.resolve_bundle_path", .apps, .deviceValidationRequired,
                              "Cross-app bundle resolution is deferred during automatic startup."))
        records.append(record("apps.resolve_data_container", .apps, .deviceValidationRequired,
                              "Cross-app data-container resolution is deferred during automatic startup."))

        records.append(record("execution.ios_system", .execution, .deviceValidationRequired,
                              "Dynamic execution symbols are not inspected during automatic startup."))
        records.append(record("execution.posix_spawn_symbol", .execution, .deviceValidationRequired,
                              "Spawn/persona symbols are not inspected during automatic startup."))
        records.append(record("execution.spawn_helper", .execution, .deviceValidationRequired,
                              "Embedded root-helper spawning is deferred until explicit device validation."))
        records.append(record("execution.root_helper", .execution, .deviceValidationRequired,
                              "UID 0/persona validation is never executed automatically during app launch."))
        records.append(record("execution.jit_wasm", .execution, .unavailable,
                              "No WASM/JIT execution backend is connected in the current app build."))

        records.append(record("apps.launch", .apps, .deviceValidationRequired,
                              "Private app-launch capability is deferred until explicit device validation."))
        records.append(record("apps.terminate", .apps, .deviceValidationRequired,
                              "Privileged app-termination capability is deferred until explicit device validation."))
        records.append(record("apps.uninstall", .apps, .deviceValidationRequired,
                              "Privileged uninstall capability is deferred until explicit device validation."))

        records.append(record("data.photos", .data, .deviceValidationRequired,
                              "PhotoKit authorization is user-controlled and is not requested automatically."))
        records.append(record("data.contacts", .data, .deviceValidationRequired,
                              "Contacts access is authorization-gated and is not requested automatically."))
        records.append(record("data.calendar", .data, .deviceValidationRequired,
                              "Calendar access is authorization-gated and is not requested automatically."))
        records.append(record("data.keychain_scope", .data, .deviceValidationRequired,
                              "Keychain write/read/delete probing is deferred during automatic startup and runs only during explicit device validation."))

        records.append(record("automation.url_scheme", .automation, .unavailable,
                              "The current URL-scheme executor is a disabled placeholder and cannot execute app actions."))
        records.append(record("automation.xctest_wda", .automation, .unavailable,
                              "No XCTest/WDA runtime backend is connected in this build."))
        let deferredGUIStatus: CapabilityStatus = guiCapabilityProvider == nil ? .unavailable : .deviceValidationRequired
        let deferredGUIDetail = guiCapabilityProvider == nil
            ? "No GUI automation backend is connected in this build."
            : "GUI private-runtime probing is deferred during automatic startup and ordinary message send. Run explicit device validation before use."
        for feature in GUIAutomationFeature.allCases {
            records.append(record(feature.capabilityID, .automation, deferredGUIStatus, deferredGUIDetail))
        }
        records.append(record("automation.gui", .automation, deferredGUIStatus, deferredGUIDetail))
        records.append(record("ipa.inspect", .ipa, .available,
                              "ZIP/Info.plist inspection is implemented in-process."))
        records.append(record("ipa.decrypt", .ipa, .unavailable,
                              "No IPA decryption executor is connected in the current build."))
        records.append(record("ipa.install", .ipa, .unavailable,
                              "No IPA installation executor is connected in the current build."))
        records.append(record("network.urlsession", .network, .available,
                              "Foundation URLSession is available; no network request is required by this startup probe."))

        records.append(contentsOf: HomeOSCapabilityLayer.records(from: records))
        let profile = CapabilityProfile(records: records)
        for item in records {
            try? await diagnosticLogger?.log(
                level: .info,
                subsystem: "capability",
                action: item.id,
                result: item.status.rawValue,
                diagnostic: item.detail,
                metadata: ["domain": item.domain.rawValue, "mode": "startup-safe"]
            )
        }
        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "capability",
            action: "probe.startup-safe.finish",
            result: "completed",
            metadata: ["count": String(records.count)]
        )
        return profile
    }

    public func probeExtendedDevice() async -> CapabilityProfile {
        try? await diagnosticLogger?.log(level: .info, subsystem: "capability", action: "probe.extended.start", result: "running")
        var records = (await probeStartupSafe().records).filter { !$0.id.hasPrefix("homeos.") }

        func replacing(_ item: CapabilityRecord) {
            records.removeAll { $0.id == item.id }
            records.append(item)
        }

        let sharedCandidate = URL(fileURLWithPath: "/var/mobile/Media", isDirectory: true)
        replacing(record("filesystem.shared_user_files", .filesystem, fileManager.isReadableFile(atPath: sharedCandidate.path) ? .available : .unavailable,
                         "Explicit extended read-only visibility check for the user media area."))
        replacing(record("execution.ios_system", .execution, Self.hasDynamicSymbol("ios_system") ? .available : .unavailable,
                         "Explicit extended dynamic-symbol presence check; no command is executed."))
        replacing(record("execution.posix_spawn_symbol", .execution, Self.hasDynamicSymbol("posix_spawn") ? .available : .unavailable,
                         "Explicit extended spawn-symbol presence check; no helper is spawned."))

        let apps = await appResolver.installedApps()
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let enumerationProven: Bool
        let enumerationDetail: String
        if let provider = appResolver as? any AppEnumerationCapabilityProviding {
            enumerationProven = await provider.canEnumerateInstalledApps()
            enumerationDetail = await provider.installedAppEnumerationDetail()
        } else {
            let crossAppCount = apps.filter { node in
                guard let bundleID = node.ownerBundleID, !bundleID.isEmpty else { return false }
                return ownBundle.isEmpty || bundleID != ownBundle
            }.count
            enumerationProven = crossAppCount > 0
            enumerationDetail = enumerationProven
                ? "Resolver returned \(apps.count) app records including \(crossAppCount) non-own apps."
                : "Resolver did not prove visibility of any non-own installed app."
        }
        replacing(record("apps.enumerate", .apps, enumerationProven ? .available : .unavailable,
                         enumerationProven ? "Bounded isolated app enumeration verified: \(enumerationDetail)" : "Bounded isolated app enumeration not proven: \(enumerationDetail)"))

        let ownBundlePath = ownBundle.isEmpty ? nil : await appResolver.bundlePath(for: ownBundle)
        replacing(record("apps.resolve_own_bundle_path", .apps, ownBundlePath == nil ? .unknown : .available,
                         "Resolution of Cloud Code's own bundle path after explicit extended validation."))
        let ownDataPath = ownBundle.isEmpty ? nil : await appResolver.dataContainerPath(for: ownBundle)
        replacing(record("apps.resolve_own_data_container", .apps, ownDataPath == nil ? .unknown : .available,
                         "Resolution of Cloud Code's own data container after explicit extended validation."))

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
        replacing(record("apps.resolve_bundle_path", .apps, otherBundleResolved ? .available : (enumerationProven ? .deviceValidationRequired : .unavailable),
                         otherBundleResolved ? "Resolved at least one non-own installed-app bundle path through the bounded resolver." : "Cross-app bundle path resolution is not currently proven."))
        replacing(record("apps.resolve_data_container", .apps, otherContainerResolved ? .available : (enumerationProven ? .deviceValidationRequired : .unavailable),
                         otherContainerResolved ? "Resolved at least one non-own installed-app data container through the bounded resolver." : "Cross-app data-container resolution is not currently proven."))

        if let lifecycle = appResolver as? any AppLifecycleCapabilityProviding {
            let launch = await lifecycle.appLaunchCapability()
            replacing(record("apps.launch", .apps, launch.available ? .available : .deviceValidationRequired,
                             launch.available ? "Bounded isolated app-launch backend verified: \(launch.detail)" : "App launch still requires device validation: \(launch.detail)"))
        }

        // GUI private-runtime readiness is intentionally not probed in the extended stage.
        // It may require a TrollStore root/persona helper, so only the explicit privileged
        // validation stage is allowed to promote the startup-safe device_validation_required
        // placeholders to available/unavailable runtime evidence.

        records.append(contentsOf: HomeOSCapabilityLayer.records(from: records))
        let profile = CapabilityProfile(records: records)
        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "capability",
            action: "probe.extended.finish",
            result: "completed",
            metadata: ["count": String(records.count)]
        )
        return profile
    }

    public func probe() async -> CapabilityProfile {
        await probePrivileged()
    }

    public func probePrivileged() async -> CapabilityProfile {
        try? await diagnosticLogger?.log(level: .info, subsystem: "capability", action: "probe.privileged.start", result: "running")
        var records: [CapabilityRecord] = []

        records.append(record("filesystem.own_container", .filesystem, canReadAndWrite(homeDirectory) ? .available : .unavailable,
                              "Read/write probe against the app's home directory."))

        let sharedCandidate = URL(fileURLWithPath: "/var/mobile/Media", isDirectory: true)
        records.append(record("filesystem.shared_user_files", .filesystem, fileManager.isReadableFile(atPath: sharedCandidate.path) ? .available : .unavailable,
                              "Best-effort read probe for the user media area; exact access depends on entitlement and device."))

        let mobileRoot = URL(fileURLWithPath: "/var/mobile", isDirectory: true)
        records.append(record("filesystem.unrestricted", .filesystem, unrestrictedFilesystemProbe(root: mobileRoot) ? .available : .unavailable,
                              "Conservative direct read/write probe outside the app container. This does not imply root identity."))

        let apps = await appResolver.installedApps()
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let enumerationProven: Bool
        let enumerationDetail: String
        if let provider = appResolver as? any AppEnumerationCapabilityProviding {
            enumerationProven = await provider.canEnumerateInstalledApps()
            enumerationDetail = await provider.installedAppEnumerationDetail()
        } else {
            let crossAppCount = apps.filter { node in
                guard let bundleID = node.ownerBundleID, !bundleID.isEmpty else { return false }
                return ownBundle.isEmpty || bundleID != ownBundle
            }.count
            enumerationProven = crossAppCount > 0
            enumerationDetail = enumerationProven
                ? "Resolver returned \(apps.count) app records including \(crossAppCount) non-own apps."
                : "Resolver did not prove visibility of any non-own installed app."
        }
        records.append(record("apps.enumerate", .apps, enumerationProven ? .available : .unavailable,
                              enumerationProven ? "Installed-app enumeration verified: \(enumerationDetail)" : "Installed-app enumeration not proven: \(enumerationDetail)"))

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
        if let provider = appResolver as? any RootHelperCapabilityProviding {
            let helper = await provider.rootHelperCapability()
            let helperStatus: CapabilityStatus = helper.available ? .available : .deviceValidationRequired
            records.append(record("execution.spawn_helper", .execution, helperStatus,
                                  helper.available ? "Embedded helper spawn verified on this runtime: \(helper.detail)" : "Embedded helper exists but root spawn is not yet verified on this runtime: \(helper.detail)"))
            records.append(record("execution.root_helper", .execution, helperStatus,
                                  helper.available ? "Embedded helper executed with UID 0 on this runtime: \(helper.detail)" : "Root-helper execution requires a successful TrollStore persona/root probe: \(helper.detail)"))
        } else {
            records.append(record("execution.spawn_helper", .execution, .unavailable,
                                  "This build does not expose an embedded helper capability provider."))
            records.append(record("execution.root_helper", .execution, .unavailable,
                                  "This build does not expose an embedded root-helper capability provider."))
        }
        records.append(record("execution.jit_wasm", .execution, .unavailable,
                              "No WASM/JIT execution backend is connected in the current app build."))

        if let lifecycle = appResolver as? any AppLifecycleCapabilityProviding {
            let launch = await lifecycle.appLaunchCapability()
            let terminate = await lifecycle.appTerminateCapability()
            records.append(record("apps.launch", .apps, launch.available ? .available : .deviceValidationRequired,
                                  launch.available ? "App launch backend verified on this runtime: \(launch.detail)" : "App launch backend requires device validation: \(launch.detail)"))
            records.append(record("apps.terminate", .apps, terminate.available ? .available : .deviceValidationRequired,
                                  terminate.available ? "App termination backend verified on this runtime: \(terminate.detail)" : "App termination backend requires device validation: \(terminate.detail)"))
        } else {
            records.append(record("apps.launch", .apps, .unavailable,
                                  "No app-launch capability provider is connected in the current build."))
            records.append(record("apps.terminate", .apps, .unavailable,
                                  "No app-termination capability provider is connected in the current build."))
        }
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
        if let guiCapabilityProvider {
            let gui = await guiCapabilityProvider.guiCapabilitySnapshot()
            for feature in GUIAutomationFeature.allCases {
                records.append(record(feature.capabilityID, .automation, gui.status(feature), "\(gui.backendIdentifier): \(gui.detail(feature))"))
            }
            records.append(record("automation.gui", .automation, gui.compositeStatus,
                                  "Composite GUI readiness from \(gui.backendIdentifier); all observation/action/verification features must be available."))
        } else {
            for feature in GUIAutomationFeature.allCases {
                records.append(record(feature.capabilityID, .automation, .unavailable, "No GUI automation backend is connected in this build."))
            }
            records.append(record("automation.gui", .automation, .unavailable,
                                  "No GUI automation backend is connected in this build."))
        }

        records.append(record("ipa.inspect", .ipa, .available,
                              "ZIP/Info.plist inspection is implemented in-process."))
        records.append(record("ipa.decrypt", .ipa, .unavailable,
                              "No IPA decryption executor is connected in the current build."))
        records.append(record("ipa.install", .ipa, .unavailable,
                              "No IPA installation executor is connected in the current build."))

        records.append(record("network.urlsession", .network, .available,
                              "Foundation URLSession is linked and available to typed network/provider adapters; this proves API availability, not current internet reachability."))

        records.append(contentsOf: HomeOSCapabilityLayer.records(from: records))

        let profile = CapabilityProfile(records: records)
        for item in records {
            try? await diagnosticLogger?.log(
                level: .info,
                subsystem: "capability",
                action: item.id,
                result: item.status.rawValue,
                diagnostic: item.detail,
                metadata: ["domain": item.domain.rawValue]
            )
        }
        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "capability",
            action: "probe.privileged.finish",
            result: "completed",
            metadata: ["count": String(records.count)]
        )
        return profile
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
        guard fileManager.isReadableFile(atPath: sensitiveProbe.path), fileManager.isWritableFile(atPath: sensitiveProbe.path) else { return false }

        let canary = sensitiveProbe.appendingPathComponent(".cloudcode-capability-\(UUID().uuidString)")
        let bytes = Data([0x43, 0x43, 0x50, 0x52])
        do {
            try bytes.write(to: canary, options: [.atomic, .withoutOverwriting])
            defer { try? fileManager.removeItem(at: canary) }
            let actual = try Data(contentsOf: canary)
            return actual == bytes
        } catch {
            try? fileManager.removeItem(at: canary)
            return false
        }
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
