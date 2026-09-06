import Foundation

public protocol ToolExecuting: Sendable {
    var route: AppExecutionRoute { get }
    func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool
    func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult
}

/// Allows an exact requested operation to validate a capability lazily when the startup snapshot
/// deliberately left that capability as `device_validation_required`. Route selection must stay
/// side-effect free: the concrete execute() call performs the bounded validation and fails closed.
/// `unknown` and `unavailable` are never eligible.
public protocol DeferredCapabilitySelfValidatingToolExecutor: ToolExecuting {
    func allowsDeferredCapabilityAttempt(
        _ capabilityIDs: [String],
        for tool: ToolDescriptor,
        capabilities: CapabilityProfile
    ) async -> Bool
}

public struct ToolExecutionContext: Sendable {
    public var permissionMode: PermissionMode
    public var capabilityProfile: CapabilityProfile
    public var allowedRoot: URL?
    public var currentUserRequest: String?

    public init(
        permissionMode: PermissionMode,
        capabilityProfile: CapabilityProfile,
        allowedRoot: URL? = nil,
        currentUserRequest: String? = nil
    ) {
        self.permissionMode = permissionMode
        self.capabilityProfile = capabilityProfile
        self.allowedRoot = allowedRoot
        self.currentUserRequest = currentUserRequest
    }
}

public enum ExplicitUserIntentGate {
    public static func allowsAppUninstall(request: String?, bundleID: String, displayName: String?) -> Bool {
        guard let request else { return false }
        let normalized = normalize(request)
        guard !normalized.isEmpty else { return false }
        let uninstallMarkers = ["卸载", "移除", "删掉", "删除app", "删除应用", "uninstall", "removeapp", "deleteapp"]
        guard uninstallMarkers.contains(where: { normalized.contains(normalize($0)) }) else { return false }

        let normalizedBundleID = normalize(bundleID)
        if !normalizedBundleID.isEmpty, normalized.contains(normalizedBundleID) { return true }
        if let displayName {
            let normalizedName = normalize(displayName)
            if normalizedName.count >= 2, normalized.contains(normalizedName) { return true }
        }
        return false
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0.value > 0x7F }
            .map(String.init)
            .joined()
    }
}

public enum ToolRouterError: Error, Equatable {
    case unknownTool(String)
    case missingCapability(String)
    case noExecutionRoute(String)
}

public enum GUIAutomationFeature: String, CaseIterable, Sendable {
    case openApp = "open_app"
    case tree
    case screenshot
    case touch
    case textInput = "text_input"
    case gestures
    case verify

    public var capabilityID: String { "automation.gui.\(rawValue)" }
}

public struct GUIAutomationCapabilitySnapshot: Sendable, Equatable {
    public var backendIdentifier: String
    public var statuses: [GUIAutomationFeature: CapabilityStatus]
    public var details: [GUIAutomationFeature: String]

    public init(
        backendIdentifier: String,
        statuses: [GUIAutomationFeature: CapabilityStatus],
        details: [GUIAutomationFeature: String] = [:]
    ) {
        self.backendIdentifier = backendIdentifier
        self.statuses = statuses
        self.details = details
    }

    public func status(_ feature: GUIAutomationFeature) -> CapabilityStatus {
        statuses[feature] ?? .unknown
    }

    public func detail(_ feature: GUIAutomationFeature) -> String {
        details[feature] ?? "No runtime detail was returned for \(feature.rawValue)."
    }

    public var compositeStatus: CapabilityStatus {
        let required: [GUIAutomationFeature] = [.openApp, .screenshot, .touch, .textInput, .gestures, .tree, .verify]
        if required.allSatisfy({ status($0) == .available }) { return .available }
        if required.contains(where: { status($0) == .deviceValidationRequired }) { return .deviceValidationRequired }
        if required.contains(where: { status($0) == .unknown }) { return .unknown }
        return .unavailable
    }
}

public protocol GUIAutomationCapabilityProviding: Sendable {
    func guiCapabilitySnapshot() async -> GUIAutomationCapabilitySnapshot
}

public enum GUIVisibleTextVerifier {
    public static func verify(tree: String, assertion: String) -> VerificationResult {
        let expected = normalizedNeedle(assertion)
        guard !expected.isEmpty else {
            return VerificationResult(
                passed: false,
                checks: ["Parse a non-empty visible-text assertion"],
                failures: ["The assertion did not contain a verifiable text target."]
            )
        }
        let passed = tree.range(of: expected, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        return VerificationResult(
            passed: passed,
            checks: ["Fresh GUI observation contains requested visible text (<\(expected.count) chars>)"],
            failures: passed ? [] : ["Fresh GUI observation did not contain the requested visible-text target."]
        )
    }

    private static func normalizedNeedle(_ assertion: String) -> String {
        let trimmed = assertion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        for prefix in ["contains:", "text:", "visible:"] where trimmed.lowercased().hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let firstQuote = trimmed.firstIndex(of: "\""),
           let lastQuote = trimmed.lastIndex(of: "\""),
           firstQuote < lastQuote {
            return String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
        }
        return trimmed
    }
}

public struct GUIElementFrame: Codable, Equatable, Sendable {
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

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var isUsable: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 && x >= 0 && y >= 0
    }
}

