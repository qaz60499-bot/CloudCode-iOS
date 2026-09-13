import Foundation
import ZIPFoundation

public enum ProviderBackend: String, Codable, CaseIterable, Sendable {
    case network
    case appBacked = "app_backed"
    case localModel = "local_model"
}

public enum AppBackedProviderAvailabilityState: String, Codable, CaseIterable, Sendable {
    case notInstalled = "NOT_INSTALLED"
    case needsAuthorization = "NEEDS_AUTHORIZATION"
    case needsLogin = "NEEDS_LOGIN"
    case ready = "READY"
    case busy = "BUSY"
    case degraded = "DEGRADED"
    case needsPluginUpdate = "NEEDS_PLUGIN_UPDATE"
    case timeout = "TIMEOUT"
}

public enum AppBackedProviderHostState: String, Codable, CaseIterable, Sendable {
    case idle = "IDLE"
    case checkInstalled = "CHECK_INSTALLED"
    case checkAuthorization = "CHECK_AUTHORIZATION"
    case checkCompatibility = "CHECK_COMPATIBILITY"
    case launchApp = "LAUNCH_APP"
    case verifyForeground = "VERIFY_FOREGROUND"
    case verifyLogin = "VERIFY_LOGIN"
    case prepareSession = "PREPARE_SESSION"
    case locateComposer = "LOCATE_COMPOSER"
    case submit = "SUBMIT"
    case verifySubmission = "VERIFY_SUBMISSION"
    case waitGenerationStart = "WAIT_GENERATION_START"
    case waitGeneration = "WAIT_GENERATION"
    case extractResponse = "EXTRACT_RESPONSE"
    case validateResponse = "VALIDATE_RESPONSE"
    case restoreTarget = "RESTORE_TARGET"
    case done = "DONE"
    case classify = "CLASSIFY"
}

public enum AppProviderSelectorStrategy: String, Codable, CaseIterable, Sendable {
    case accessibilityIdentifier = "accessibility_identifier"
    case axRole = "ax_role"
    case semanticLabel = "semantic_label"
    case visibleText = "visible_text"
    case relativeLayout = "relative_layout"
    case ocrText = "ocr_text"
    case coordinateFallback = "coordinate_fallback"
}