public struct GUIElementMatch: Codable, Equatable, Sendable {
    public var path: String
    public var role: String?
    public var label: String?
    public var value: String?
    public var title: String?
    public var identifier: String?
    public var placeholder: String?
    public var frame: GUIElementFrame

    public init(path: String, role: String?, label: String?, value: String?, title: String?, identifier: String?, placeholder: String?, frame: GUIElementFrame) {
        self.path = path
        self.role = role
        self.label = label
        self.value = value
        self.title = title
        self.identifier = identifier
        self.placeholder = placeholder
        self.frame = frame
    }

    public var searchableText: String {
        [identifier, label, title, placeholder, value].compactMap { $0 }.joined(separator: "\n")
    }
}

public enum GUIElementMatchMode: String, Sendable {
    case exact
    case contains
}

/// Parses the existing bounded AX JSON tree into stable element candidates. This stays in Core so
/// both the on-device TrollStore backend and an optional XCTest/WDA bridge can share identical
/// query/ambiguity/stale-element rules without creating a second automation architecture.
public enum GUIElementResolver {
    public static func find(
        in tree: String,
        query: String,
        role: String? = nil,
        mode: GUIElementMatchMode = .exact,
        maximumMatches: Int = 8
    ) -> [GUIElementMatch] {
        let needle = normalized(query)
        guard !needle.isEmpty, needle.utf8.count <= 512,
              let data = tree.data(using: .utf8), data.count <= 512 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let normalizedRole = role.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
        var matches: [GUIElementMatch] = []
        walk(root, path: "0", needle: needle, role: normalizedRole, mode: mode, maximumMatches: max(1, min(maximumMatches, 32)), matches: &matches)
        return matches
    }