public struct AppProviderCoordinateFallback: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var deviceClass: String
    public var orientation: String
    public var appVersion: String
    public var screenWidth: Double
    public var screenHeight: Double

    public init(
        x: Double,
        y: Double,
        deviceClass: String,
        orientation: String,
        appVersion: String,
        screenWidth: Double,
        screenHeight: Double
    ) {
        self.x = x
        self.y = y
        self.deviceClass = deviceClass
        self.orientation = orientation
        self.appVersion = appVersion
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

public struct AppProviderSelector: Codable, Equatable, Sendable {
    public var strategy: AppProviderSelectorStrategy
    public var value: String?
    public var role: String?
    public var traits: [String]
    public var relation: String?
    public var coordinate: AppProviderCoordinateFallback?
    public var minimumConfidence: Double

    public init(
        strategy: AppProviderSelectorStrategy,
        value: String? = nil,
        role: String? = nil,
        traits: [String] = [],
        relation: String? = nil,
        coordinate: AppProviderCoordinateFallback? = nil,
        minimumConfidence: Double = 0.75
    ) {
        self.strategy = strategy
        self.value = value
        self.role = role
        self.traits = traits
        self.relation = relation
        self.coordinate = coordinate
        self.minimumConfidence = minimumConfidence
    }
}

public struct AppProviderSelectorSet: Codable, Equatable, Sendable {
    public var composer: [AppProviderSelector]
    public var send: [AppProviderSelector]
    public var newConversation: [AppProviderSelector]
    public var generationStart: [AppProviderSelector]
    public var generationComplete: [AppProviderSelector]
    public var response: [AppProviderSelector]
    public var copyButton: [AppProviderSelector]
    public var readyIndicators: [AppProviderSelector]
    public var needsLoginIndicators: [AppProviderSelector]
    public var errorIndicators: [AppProviderSelector]

    public init(
        composer: [AppProviderSelector] = [],
        send: [AppProviderSelector] = [],
        newConversation: [AppProviderSelector] = [],
        generationStart: [AppProviderSelector] = [],
        generationComplete: [AppProviderSelector] = [],
        response: [AppProviderSelector] = [],
        copyButton: [AppProviderSelector] = [],
        readyIndicators: [AppProviderSelector] = [],
        needsLoginIndicators: [AppProviderSelector] = [],
        errorIndicators: [AppProviderSelector] = []
    ) {
        self.composer = composer
        self.send = send
        self.newConversation = newConversation
        self.generationStart = generationStart
        self.generationComplete = generationComplete
        self.response = response
        self.copyButton = copyButton
        self.readyIndicators = readyIndicators
        self.needsLoginIndicators = needsLoginIndicators
        self.errorIndicators = errorIndicators
    }
}

public enum AppProviderResponseExtractorKind: String, Codable, Sendable {
    case axText = "ax_text"
    case copyClipboard = "copy_clipboard"
    case ocrRegion = "ocr_region"
}

public struct AppProviderNormalizedRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AppProviderResponseExtractor: Codable, Equatable, Sendable {
    public var kind: AppProviderResponseExtractorKind
    public var selectors: [AppProviderSelector]
    public var region: AppProviderNormalizedRegion?
    public var minimumCharacters: Int

    public init(
        kind: AppProviderResponseExtractorKind,
        selectors: [AppProviderSelector] = [],
        region: AppProviderNormalizedRegion? = nil,
        minimumCharacters: Int = 1
    ) {
        self.kind = kind
        self.selectors = selectors
        self.region = region
        self.minimumCharacters = minimumCharacters
    }
}

public struct AppProviderWorkflow: Codable, Equatable, Sendable {
    public var requestPrefix: String
    public var requestSuffix: String
    public var responseStartMarker: String
    public var responseEndMarker: String
    public var generationStartTimeoutSeconds: Double
    public var generationTimeoutSeconds: Double
    public var stableWindowSeconds: Double
    public var pollIntervalSeconds: Double
    public var retryBudget: Int
    public var preferNewConversation: Bool

    public init(
        requestPrefix: String = "",
        requestSuffix: String = "",
        responseStartMarker: String = "",
        responseEndMarker: String = "",
        generationStartTimeoutSeconds: Double = 20,
        generationTimeoutSeconds: Double = 180,
        stableWindowSeconds: Double = 2,
        pollIntervalSeconds: Double = 0.75,
        retryBudget: Int = 1,
        preferNewConversation: Bool = true
    ) {
        self.requestPrefix = requestPrefix
        self.requestSuffix = requestSuffix
        self.responseStartMarker = responseStartMarker
        self.responseEndMarker = responseEndMarker
        self.generationStartTimeoutSeconds = generationStartTimeoutSeconds
        self.generationTimeoutSeconds = generationTimeoutSeconds
        self.stableWindowSeconds = stableWindowSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.retryBudget = retryBudget
        self.preferNewConversation = preferNewConversation
    }
}

public struct AppProviderRecoveryRule: Codable, Equatable, Sendable {
    public var failure: String
    public var action: String
    public var maxAttempts: Int

    public init(failure: String, action: String, maxAttempts: Int = 1) {
        self.failure = failure
        self.action = action
        self.maxAttempts = maxAttempts
    }
}

public struct AppProviderRecoveryDocument: Codable, Equatable, Sendable {
    public var rules: [AppProviderRecoveryRule]

    public init(rules: [AppProviderRecoveryRule] = []) {
        self.rules = rules
    }
}

public struct AppProviderCompatibility: Codable, Equatable, Sendable {
    public var testedAppVersion: String?
    public var minimumAppVersion: String?
    public var maximumAppVersion: String?
    public var selectorRevision: String

    public init(
        testedAppVersion: String? = nil,
        minimumAppVersion: String? = nil,
        maximumAppVersion: String? = nil,
        selectorRevision: String = "1"
    ) {
        self.testedAppVersion = testedAppVersion
        self.minimumAppVersion = minimumAppVersion
        self.maximumAppVersion = maximumAppVersion
        self.selectorRevision = selectorRevision
    }
}

public struct AppProviderPackageResources: Codable, Equatable, Sendable {
    public var selectors: String
    public var workflow: String
    public var recovery: String
    public var prompts: String?

    public init(
        selectors: String = "selectors.json",
        workflow: String = "workflow.json",
        recovery: String = "recovery.json",
        prompts: String? = "prompts.md"
    ) {
        self.selectors = selectors
        self.workflow = workflow
        self.recovery = recovery
        self.prompts = prompts
    }
}

public struct AppProviderPackageManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var revision: String
    public var id: String
    public var displayName: String
    public var bundleID: String
    public var launchSchemes: [String]
    public var requiresLogin: Bool
    public var modelLabel: String
    public var declaredCapabilities: [String]
    public var compatibility: AppProviderCompatibility
    public var responseExtractors: [AppProviderResponseExtractor]
    public var supportsBackgroundGeneration: Bool
    public var resources: AppProviderPackageResources

    public init(
        schemaVersion: Int = 1,
        revision: String,
        id: String,
        displayName: String,
        bundleID: String,
        launchSchemes: [String] = [],
        requiresLogin: Bool = true,
        modelLabel: String = "Current App Mode",
        declaredCapabilities: [String],
        compatibility: AppProviderCompatibility = AppProviderCompatibility(),
        responseExtractors: [AppProviderResponseExtractor],
        supportsBackgroundGeneration: Bool = false,
        resources: AppProviderPackageResources = AppProviderPackageResources()
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.launchSchemes = launchSchemes
        self.requiresLogin = requiresLogin
        self.modelLabel = modelLabel
        self.declaredCapabilities = declaredCapabilities
        self.compatibility = compatibility
        self.responseExtractors = responseExtractors
        self.supportsBackgroundGeneration = supportsBackgroundGeneration
        self.resources = resources
    }
}

public struct AppProviderPackageSummary: Identifiable, Equatable, Sendable {
    public var id: String { manifest.id }
    public var manifest: AppProviderPackageManifest
    public var enabled: Bool
    public var directoryURL: URL

    public init(manifest: AppProviderPackageManifest, enabled: Bool, directoryURL: URL) {
        self.manifest = manifest
        self.enabled = enabled
        self.directoryURL = directoryURL
    }
}

public struct AppProviderPackage: Equatable, Sendable {
    public var summary: AppProviderPackageSummary
    public var selectors: AppProviderSelectorSet
    public var workflow: AppProviderWorkflow
    public var recovery: AppProviderRecoveryDocument
    public var prompts: String?

    public init(
        summary: AppProviderPackageSummary,
        selectors: AppProviderSelectorSet,
        workflow: AppProviderWorkflow,
        recovery: AppProviderRecoveryDocument,
        prompts: String?
    ) {
        self.summary = summary
        self.selectors = selectors
        self.workflow = workflow
        self.recovery = recovery
        self.prompts = prompts
    }
}

public struct AppBackedProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var packageID: String
    public var displayName: String
    public var bundleID: String
    public var modelLabel: String
    public var agentSessionID: UUID
    public var restoreTargetBundleID: String?

    public init(
        id: UUID = UUID(),
        packageID: String,
        displayName: String,
        bundleID: String,
        modelLabel: String = "Current App Mode",
        agentSessionID: UUID,
        restoreTargetBundleID: String? = nil
    ) {
        self.id = id
        self.packageID = packageID
        self.displayName = displayName
        self.bundleID = bundleID
        self.modelLabel = modelLabel
        self.agentSessionID = agentSessionID
        self.restoreTargetBundleID = restoreTargetBundleID
    }
}

public enum ProviderExecutionConfiguration: Equatable, Sendable {
    case network(ProviderConfiguration)
    case appBacked(AppBackedProviderConfiguration)

    public var backend: ProviderBackend {
        switch self {
        case .network: return .network
        case .appBacked: return .appBacked
        }
    }

    public var name: String {
        switch self {
        case .network(let value): return value.name
        case .appBacked(let value): return value.displayName
        }
    }

    public var model: String {
        switch self {
        case .network(let value): return value.model
        case .appBacked(let value): return value.modelLabel
        }
    }

    public var providerID: String? {
        switch self {
        case .network(let value): return value.providerID
        case .appBacked(let value): return value.packageID
        }
    }

    public var reasoningEffort: ModelReasoningEffort {
        switch self {
        case .network(let value): return value.reasoningEffort ?? .automatic
        case .appBacked: return .automatic
        }
    }

    public var baseURL: URL? {
        if case .network(let value) = self { return value.baseURL }
        return nil
    }

    public var protocolName: String? {
        if case .network(let value) = self { return value.protocolName }
        return nil
    }

    public var authModeName: String? {
        if case .network(let value) = self { return value.authModeName }
        return nil
    }

    public var apiKeyReference: String? {
        if case .network(let value) = self { return value.apiKeyReference }
        return nil
    }

    public var fallbackAPIKeyReferences: [String] {
        if case .network(let value) = self { return value.fallbackAPIKeyReferences ?? [] }
        return []
    }

    public var fallbackProtocolNames: [String] {
        if case .network(let value) = self { return value.fallbackProtocolNames ?? [] }
        return []
    }

    public var allowSameProviderKeyFailover: Bool {
        if case .network(let value) = self { return value.allowSameProviderKeyFailover == true }
        return false
    }

    public var appBackedPackageID: String? {
        if case .appBacked(let value) = self { return value.packageID }
        return nil
    }

    public var appBackedBundleID: String? {
        if case .appBacked(let value) = self { return value.bundleID }
        return nil
    }
}

public enum AppProviderPackageError: Error, Equatable, Sendable {
    case unsupportedSource
    case invalidArchive
    case unsafeArchiveEntry(String)
    case archiveTooLarge
    case manifestMissing
    case manifestInvalid
    case resourceMissing(String)
    case resourceTooLarge(String)
    case unknownCapability(String)
    case unexpectedResource(String)
    case packageNotFound(String)
}