    public static func uniqueMatch(
        in tree: String,
        query: String,
        role: String? = nil,
        mode: GUIElementMatchMode = .exact
    ) -> GUIElementMatch? {
        let matches = find(in: tree, query: query, role: role, mode: mode, maximumMatches: 2)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func walk(
        _ raw: Any,
        path: String,
        needle: String,
        role: String?,
        mode: GUIElementMatchMode,
        maximumMatches: Int,
        matches: inout [GUIElementMatch]
    ) {
        guard matches.count < maximumMatches else { return }
        if let node = raw as? [String: Any] {
            if let candidate = candidate(node, path: path), elementMatches(candidate, needle: needle, role: role, mode: mode) {
                matches.append(candidate)
                if matches.count >= maximumMatches { return }
            }
            if let wrappedTree = node["tree"] {
                walk(wrappedTree, path: "\(path).tree", needle: needle, role: role, mode: mode, maximumMatches: maximumMatches, matches: &matches)
                if matches.count >= maximumMatches { return }
            }
            if let children = node["children"] as? [Any] {
                for (index, child) in children.enumerated() {
                    walk(child, path: "\(path).\(index)", needle: needle, role: role, mode: mode, maximumMatches: maximumMatches, matches: &matches)
                    if matches.count >= maximumMatches { return }
                }
            }
        } else if let array = raw as? [Any] {
            for (index, child) in array.enumerated() {
                walk(child, path: "\(path).\(index)", needle: needle, role: role, mode: mode, maximumMatches: maximumMatches, matches: &matches)
                if matches.count >= maximumMatches { return }
            }
        }
    }

    private static func candidate(_ node: [String: Any], path: String) -> GUIElementMatch? {
        guard let rawFrame = node["frame"] as? [String: Any],
              let x = number(rawFrame["x"]), let y = number(rawFrame["y"]),
              let width = number(rawFrame["width"]), let height = number(rawFrame["height"]) else { return nil }
        let frame = GUIElementFrame(x: x, y: y, width: width, height: height)
        guard frame.isUsable else { return nil }
        return GUIElementMatch(
            path: path,
            role: string(node["role"]),
            label: string(node["label"]),
            value: string(node["value"]),
            title: string(node["title"]),
            identifier: string(node["identifier"]),
            placeholder: string(node["placeholder"]),
            frame: frame
        )
    }

    private static func elementMatches(_ candidate: GUIElementMatch, needle: String, role: String?, mode: GUIElementMatchMode) -> Bool {
        if let role, normalized(candidate.role ?? "") != role { return false }
        let fields = [candidate.identifier, candidate.label, candidate.title, candidate.placeholder, candidate.value]
            .compactMap { $0 }
            .map(normalized)
            .filter { !$0.isEmpty }
        switch mode {
        case .exact: return fields.contains(needle)
        case .contains: return fields.contains(where: { $0.contains(needle) })
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func string(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else { return nil }
        return trimmed
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }
}

public enum GUIApprovalTargetSanitizer {
    /// Builds approval text without ever embedding gui.type input contents.
    public static func target(for call: ToolCall) -> String {
        switch call.name {
        case "gui.openApp", "gui.openAppObserve":
            return call.arguments["bundleId"] ?? "当前前台 App"
        case "gui.findElement", "gui.waitForElement":
            return "当前前台 App · element query"
        case "gui.tapElementObserve":
            return "当前前台 App · structured element tap"
        case "gui.typeElementObserve":
            let count = call.arguments["text"]?.count ?? 0
            return "当前前台 App · structured element input \(count) 个字符（内容已隐藏）"
        case "gui.runStructuredPlan":
            return "当前前台 App · bounded structured local plan"
        case "gui.type", "gui.typeObserve":
            let count = call.arguments["text"]?.count ?? 0
            return "当前前台 App · 输入 \(count) 个字符（内容已隐藏）"
        case "gui.tap", "gui.tapObserve": return "当前前台 App · tap"
        case "gui.scroll", "gui.scrollObserve": return "当前前台 App · scroll"
        case "gui.swipe", "gui.swipeObserve": return "当前前台 App · swipe"
        case "gui.swipeSequence":
            let count = call.arguments["count"] ?? "?"
            return "当前前台 App · bounded swipe sequence ×\(count)"
        case "gui.navigateBack": return "当前前台 App · navigate back/dismiss (\(call.arguments["strategy"] ?? "?"))"
        case "gui.verify": return "当前 GUI 会话 · verify"
        default: return "当前 GUI 会话"
        }
    }
}

public actor ToolRegistry {
    private var descriptors: [String: ToolDescriptor]

    public init(descriptors: [ToolDescriptor] = ToolRegistry.phaseOneDefaults) {
        self.descriptors = Dictionary(descriptors.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func descriptor(named name: String) -> ToolDescriptor? { descriptors[name] }
    public func all() -> [ToolDescriptor] { descriptors.values.sorted { $0.name < $1.name } }
    public func register(_ descriptor: ToolDescriptor) { descriptors[descriptor.name] = descriptor }

    public static let phaseOneDefaults: [ToolDescriptor] = [
        ToolDescriptor(name: "capability.probe", summary: "Return the capability snapshot already validated for this session; never initiates privileged probing.", risk: .readOnly),
        ToolDescriptor(name: "apps.list", summary: "Search or page the cached installed-app index. Optional query matches app name/bundle ID; offset/limit are bounded. Device enumeration is reused until explicitly invalidated.", risk: .readOnly),
        ToolDescriptor(name: "apps.inspect", summary: "Inspect an installed app by bundle ID through the bounded resolver; missing targets fail closed.", risk: .readOnly),
        ToolDescriptor(name: "container.resolve", summary: "Resolve the current data container for a bundle ID without caching UUID paths; missing targets fail closed.", risk: .readOnly),
        ToolDescriptor(name: "files.list", summary: "List a directory through structured filesystem access.", risk: .readOnly),
        ToolDescriptor(name: "files.search", summary: "Search a bounded directory progressively.", risk: .readOnly),
        ToolDescriptor(name: "files.read", summary: "Read a bounded text file.", risk: .readOnly),
        ToolDescriptor(name: "files.stat", summary: "Read current filesystem stat-style metadata after revalidating the real path.", risk: .readOnly, requiredCapabilities: ["native.files"]),
        ToolDescriptor(name: "files.metadata", summary: "Read bounded current file metadata through public native filesystem APIs.", risk: .readOnly, requiredCapabilities: ["native.files"]),
        ToolDescriptor(name: "files.hash", summary: "Compute a bounded SHA-256 over a revalidated regular file.", risk: .readOnly, requiredCapabilities: ["native.files"]),
        ToolDescriptor(name: "files.diff", summary: "Compute a bounded local text diff between two revalidated files.", risk: .readOnly, requiredCapabilities: ["native.files"]),
        ToolDescriptor(name: "files.copy", summary: "Copy one ordinary file with descriptor-pinned source/destination validation and byte verification.", risk: .safeWrite, requiredCapabilities: ["native.files"]),
        ToolDescriptor(name: "files.move", summary: "Move one item with descriptor-pinned source/destination validation and post-rename identity verification.", risk: .sensitiveWrite, requiredCapabilities: ["native.files"]),
        ToolDescriptor(name: "plist.read", summary: "Read a bounded plist through PropertyListSerialization.", risk: .readOnly, requiredCapabilities: ["native.plist"]),
        ToolDescriptor(name: "plist.query", summary: "Query a bounded plist key path locally.", risk: .readOnly, requiredCapabilities: ["native.plist"]),
        ToolDescriptor(name: "plist.metadata", summary: "Inspect bounded plist format/type/key metadata locally.", risk: .readOnly, requiredCapabilities: ["native.plist"]),
        ToolDescriptor(name: "json.read", summary: "Read a bounded JSON value locally.", risk: .readOnly, requiredCapabilities: ["native.json"]),
        ToolDescriptor(name: "json.query", summary: "Query a bounded JSON key path locally.", risk: .readOnly, requiredCapabilities: ["native.json"]),
        ToolDescriptor(name: "json.filter", summary: "Filter a bounded JSON array locally by one scalar field equality.", risk: .readOnly, requiredCapabilities: ["native.json"]),
        ToolDescriptor(name: "json.aggregate", summary: "Aggregate count/sum/min/max/avg over a bounded JSON array locally.", risk: .readOnly, requiredCapabilities: ["native.json"]),
        ToolDescriptor(name: "sqlite.discover", summary: "Discover likely SQLite files under a bounded revalidated root without opening unrelated paths.", risk: .readOnly, requiredCapabilities: ["native.sqlite"]),
        ToolDescriptor(name: "sqlite.tables", summary: "List SQLite tables/views through a read-only native connection.", risk: .readOnly, requiredCapabilities: ["native.sqlite"]),
        ToolDescriptor(name: "sqlite.schema", summary: "Inspect bounded SQLite schema metadata through a read-only native connection.", risk: .readOnly, requiredCapabilities: ["native.sqlite"]),
        ToolDescriptor(name: "sqlite.query", summary: "Run one bounded read-only SELECT/WITH/EXPLAIN QUERY PLAN statement locally.", risk: .readOnly, requiredCapabilities: ["native.sqlite"]),
        ToolDescriptor(name: "sqlite.filter", summary: "Filter one SQLite table locally using validated identifiers and a bound scalar parameter.", risk: .readOnly, requiredCapabilities: ["native.sqlite"]),
        ToolDescriptor(name: "sqlite.aggregate", summary: "Run one bounded count/sum/min/max/avg SQLite aggregate locally.", risk: .readOnly, requiredCapabilities: ["native.sqlite"]),
        ToolDescriptor(name: "sqlite.sample", summary: "Sample a bounded number of rows from one validated SQLite table.", risk: .readOnly, requiredCapabilities: ["native.sqlite"]),
        ToolDescriptor(name: "container.list", summary: "Resolve the current app data container and list a bounded subdirectory; cached UUID paths are never trusted for execution.", risk: .readOnly, requiredCapabilities: ["native.container"]),
        ToolDescriptor(name: "container.search", summary: "Resolve the current app data container and search it progressively; execution always revalidates the current path.", risk: .readOnly, requiredCapabilities: ["native.container"]),
        ToolDescriptor(name: "data.localQuery", summary: "Bounded local resolve→search→inspect→query/aggregate macro for plist/JSON/SQLite data, reducing provider round-trips while keeping every real path revalidated.", risk: .readOnly, requiredCapabilities: ["native.data_macro"]),
        ToolDescriptor(name: "storage.analyze", summary: "Analyze file sizes in a resolved directory/container.", risk: .readOnly),
        ToolDescriptor(name: "files.create", summary: "Create a new ordinary file.", risk: .safeWrite),
        ToolDescriptor(name: "files.modify", summary: "Transactionally modify an existing file with diff, backup and verification.", risk: .sensitiveWrite),
        ToolDescriptor(name: "files.delete", summary: "Move a target into Cloud Code Trash rather than unlinking it.", risk: .destructive),
        ToolDescriptor(name: "trash.restore", summary: "Restore a Cloud Code Trash record.", risk: .safeWrite),
        ToolDescriptor(name: "trash.purge", summary: "Permanently delete a Trash record.", risk: .permanentDestructive),
        ToolDescriptor(name: "ipa.locate", summary: "Find IPA archives in a bounded root.", risk: .readOnly),
        ToolDescriptor(name: "ipa.inspect", summary: "Inspect Info.plist, architectures, frameworks, extensions and signature metadata.", risk: .readOnly, requiredCapabilities: ["ipa.inspect"]),
        ToolDescriptor(name: "ipa.extract", summary: "Safely extract an IPA with path traversal protections.", risk: .safeWrite),
        ToolDescriptor(name: "ipa.repack", summary: "Repack a modified IPA.", risk: .sensitiveWrite),
        ToolDescriptor(name: "ipa.install", summary: "Install an IPA through an available privileged adapter.", risk: .systemChange, requiredCapabilities: ["ipa.install"], preferredRoute: .privateFramework),
        ToolDescriptor(name: "apps.launch", summary: "Launch an installed app after a bounded, isolated runtime validation of the LaunchServices backend and target installation state.", risk: .safeWrite, preferredRoute: .privateFramework),
        ToolDescriptor(name: "apps.uninstall", summary: "Uninstall an app.", risk: .permanentDestructive, requiredCapabilities: ["apps.uninstall"], preferredRoute: .privateFramework),
        ToolDescriptor(name: "apps.terminate", summary: "Terminate an app/process.", risk: .systemChange, requiredCapabilities: ["apps.terminate"], preferredRoute: .privateFramework),
        ToolDescriptor(name: "advanced.shell", summary: "Execute an advanced shell command. High risk and never the default tool path.", risk: .systemChange, requiredCapabilities: ["execution.ios_system"], preferredRoute: .cli),
        ToolDescriptor(name: "gui.openApp", summary: "Open an app using the GUI automation fallback backend.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.openApp.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.openAppObserve", summary: "Open exactly one target app, verify the target became foreground in the bounded helper, then immediately capture one fresh screenshot locally. The screenshot is for semantic planning only and never substitutes for the target-foreground launch verification.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.openApp.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.tree", summary: "Read the GUI accessibility tree from the configured automation backend.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.tree.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.findElement", summary: "Resolve a unique visible accessibility element locally by identifier/label/title/placeholder/value, with optional role and exact-or-contains matching. Returns only bounded structural metadata and coordinates; no screenshot or Vision call is needed.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.tree.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.waitForElement", summary: "Poll the local accessibility tree for a unique element for a bounded time without calling the remote model between polls. Use for known delayed pages; ambiguity and timeouts fail closed.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.tree.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.tapElementObserve", summary: "Find one unique accessibility element locally, tap its current frame center, then immediately capture a fresh screenshot. This avoids Vision coordinate lookup while preserving post-action semantic re-planning.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.tree.capabilityID, GUIAutomationFeature.touch.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.typeElementObserve", summary: "Find one unique non-protected accessibility element locally, focus it, enter bounded text, then immediately capture a fresh screenshot. Secure/system-confirmation targets are rejected and ambiguity fails closed.", risk: .sensitiveWrite, requiredCapabilities: [GUIAutomationFeature.tree.capabilityID, GUIAutomationFeature.touch.capabilityID, GUIAutomationFeature.textInput.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.runStructuredPlan", summary: "Execute a bounded local multi-step plan using only foreground-verified app launch, accessibility element queries, element taps/text, bounded swipes/back gestures, and local validators. Every non-final state-changing step must declare an accessibility-tree expectation before another write may run. Any ambiguity, stale tree, failed expectation, protected confirmation target, or unsupported action stops the plan and returns control for re-planning. Vision remains fallback only.", risk: .sensitiveWrite, requiredCapabilities: [GUIAutomationFeature.openApp.capabilityID, GUIAutomationFeature.tree.capabilityID, GUIAutomationFeature.screenshot.capabilityID, GUIAutomationFeature.touch.capabilityID, GUIAutomationFeature.textInput.capabilityID, GUIAutomationFeature.gestures.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.screenshot", summary: "Capture a screenshot through the GUI automation backend.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.tap", summary: "Tap a GUI coordinate/element through the configured backend.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.touch.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.type", summary: "Type text through the configured backend.", risk: .sensitiveWrite, requiredCapabilities: [GUIAutomationFeature.textInput.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.scroll", summary: "Scroll through the configured backend.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.swipe", summary: "Swipe through the configured backend.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.swipeSequence", summary: "Execute an explicitly requested finite sequence of identical swipes locally. The bounded executor captures lightweight screenshots between gestures, stops early on byte-identical observations, and returns the final screenshot so the model does not need a full round-trip between every repeated swipe.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.navigateBack", summary: "Navigate back from a temporary iOS detail/media surface using one explicit bounded strategy: edge for a left-edge navigation-pop gesture, or dismissDown for a fullscreen/modal downward dismiss. The tool returns a fresh final screenshot; that screenshot, not motion/hash alone, must be inspected semantically before continuing.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.tapObserve", summary: "Execute one bounded tap and immediately capture a fresh screenshot locally. This is a one-write micro-plan; the returned image must be interpreted before any dependent write.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.touch.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.typeObserve", summary: "Execute one bounded text-input action and immediately capture a fresh screenshot locally. This is a one-write micro-plan; do not send or perform another dependent write before interpreting the returned image.", risk: .sensitiveWrite, requiredCapabilities: [GUIAutomationFeature.textInput.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.scrollObserve", summary: "Execute one bounded scroll and immediately capture a fresh screenshot locally. This is a one-write micro-plan; interpret the returned image before another dependent write.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.swipeObserve", summary: "Execute one bounded swipe and immediately capture a fresh screenshot locally. This is a one-write micro-plan; interpret the returned image before another dependent write.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID, GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "interaction.confirmTransition", summary: "Record semantically verified navigation evidence for the adaptive iOS interaction framework after inspecting fresh observation data. This never performs a GUI action and never changes permissions.", risk: .readOnly),
        ToolDescriptor(name: "gui.verify", summary: "Verify GUI postconditions through the configured backend.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.verify.capabilityID], preferredRoute: .guiFallback)
    ]
}

public struct ExecutionPathMetric: Codable, Equatable, Sendable {
    public var tool: String
    public var routeCandidates: [AppExecutionRoute]
    public var selectedRoute: AppExecutionRoute?
    public var fallbackReason: String
    public var fallbackDepth: Int
    public var routeSelectionLatencyMS: Int
    public var executionLatencyMS: Int
    public var totalLatencyMS: Int
    public var outcome: String
    public var recordedAt: Date

    public init(tool: String, routeCandidates: [AppExecutionRoute], selectedRoute: AppExecutionRoute?, fallbackReason: String, fallbackDepth: Int, routeSelectionLatencyMS: Int, executionLatencyMS: Int, totalLatencyMS: Int, outcome: String, recordedAt: Date = Date()) {
        self.tool = tool
        self.routeCandidates = routeCandidates
        self.selectedRoute = selectedRoute
        self.fallbackReason = fallbackReason
        self.fallbackDepth = fallbackDepth
        self.routeSelectionLatencyMS = routeSelectionLatencyMS
        self.executionLatencyMS = executionLatencyMS
        self.totalLatencyMS = totalLatencyMS
        self.outcome = outcome
        self.recordedAt = recordedAt
    }
}

public actor ExecutionPathMetrics {
    private var values: [ExecutionPathMetric] = []
    private let maximumCount: Int

    public init(maximumCount: Int = 512) {
        self.maximumCount = max(32, min(maximumCount, 4_096))
    }

    public func record(_ metric: ExecutionPathMetric) {
        values.append(metric)
        if values.count > maximumCount { values.removeFirst(values.count - maximumCount) }
    }

    public func recent(limit: Int = 100) -> [ExecutionPathMetric] {
        Array(values.suffix(min(max(limit, 1), maximumCount)))
    }
}

public actor ToolRouter {
    private struct RouteDecision: Sendable {
        var route: AppExecutionRoute
        var candidates: [AppExecutionRoute]
        var fallbackReason: String
        var fallbackDepth: Int
        var latencyMS: Int
    }

    private let registry: ToolRegistry
    private let executors: [ToolExecuting]
    private let executionLedger: ToolExecutionLedger?
    private let diagnosticLogger: DiagnosticLogStore?
    private let executionPathMetrics: ExecutionPathMetrics
    private var inFlight: [UUID: (call: ToolCall, task: Task<ToolResult, Error>)] = [:]

    public init(
        registry: ToolRegistry,
        executors: [ToolExecuting],
        executionLedger: ToolExecutionLedger? = nil,
        diagnosticLogger: DiagnosticLogStore? = nil,
        executionPathMetrics: ExecutionPathMetrics = ExecutionPathMetrics()
    ) {
        self.registry = registry
        self.executors = executors
        self.executionLedger = executionLedger
        self.diagnosticLogger = diagnosticLogger
        self.executionPathMetrics = executionPathMetrics
    }

    public func recentExecutionPathMetrics(limit: Int = 100) async -> [ExecutionPathMetric] {
        await executionPathMetrics.recent(limit: limit)
    }

    /// Returns only tools that have a side-effect-free route decision for the current capability
    /// profile. This keeps impossible/unavailable schemas out of every provider request while
    /// retaining exact-operation deferred self-validation routes such as the TrollStore GUI tools.
    public func providerRoutableToolNames(capabilities: CapabilityProfile) async -> Set<String> {
        let descriptors = await registry.all()
        var names = Set<String>()
        for descriptor in descriptors {
            let probeCall = ToolCall(name: descriptor.name, arguments: [:], sessionID: UUID())
            if (try? await routeDecision(for: probeCall, capabilities: capabilities)) != nil {
                names.insert(descriptor.name)
            }
        }
        return names
    }

    public func chooseRoute(for call: ToolCall, capabilities: CapabilityProfile) async throws -> AppExecutionRoute {
        try await routeDecision(for: call, capabilities: capabilities).route
    }

    private func routeDecision(for call: ToolCall, capabilities: CapabilityProfile) async throws -> RouteDecision {
        let startedAt = Date()
        guard let descriptor = await registry.descriptor(named: call.name) else { throw ToolRouterError.unknownTool(call.name) }
        let candidates = routeOrder(preferred: descriptor.preferredRoute)
        var deferredCapabilities: [String] = []
        for required in descriptor.requiredCapabilities {
            switch capabilities.status(required) {
            case .available:
                continue
            case .deviceValidationRequired:
                deferredCapabilities.append(required)
            case .unknown, .unavailable:
                throw ToolRouterError.missingCapability(required)
            }
        }

        var skipped: [String] = []
        for (index, route) in candidates.enumerated() {
            let routeExecutors = executors.filter { $0.route == route }
            guard !routeExecutors.isEmpty else {
                skipped.append("\(route.rawValue):no_executor")
                continue
            }
            var routeDeferredBlocked = false
            for executor in routeExecutors {
                if !deferredCapabilities.isEmpty {
                    guard let selfValidating = executor as? any DeferredCapabilitySelfValidatingToolExecutor,
                          await selfValidating.allowsDeferredCapabilityAttempt(
                            deferredCapabilities,
                            for: descriptor,
                            capabilities: capabilities
                          ) else {
                        routeDeferredBlocked = true
                        continue
                    }
                }
                if await executor.supports(descriptor, capabilities: capabilities) {
                    let latencyMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                    let reason = skipped.isEmpty ? "first_candidate_supported" : skipped.joined(separator: ";")
                    return RouteDecision(route: route, candidates: candidates, fallbackReason: reason, fallbackDepth: index, latencyMS: latencyMS)
                }
            }
            skipped.append(routeDeferredBlocked ? "\(route.rawValue):deferred_validation_rejected_or_unsupported" : "\(route.rawValue):unsupported")
        }
        if let missing = deferredCapabilities.first {
            throw ToolRouterError.missingCapability(missing)
        }
        throw ToolRouterError.noExecutionRoute(call.name)
    }

    /// Recovery-only lookup for a historical dangling call. This never selects an executor,
    /// never runs a tool, and never creates a new ledger pending marker.
    public func recoverPersistedResult(for call: ToolCall) async throws -> ToolResult? {
        guard let descriptor = await registry.descriptor(named: call.name) else {
            throw ToolRouterError.unknownTool(call.name)
        }
        guard descriptor.risk != .readOnly else { return nil }
        guard let executionLedger else { return nil }
        return try await executionLedger.completedResult(for: call)
    }

    public func execute(_ call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        let executionStartedAt = Date()
        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "tool",
            action: call.name,
            result: "started",
            sessionID: call.sessionID,
            toolCallID: call.id,
            metadata: ["argumentKeys": call.arguments.keys.sorted().joined(separator: ",")]
        )
        guard let descriptor = await registry.descriptor(named: call.name) else {
            let error = ToolRouterError.unknownTool(call.name)
            try? await diagnosticLogger?.log(level: .error, subsystem: "tool", action: call.name, result: "unknown_tool", sessionID: call.sessionID, toolCallID: call.id, error: error)
            throw error
        }
        let decision: RouteDecision
        do {
            decision = try await routeDecision(for: call, capabilities: context.capabilityProfile)
            try? await diagnosticLogger?.log(
                level: .info,
                subsystem: "tool-route",
                action: call.name,
                result: "selected",
                sessionID: call.sessionID,
                toolCallID: call.id,
                metadata: [
                    "route": decision.route.rawValue,
                    "routeCandidates": decision.candidates.map(\.rawValue).joined(separator: ","),
                    "fallbackReason": decision.fallbackReason,
                    "fallbackDepth": String(decision.fallbackDepth),
                    "routeSelectionLatencyMS": String(decision.latencyMS)
                ]
            )
        } catch {
            let candidates = routeOrder(preferred: descriptor.preferredRoute)
            let totalMS = max(0, Int(Date().timeIntervalSince(executionStartedAt) * 1_000))
            await executionPathMetrics.record(ExecutionPathMetric(
                tool: call.name,
                routeCandidates: candidates,
                selectedRoute: nil,
                fallbackReason: "route_failed:\(String(describing: error))",
                fallbackDepth: candidates.count,
                routeSelectionLatencyMS: totalMS,
                executionLatencyMS: 0,
                totalLatencyMS: totalMS,
                outcome: "route_failed"
            ))
            try? await diagnosticLogger?.log(level: .error, subsystem: "tool", action: call.name, result: "route_failed", sessionID: call.sessionID, toolCallID: call.id, error: error, metadata: ["routeCandidates": candidates.map(\.rawValue).joined(separator: ","), "routeSelectionLatencyMS": String(totalMS)])
            throw error
        }
        let route = decision.route

        var selectedExecutor: ToolExecuting?
        for executor in executors where executor.route == route {
            if await executor.supports(descriptor, capabilities: context.capabilityProfile) {
                selectedExecutor = executor
                break
            }
        }
        guard let executor = selectedExecutor else { throw ToolRouterError.noExecutionRoute(call.name) }

        if descriptor.risk == .readOnly {
            let executorStartedAt = Date()
            do {
                let result = try await DiagnosticContext.$sessionID.withValue(call.sessionID) {
                    try await DiagnosticContext.$toolCallID.withValue(call.id) {
                        try await executor.execute(call, descriptor: descriptor, context: context)
                    }
                }
                await recordExecutionPath(call: call, decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, outcome: result.success ? "completed" : "failed")
                try? await diagnosticLogger?.log(level: result.success ? .info : .warning, subsystem: "tool", action: call.name, result: result.success ? "completed" : "failed", sessionID: call.sessionID, toolCallID: call.id, diagnostic: result.summary, metadata: executionMetadata(decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, verification: result.verification))
                return result
            } catch {
                await recordExecutionPath(call: call, decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, outcome: "failed")
                try? await diagnosticLogger?.log(level: .error, subsystem: "tool", action: call.name, result: "failed", sessionID: call.sessionID, toolCallID: call.id, error: error, metadata: executionMetadata(decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, verification: nil))
                throw error
            }
        }

        if let existing = inFlight[call.id] {
            guard existing.call == call else { throw ToolExecutionLedgerError.idempotencyConflict(call.id) }
            let reusedAt = Date()
            let result = try await existing.task.value
            await recordExecutionPath(call: call, decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: reusedAt, outcome: "inflight_reused")
            return result
        }

        let executorStartedAt = Date()
        let task = Task<ToolResult, Error> {
            if let executionLedger,
               let cached = try await executionLedger.prepare(call) {
                try? await diagnosticLogger?.log(level: .info, subsystem: "tool", action: call.name, result: "idempotent_cached", sessionID: call.sessionID, toolCallID: call.id, diagnostic: cached.summary)
                return cached
            }
            let result = try await DiagnosticContext.$sessionID.withValue(call.sessionID) {
                try await DiagnosticContext.$toolCallID.withValue(call.id) {
                    try await executor.execute(call, descriptor: descriptor, context: context)
                }
            }
            if result.success, let executionLedger {
                try await executionLedger.complete(result, for: call)
            }
            return result
        }
        inFlight[call.id] = (call, task)
        defer { inFlight.removeValue(forKey: call.id) }
        do {
            let result = try await task.value
            await recordExecutionPath(call: call, decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, outcome: result.success ? "completed" : "failed")
            try? await diagnosticLogger?.log(
                level: result.success ? .info : .warning,
                subsystem: "tool",
                action: call.name,
                result: result.success ? "completed" : "failed",
                sessionID: call.sessionID,
                toolCallID: call.id,
                diagnostic: result.summary,
                metadata: executionMetadata(decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, verification: result.verification)
            )
            return result
        } catch {
            await recordExecutionPath(call: call, decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, outcome: "failed")
            try? await diagnosticLogger?.log(level: .error, subsystem: "tool", action: call.name, result: "failed", sessionID: call.sessionID, toolCallID: call.id, error: error, metadata: executionMetadata(decision: decision, executionStartedAt: executionStartedAt, executorStartedAt: executorStartedAt, verification: nil))
            throw error
        }
    }

    private func recordExecutionPath(
        call: ToolCall,
        decision: RouteDecision,
        executionStartedAt: Date,
        executorStartedAt: Date,
        outcome: String
    ) async {
        let now = Date()
        let executionMS = max(0, Int(now.timeIntervalSince(executorStartedAt) * 1_000))
        let totalMS = max(0, Int(now.timeIntervalSince(executionStartedAt) * 1_000))
        await executionPathMetrics.record(ExecutionPathMetric(
            tool: call.name,
            routeCandidates: decision.candidates,
            selectedRoute: decision.route,
            fallbackReason: decision.fallbackReason,
            fallbackDepth: decision.fallbackDepth,
            routeSelectionLatencyMS: decision.latencyMS,
            executionLatencyMS: executionMS,
            totalLatencyMS: totalMS,
            outcome: outcome
        ))
    }

    private func executionMetadata(
        decision: RouteDecision,
        executionStartedAt: Date,
        executorStartedAt: Date,
        verification: VerificationResult?
    ) -> [String: String] {
        let now = Date()
        return [
            "route": decision.route.rawValue,
            "routeCandidates": decision.candidates.map(\.rawValue).joined(separator: ","),
            "fallbackReason": decision.fallbackReason,
            "fallbackDepth": String(decision.fallbackDepth),
            "routeSelectionLatencyMS": String(decision.latencyMS),
            "executionLatencyMS": String(max(0, Int(now.timeIntervalSince(executorStartedAt) * 1_000))),
            "totalLatencyMS": String(max(0, Int(now.timeIntervalSince(executionStartedAt) * 1_000))),
            "verification": verification.map { $0.passed ? "passed" : "failed" } ?? "none"
        ]
    }

    private func routeOrder(preferred: AppExecutionRoute) -> [AppExecutionRoute] {
        let canonical: [AppExecutionRoute] = [.structuredTool, .cli, .privateFramework, .urlScheme, .guiFallback]
        if preferred == .structuredTool { return canonical }
        guard let preferredIndex = canonical.firstIndex(of: preferred) else { return canonical }
        var result = canonical
        let value = result.remove(at: preferredIndex)
        result.insert(value, at: 0)
        return result
    }
}

public protocol GUIAutomationBackend: GUIAutomationCapabilityProviding, Sendable {
    var identifier: String { get }
    func isAvailable() async -> Bool
    func openApp(bundleID: String) async throws
    func tree() async throws -> String
    func screenshot() async throws -> Data
    func tap(x: Double, y: Double) async throws
    func type(_ text: String) async throws
    func scroll(deltaX: Double, deltaY: Double) async throws
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double) async throws
    func navigateBack(strategy: String) async throws
    func verify(_ assertion: String) async throws -> VerificationResult
}

public struct UnavailableGUIBackend: GUIAutomationBackend, Sendable {
    public let identifier = "unavailable"
    public init() {}
    public func isAvailable() async -> Bool { false }
    public func guiCapabilitySnapshot() async -> GUIAutomationCapabilitySnapshot {
        GUIAutomationCapabilitySnapshot(
            backendIdentifier: identifier,
            statuses: Dictionary(uniqueKeysWithValues: GUIAutomationFeature.allCases.map { ($0, .unavailable) }),
            details: Dictionary(uniqueKeysWithValues: GUIAutomationFeature.allCases.map { ($0, "No GUI automation runtime is connected.") })
        )
    }
    public func openApp(bundleID: String) async throws { throw ToolRouterError.noExecutionRoute("gui.openApp") }
    public func tree() async throws -> String { throw ToolRouterError.noExecutionRoute("gui.tree") }
    public func screenshot() async throws -> Data { throw ToolRouterError.noExecutionRoute("gui.screenshot") }
    public func tap(x: Double, y: Double) async throws { throw ToolRouterError.noExecutionRoute("gui.tap") }
    public func type(_ text: String) async throws { throw ToolRouterError.noExecutionRoute("gui.type") }
    public func scroll(deltaX: Double, deltaY: Double) async throws { throw ToolRouterError.noExecutionRoute("gui.scroll") }
    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double) async throws { throw ToolRouterError.noExecutionRoute("gui.swipe") }
    public func navigateBack(strategy: String) async throws { throw ToolRouterError.noExecutionRoute("gui.navigateBack") }
    public func verify(_ assertion: String) async throws -> VerificationResult { throw ToolRouterError.noExecutionRoute("gui.verify") }
}

public protocol SemanticCLIBackend: Sendable {
    func isAvailable() async -> Bool
    func execute(command: SemanticCommand) async throws -> ToolResult
}

public struct SemanticCommand: Codable, Equatable, Sendable {
    public var verb: String
    public var arguments: [String]
    public var options: [String: String]

    public init(verb: String, arguments: [String] = [], options: [String: String] = [:]) {
        self.verb = verb
        self.arguments = arguments
        self.options = options
    }
}

public struct CLISemanticParser: Sendable {
    public init() {}

    public func parse(_ input: String) -> SemanticCommand? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var verbParts: [String] = []
        var arguments: [String] = []
        var options: [String: String] = [:]
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    options[key] = tokens[index + 1]
                    index += 2
                } else {
                    options[key] = "true"
                    index += 1
                }
                continue
            }
            if verbParts.count < 2 { verbParts.append(token) } else { arguments.append(token) }
            index += 1
        }
        return SemanticCommand(verb: verbParts.joined(separator: "."), arguments: arguments, options: options)
    }

    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var quoteCharacter: Character?
        for character in input {
            if (character == "\"" || character == "'") {
                if quoted && character == quoteCharacter { quoted = false; quoteCharacter = nil }
                else if !quoted { quoted = true; quoteCharacter = character }
                else { current.append(character) }
                continue
            }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