public actor AppProviderPackageStore {
    public static let supportedCapabilities: Set<String> = [
        "app.launch",
        "gui.ax.read",
        "gui.touch",
        "gui.textInput",
        "screenshot",
        "clipboard.read"
    ]

    private struct StateFile: Codable {
        var disabledIDs: [String]
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private static let maxArchiveEntries = 96
    private static let maxPackageBytes: UInt64 = 8 * 1024 * 1024
    private static let maxManifestBytes = 256 * 1024
    private static let maxResourceBytes = 1024 * 1024

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func all() throws -> [AppProviderPackageSummary] {
        try ensureRoot()
        let disabled = disabledIDs()
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var result: [AppProviderPackageSummary] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let package = try? loadPackage(at: url) else { continue }
            var summary = package.summary
            summary.enabled = !disabled.contains(summary.id)
            result.append(summary)
        }
        return result.sorted { lhs, rhs in
            if lhs.manifest.displayName != rhs.manifest.displayName {
                return lhs.manifest.displayName.localizedStandardCompare(rhs.manifest.displayName) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    public func package(id: String) throws -> AppProviderPackage {
        let url = rootURL.appendingPathComponent(Self.directoryName(for: id), isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else { throw AppProviderPackageError.packageNotFound(id) }
        var package = try loadPackage(at: url)
        package.summary.enabled = !disabledIDs().contains(id)
        return package
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        _ = try package(id: id)
        var disabled = disabledIDs()
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        try persistDisabledIDs(disabled)
    }

    @discardableResult
    public func install(from sourceURL: URL) throws -> AppProviderPackageSummary {
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
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppProviderPackageError.unsupportedSource }
            let copied = staging.appendingPathComponent("folder", isDirectory: true)
            try copyDirectoryBounded(from: sourceURL, to: copied)
            packageRoot = try resolvePackageRoot(in: copied)
        }

        let package = try loadPackage(at: packageRoot)
        let target = rootURL.appendingPathComponent(Self.directoryName(for: package.summary.id), isDirectory: true)
        let incoming = rootURL.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        let backup = rootURL.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: packageRoot, to: incoming)
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
        var summary = try loadPackage(at: target).summary
        summary.enabled = !disabledIDs().contains(summary.id)
        return summary
    }

    @discardableResult
    public func createTemplate(
        id: String,
        displayName: String,
        bundleID: String,
        launchSchemes: [String] = [],
        testedAppVersion: String? = nil
    ) throws -> AppProviderPackageSummary {
        try ensureRoot()
        let revision = ISO8601DateFormatter().string(from: Date()) + "-" + UUID().uuidString
        let manifest = AppProviderPackageManifest(
            revision: revision,
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
            launchSchemes: launchSchemes,
            requiresLogin: false,
            declaredCapabilities: ["app.launch", "gui.ax.read", "gui.touch", "gui.textInput", "screenshot", "clipboard.read"],
            compatibility: AppProviderCompatibility(testedAppVersion: testedAppVersion, selectorRevision: "1"),
            responseExtractors: [
                AppProviderResponseExtractor(kind: .axText),
                AppProviderResponseExtractor(kind: .copyClipboard),
                AppProviderResponseExtractor(kind: .ocrRegion)
            ]
        )
        try validate(manifest)
        let selectors = AppProviderSelectorSet()
        let workflow = AppProviderWorkflow(
            requestPrefix: "CLOUDCODE_REQUEST_ID={{request_id}}\n",
            requestSuffix: "\nReturn only the requested answer or Cloud Code tool-call JSON. Do not claim device actions were executed.",
            responseStartMarker: "",
            responseEndMarker: "",
            retryBudget: 1,
            preferNewConversation: true
        )
        let recovery = AppProviderRecoveryDocument(rules: [
            .init(failure: "foreground_mismatch", action: "relaunch_once", maxAttempts: 1),
            .init(failure: "selector_mismatch", action: "stop_and_mark_needs_plugin_update", maxAttempts: 0),
            .init(failure: "generation_timeout", action: "stop_and_mark_timeout", maxAttempts: 0)
        ])
        let staging = rootURL.appendingPathComponent(".template-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try writePackageFiles(manifest: manifest, selectors: selectors, workflow: workflow, recovery: recovery, prompts: "# App Provider Prompts\n\nUse a request nonce and never assume prior chat text belongs to the current Cloud Code request.\n", to: staging)
        return try install(from: staging)
    }

    @discardableResult
    public func updateSetup(
        id: String,
        selectors: AppProviderSelectorSet,
        requiresLogin: Bool,
        testedAppVersion: String? = nil,
        launchSchemes: [String]? = nil,
        workflow: AppProviderWorkflow? = nil,
        recovery: AppProviderRecoveryDocument? = nil
    ) throws -> AppProviderPackageSummary {
        let current = try package(id: id)
        var manifest = current.summary.manifest
        manifest.revision = ISO8601DateFormatter().string(from: Date()) + "-" + UUID().uuidString
        manifest.requiresLogin = requiresLogin
        if let launchSchemes { manifest.launchSchemes = launchSchemes }
        if let testedAppVersion {
            manifest.compatibility.testedAppVersion = testedAppVersion
            manifest.compatibility.selectorRevision = String((Int(manifest.compatibility.selectorRevision) ?? 0) + 1)
        }
        let resolvedWorkflow = workflow ?? current.workflow
        let resolvedRecovery = recovery ?? current.recovery
        try validate(manifest)
        try validate(selectors: selectors, manifest: manifest)
        try validate(workflow: resolvedWorkflow)
        try validate(recovery: resolvedRecovery)
        let staging = rootURL.appendingPathComponent(".setup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try writePackageFiles(manifest: manifest, selectors: selectors, workflow: resolvedWorkflow, recovery: resolvedRecovery, prompts: current.prompts, to: staging)
        return try install(from: staging)
    }

    public func remove(id: String) throws {
        let target = rootURL.appendingPathComponent(Self.directoryName(for: id), isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else { throw AppProviderPackageError.packageNotFound(id) }
        try fileManager.removeItem(at: target)
        var disabled = disabledIDs()
        disabled.remove(id)
        try persistDisabledIDs(disabled)
    }

    public func export(id: String, to destinationURL: URL) throws -> URL {
        let packageURL = rootURL.appendingPathComponent(Self.directoryName(for: id), isDirectory: true)
        guard fileManager.fileExists(atPath: packageURL.path) else { throw AppProviderPackageError.packageNotFound(id) }
        _ = try loadPackage(at: packageURL)
        if fileManager.fileExists(atPath: destinationURL.path) { try fileManager.removeItem(at: destinationURL) }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = try Archive(url: destinationURL, accessMode: .create)
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw AppProviderPackageError.invalidArchive }
        let root = packageURL.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var count = 0
        for case let item as URL in enumerator {
            count += 1
            guard count <= Self.maxArchiveEntries else { throw AppProviderPackageError.archiveTooLarge }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AppProviderPackageError.unsafeArchiveEntry(item.lastPathComponent) }
            guard values.isRegularFile == true else { continue }
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else { throw AppProviderPackageError.unsafeArchiveEntry(item.path) }
            let relative = String(standardized.path.dropFirst(prefix.count)).replacingOccurrences(of: "\\", with: "/")
            guard Self.validArchiveEntryPath(relative) else { throw AppProviderPackageError.unsafeArchiveEntry(relative) }
            try archive.addEntry(with: relative, fileURL: standardized, compressionMethod: .deflate)
        }
        return destinationURL
    }

    public func seedFirstPartyIfMissing() throws {
        try ensureRoot()
        for package in Self.firstPartyPackages() {
            let target = rootURL.appendingPathComponent(Self.directoryName(for: package.manifest.id), isDirectory: true)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            let staging = rootURL.appendingPathComponent(".seed-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try writePackageFiles(
                manifest: package.manifest,
                selectors: package.selectors,
                workflow: package.workflow,
                recovery: package.recovery,
                prompts: package.prompts,
                to: staging
            )
            _ = try install(from: staging)
        }
    }

    public static func archiveContainsProviderManifest(_ sourceURL: URL) throws -> Bool {
        guard sourceURL.pathExtension.lowercased() == "zip" else { return false }
        let archive = try Archive(url: sourceURL, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= maxArchiveEntries else { throw AppProviderPackageError.archiveTooLarge }
        var total: UInt64 = 0
        var manifests: [String] = []
        for entry in entries {
            guard validArchiveEntryPath(entry.path), entry.type != .symlink else { throw AppProviderPackageError.unsafeArchiveEntry(entry.path) }
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= maxPackageBytes else { throw AppProviderPackageError.archiveTooLarge }
            total = next
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            if normalized == "provider.json" || normalized.hasSuffix("/provider.json") { manifests.append(normalized) }
        }
        guard manifests.count == 1, let manifest = manifests.first else { return false }
        return manifest.split(separator: "/").count <= 2
    }

    private func loadPackage(at packageURL: URL) throws -> AppProviderPackage {
        let manifestURL = packageURL.appendingPathComponent("provider.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw AppProviderPackageError.manifestMissing }
        let manifestData = try boundedData(manifestURL, limit: Self.maxManifestBytes, label: "provider.json")
        let manifest: AppProviderPackageManifest
        do { manifest = try JSONDecoder().decode(AppProviderPackageManifest.self, from: manifestData) }
        catch { throw AppProviderPackageError.manifestInvalid }
        try validate(manifest)
        try validatePackageLayout(root: packageURL, manifest: manifest)
        let selectors: AppProviderSelectorSet = try decodeJSONResource(manifest.resources.selectors, root: packageURL)
        let workflow: AppProviderWorkflow = try decodeJSONResource(manifest.resources.workflow, root: packageURL)
        let recovery: AppProviderRecoveryDocument = try decodeJSONResource(manifest.resources.recovery, root: packageURL)
        try validate(selectors: selectors, manifest: manifest)
        try validate(workflow: workflow)
        try validate(recovery: recovery)
        let prompts = try manifest.resources.prompts.flatMap { try readTextResource($0, root: packageURL) }
        let summary = AppProviderPackageSummary(manifest: manifest, enabled: true, directoryURL: packageURL)
        return AppProviderPackage(summary: summary, selectors: selectors, workflow: workflow, recovery: recovery, prompts: prompts)
    }

    private func validatePackageLayout(root: URL, manifest: AppProviderPackageManifest) throws {
        var expectedFiles: Set<String> = [
            "provider.json",
            manifest.resources.selectors.replacingOccurrences(of: "\\", with: "/"),
            manifest.resources.workflow.replacingOccurrences(of: "\\", with: "/"),
            manifest.resources.recovery.replacingOccurrences(of: "\\", with: "/")
        ]
        if let prompts = manifest.resources.prompts, !prompts.isEmpty {
            expectedFiles.insert(prompts.replacingOccurrences(of: "\\", with: "/"))
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw AppProviderPackageError.manifestInvalid }
        let normalizedRoot = root.standardizedFileURL
        let prefix = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw AppProviderPackageError.unsafeArchiveEntry(item.lastPathComponent)
            }
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else {
                throw AppProviderPackageError.unsafeArchiveEntry(item.path)
            }
            let relative = String(standardized.path.dropFirst(prefix.count)).replacingOccurrences(of: "\\", with: "/")
            if values.isDirectory == true {
                let directoryPrefix = relative.hasSuffix("/") ? relative : relative + "/"
                guard expectedFiles.contains(where: { $0.hasPrefix(directoryPrefix) }) else {
                    throw AppProviderPackageError.unexpectedResource(relative)
                }
            } else if values.isRegularFile == true {
                guard expectedFiles.contains(relative) else {
                    throw AppProviderPackageError.unexpectedResource(relative)
                }
            } else {
                throw AppProviderPackageError.unexpectedResource(relative)
            }
        }
    }

    private func validate(_ manifest: AppProviderPackageManifest) throws {
        guard manifest.schemaVersion == 1,
              Self.validProviderID(manifest.id),
              Self.validBundleID(manifest.bundleID),
              !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.displayName.count <= 128,
              !manifest.revision.isEmpty,
              manifest.revision.count <= 128,
              !manifest.modelLabel.isEmpty,
              manifest.modelLabel.count <= 128,
              manifest.declaredCapabilities.count <= 16,
              manifest.launchSchemes.count <= 16,
              manifest.responseExtractors.count >= 1,
              manifest.responseExtractors.count <= 8,
              Self.validRelativePath(manifest.resources.selectors),
              Self.validRelativePath(manifest.resources.workflow),
              Self.validRelativePath(manifest.resources.recovery) else {
            throw AppProviderPackageError.manifestInvalid
        }
        if let prompts = manifest.resources.prompts, !prompts.isEmpty, !Self.validRelativePath(prompts) {
            throw AppProviderPackageError.manifestInvalid
        }
        for capability in manifest.declaredCapabilities where !Self.supportedCapabilities.contains(capability) {
            throw AppProviderPackageError.unknownCapability(capability)
        }
        for scheme in manifest.launchSchemes where scheme.isEmpty || scheme.count > 128 || scheme.contains(":") {
            throw AppProviderPackageError.manifestInvalid
        }
        for extractor in manifest.responseExtractors {
            guard extractor.minimumCharacters >= 1, extractor.minimumCharacters <= 100_000 else { throw AppProviderPackageError.manifestInvalid }
            if let region = extractor.region {
                guard region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
                      region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
                      region.x <= 1, region.y <= 1, region.width <= 1, region.height <= 1,
                      region.x + region.width <= 1.000_001,
                      region.y + region.height <= 1.000_001 else {
                    throw AppProviderPackageError.manifestInvalid
                }
            }
        }
    }

    private func validate(selectors: AppProviderSelectorSet, manifest: AppProviderPackageManifest) throws {
        let groups = [
            selectors.composer, selectors.send, selectors.newConversation,
            selectors.generationStart, selectors.generationComplete,
            selectors.response, selectors.copyButton, selectors.readyIndicators,
            selectors.needsLoginIndicators, selectors.errorIndicators
        ]
        guard groups.allSatisfy({ $0.count <= 24 }) else { throw AppProviderPackageError.manifestInvalid }
        for selector in groups.flatMap({ $0 }) {
            guard selector.minimumConfidence >= 0, selector.minimumConfidence <= 1 else { throw AppProviderPackageError.manifestInvalid }
            if selector.strategy == .coordinateFallback {
                guard let coordinate = selector.coordinate,
                      coordinate.x.isFinite, coordinate.y.isFinite,
                      coordinate.screenWidth.isFinite, coordinate.screenHeight.isFinite,
                      coordinate.screenWidth > 0, coordinate.screenHeight > 0,
                      coordinate.x >= 0, coordinate.y >= 0,
                      coordinate.x <= coordinate.screenWidth, coordinate.y <= coordinate.screenHeight,
                      !coordinate.deviceClass.isEmpty,
                      !coordinate.orientation.isEmpty,
                      !coordinate.appVersion.isEmpty else {
                    throw AppProviderPackageError.manifestInvalid
                }
            } else if selector.coordinate != nil {
                throw AppProviderPackageError.manifestInvalid
            }
            if selector.strategy != .coordinateFallback,
               (selector.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               (selector.role?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               (selector.relation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                throw AppProviderPackageError.manifestInvalid
            }
        }
        if manifest.requiresLogin && selectors.readyIndicators.isEmpty && selectors.needsLoginIndicators.isEmpty {
            // Login state may remain unknown, but packages that claim login is mandatory must expose
            // at least one declarative signal instead of silently assuming the account is ready.
            throw AppProviderPackageError.manifestInvalid
        }
    }

    private func validate(workflow: AppProviderWorkflow) throws {
        guard workflow.generationStartTimeoutSeconds >= 1, workflow.generationStartTimeoutSeconds <= 120,
              workflow.generationTimeoutSeconds >= 1, workflow.generationTimeoutSeconds <= 900,
              workflow.stableWindowSeconds >= 0.5, workflow.stableWindowSeconds <= 15,
              workflow.pollIntervalSeconds >= 0.2, workflow.pollIntervalSeconds <= 5,
              workflow.retryBudget >= 0, workflow.retryBudget <= 3,
              workflow.requestPrefix.count <= 4_096,
              workflow.requestSuffix.count <= 4_096 else { throw AppProviderPackageError.manifestInvalid }
    }

    private func validate(recovery: AppProviderRecoveryDocument) throws {
        let allowedFailures: Set<String> = ["foreground_mismatch", "needs_login", "selector_mismatch", "generation_timeout"]
        let allowedActions: Set<String> = [
            "relaunch_once", "surface_needs_login", "mark_needs_plugin_update", "mark_timeout",
            "stop_and_mark_needs_plugin_update", "stop_and_mark_timeout"
        ]
        guard recovery.rules.count <= 16 else { throw AppProviderPackageError.manifestInvalid }
        for rule in recovery.rules {
            guard allowedFailures.contains(rule.failure),
                  allowedActions.contains(rule.action),
                  rule.maxAttempts >= 0, rule.maxAttempts <= 3 else {
                throw AppProviderPackageError.manifestInvalid
            }
        }
    }

    private func boundedData(_ url: URL, limit: Int, label: String) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= limit else {
            throw AppProviderPackageError.resourceTooLarge(label)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func decodeJSONResource<T: Decodable>(_ relativePath: String, root: URL) throws -> T {
        let url = try safeResourceURL(relativePath, root: root)
        let data = try boundedData(url, limit: Self.maxResourceBytes, label: relativePath)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AppProviderPackageError.manifestInvalid }
    }

    private func readTextResource(_ relativePath: String, root: URL) throws -> String? {
        let url = try safeResourceURL(relativePath, root: root)
        let data = try boundedData(url, limit: Self.maxResourceBytes, label: relativePath)
        return String(data: data, encoding: .utf8)
    }

    private func safeResourceURL(_ relativePath: String, root: URL) throws -> URL {
        guard Self.validRelativePath(relativePath) else { throw AppProviderPackageError.manifestInvalid }
        let normalizedRoot = root.standardizedFileURL
        let target = normalizedRoot.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        guard target.path.hasPrefix(prefix) else { throw AppProviderPackageError.manifestInvalid }
        guard fileManager.fileExists(atPath: target.path) else { throw AppProviderPackageError.resourceMissing(relativePath) }
        return target
    }

    private func writePackageFiles(
        manifest: AppProviderPackageManifest,
        selectors: AppProviderSelectorSet,
        workflow: AppProviderWorkflow,
        recovery: AppProviderRecoveryDocument,
        prompts: String?,
        to root: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("provider.json"), options: .atomic)
        try encoder.encode(selectors).write(to: root.appendingPathComponent(manifest.resources.selectors), options: .atomic)
        try encoder.encode(workflow).write(to: root.appendingPathComponent(manifest.resources.workflow), options: .atomic)
        try encoder.encode(recovery).write(to: root.appendingPathComponent(manifest.resources.recovery), options: .atomic)
        if let path = manifest.resources.prompts, let prompts {
            try prompts.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private var stateURL: URL { rootURL.appendingPathComponent(".provider-state.json") }

    private func disabledIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(StateFile.self, from: data) else { return [] }
        return Set(state.disabledIDs)
    }

    private func persistDisabledIDs(_ ids: Set<String>) throws {
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(StateFile(disabledIDs: ids.sorted())).write(to: stateURL, options: .atomic)
    }

    private func resolvePackageRoot(in container: URL) throws -> URL {
        if fileManager.fileExists(atPath: container.appendingPathComponent("provider.json").path) { return container }
        let children = try fileManager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.filter { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return false }
            return fileManager.fileExists(atPath: child.appendingPathComponent("provider.json").path)
        }
        guard candidates.count == 1, let candidate = candidates.first else { throw AppProviderPackageError.manifestMissing }
        return candidate
    }

    private func extractArchive(_ source: URL, to destination: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) }
        catch { throw AppProviderPackageError.invalidArchive }
        let entries = Array(archive)
        guard entries.count <= Self.maxArchiveEntries else { throw AppProviderPackageError.archiveTooLarge }
        var total: UInt64 = 0
        let root = destination.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for entry in entries {
            guard Self.validArchiveEntryPath(entry.path), entry.type != .symlink else { throw AppProviderPackageError.unsafeArchiveEntry(entry.path) }
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= Self.maxPackageBytes else { throw AppProviderPackageError.archiveTooLarge }
            total = next
            let target = root.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path == root.path || target.path.hasPrefix(prefix) else { throw AppProviderPackageError.unsafeArchiveEntry(entry.path) }
            _ = try archive.extract(entry, to: target)
        }
    }

    private func copyDirectoryBounded(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw AppProviderPackageError.unsupportedSource }
        var count = 0
        var total: UInt64 = 0
        let root = source.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let item as URL in enumerator {
            count += 1
            guard count <= Self.maxArchiveEntries else { throw AppProviderPackageError.archiveTooLarge }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AppProviderPackageError.unsafeArchiveEntry(item.lastPathComponent) }
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else { throw AppProviderPackageError.unsafeArchiveEntry(item.path) }
            let relative = String(standardized.path.dropFirst(prefix.count)).replacingOccurrences(of: "\\", with: "/")
            guard Self.validArchiveEntryPath(relative) else { throw AppProviderPackageError.unsafeArchiveEntry(relative) }
            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                let size = UInt64(max(0, values.fileSize ?? 0))
                let (next, overflow) = total.addingReportingOverflow(size)
                guard !overflow, next <= Self.maxPackageBytes else { throw AppProviderPackageError.archiveTooLarge }
                total = next
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }

    private static func validProviderID(_ value: String) -> Bool {
        guard value.hasPrefix("ai."), value.hasSuffix(".app"), value.count <= 128 else { return false }
        let punctuation = CharacterSet(charactersIn: ".-_")
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || punctuation.contains(scalar)
        }
    }

    private static func validBundleID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains("."), !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        let punctuation = CharacterSet(charactersIn: ".-")
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || punctuation.contains(scalar)
        }
    }

    private static func validRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 240, !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains(":") else { return false }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func validArchiveEntryPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 512, !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains(":") else { return false }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func directoryName(for id: String) -> String {
        Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func firstPartyPackages() -> [(manifest: AppProviderPackageManifest, selectors: AppProviderSelectorSet, workflow: AppProviderWorkflow, recovery: AppProviderRecoveryDocument, prompts: String)] {
        let capabilities = ["app.launch", "gui.ax.read", "gui.touch", "gui.textInput", "screenshot", "clipboard.read"]
        func text(_ value: String) -> AppProviderSelector { .init(strategy: .visibleText, value: value, minimumConfidence: 0.8) }
        func label(_ value: String) -> AppProviderSelector { .init(strategy: .semanticLabel, value: value, minimumConfidence: 0.85) }
        func baseWorkflow() -> AppProviderWorkflow {
            AppProviderWorkflow(
                requestPrefix: "CLOUDCODE_REQUEST_ID={{request_id}}\nCloud Code is the only device executor. You may reason, plan, and return tool-call JSON, but you did not execute device actions.\n",
                requestSuffix: "\nBind the answer to CLOUDCODE_REQUEST_ID and do not reuse text from an earlier conversation.",
                generationStartTimeoutSeconds: 20,
                generationTimeoutSeconds: 180,
                stableWindowSeconds: 2,
                pollIntervalSeconds: 0.75,
                retryBudget: 1,
                preferNewConversation: true
            )
        }
        let recovery = AppProviderRecoveryDocument(rules: [
            .init(failure: "foreground_mismatch", action: "relaunch_once", maxAttempts: 1),
            .init(failure: "needs_login", action: "surface_needs_login", maxAttempts: 0),
            .init(failure: "selector_mismatch", action: "mark_needs_plugin_update", maxAttempts: 0),
            .init(failure: "generation_timeout", action: "mark_timeout", maxAttempts: 0)
        ])
        let extractors = [
            AppProviderResponseExtractor(kind: .axText),
            AppProviderResponseExtractor(kind: .copyClipboard),
            AppProviderResponseExtractor(kind: .ocrRegion, region: .init(x: 0.04, y: 0.08, width: 0.92, height: 0.72), minimumCharacters: 2)
        ]
        let gemini = AppProviderPackageManifest(
            revision: "first-party-1",
            id: "ai.gemini.app",
            displayName: "Gemini App",
            bundleID: "com.google.gemini",
            launchSchemes: ["googlegemini", "comgooglegemini"],
            declaredCapabilities: capabilities,
            compatibility: .init(testedAppVersion: "1.2026.1870010", selectorRevision: "1"),
            responseExtractors: extractors
        )
        let geminiSelectors = AppProviderSelectorSet(
            composer: [label("问问 Gemini"), text("问问 Gemini"), text("Ask Gemini")],
            send: [label("发送"), text("发送"), text("Send")],
            newConversation: [label("发起临时对话"), text("发起临时对话"), text("New chat")],
            generationStart: [text("停止"), text("Stop")],
            generationComplete: [text("复制"), text("Copy")],
            response: [.init(strategy: .axRole, role: "StaticText", minimumConfidence: 0.8)],
            copyButton: [text("复制"), text("Copy")],
            readyIndicators: [text("问问 Gemini"), text("Ask Gemini")],
            needsLoginIndicators: [text("登录"), text("Sign in")]
        )
        let deepseek = AppProviderPackageManifest(
            revision: "first-party-1",
            id: "ai.deepseek.app",
            displayName: "DeepSeek App",
            bundleID: "com.deepseek.chat",
            launchSchemes: ["deepseek", "dpsk"],
            declaredCapabilities: capabilities,
            compatibility: .init(testedAppVersion: "2.3.3", selectorRevision: "1"),
            responseExtractors: extractors
        )
        let deepseekSelectors = AppProviderSelectorSet(
            composer: [label("给 DeepSeek 发消息"), text("给 DeepSeek 发消息"), text("Message DeepSeek"), text("Ask DeepSeek")],
            send: [label("发送"), text("发送"), text("Send")],
            newConversation: [label("新建对话"), text("新建对话"), text("New chat")],
            generationStart: [text("停止生成"), text("停止"), text("Stop")],
            generationComplete: [text("复制"), text("Copy")],
            response: [.init(strategy: .axRole, role: "StaticText", minimumConfidence: 0.8)],
            copyButton: [text("复制"), text("Copy")],
            readyIndicators: [text("DeepSeek"), text("发送消息"), text("Message")],
            needsLoginIndicators: [text("登录"), text("Sign in")]
        )
        let chatgpt = AppProviderPackageManifest(
            revision: "first-party-1",
            id: "ai.chatgpt.app",
            displayName: "ChatGPT App",
            bundleID: "com.openai.chat",
            launchSchemes: ["chatgpt"],
            declaredCapabilities: capabilities,
            compatibility: .init(selectorRevision: "1"),
            responseExtractors: extractors
        )
        let chatgptSelectors = AppProviderSelectorSet(
            composer: [label("Message"), text("Message"), text("Ask anything")],
            send: [label("Send"), text("Send")],
            newConversation: [label("New chat"), text("New chat")],
            generationStart: [text("Stop")],
            generationComplete: [text("Copy")],
            response: [.init(strategy: .axRole, role: "StaticText", minimumConfidence: 0.8)],
            copyButton: [text("Copy")],
            readyIndicators: [text("Message"), text("Ask anything")],
            needsLoginIndicators: [text("Log in"), text("Sign up")]
        )
        let prompts = "# First-party App Provider\n\nThis package is declarative. It never grants root authority and cannot execute arbitrary code. All actions remain inside Cloud Code Device Runtime and ToolRouter/PolicyEngine.\n"
        return [
            (gemini, geminiSelectors, baseWorkflow(), recovery, prompts),
            (deepseek, deepseekSelectors, baseWorkflow(), recovery, prompts),
            (chatgpt, chatgptSelectors, baseWorkflow(), recovery, prompts)
        ]
    }
}
