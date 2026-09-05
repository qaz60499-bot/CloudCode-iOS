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

    public init(permissionMode: PermissionMode, capabilityProfile: CapabilityProfile, allowedRoot: URL? = nil) {
        self.permissionMode = permissionMode
        self.capabilityProfile = capabilityProfile
        self.allowedRoot = allowedRoot
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

public enum GUIApprovalTargetSanitizer {
    /// Builds approval text without ever embedding gui.type input contents.
    public static func target(for call: ToolCall) -> String {
        switch call.name {
        case "gui.openApp":
            return call.arguments["bundleId"] ?? "当前前台 App"
        case "gui.type":
            let count = call.arguments["text"]?.count ?? 0
            return "当前前台 App · 输入 \(count) 个字符（内容已隐藏）"
        case "gui.tap": return "当前前台 App · tap"
        case "gui.scroll": return "当前前台 App · scroll"
        case "gui.swipe": return "当前前台 App · swipe"
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
        ToolDescriptor(name: "gui.tree", summary: "Read the GUI accessibility tree from the configured automation backend.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.tree.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.screenshot", summary: "Capture a screenshot through the GUI automation backend.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.screenshot.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.tap", summary: "Tap a GUI coordinate/element through the configured backend.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.touch.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.type", summary: "Type text through the configured backend.", risk: .sensitiveWrite, requiredCapabilities: [GUIAutomationFeature.textInput.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.scroll", summary: "Scroll through the configured backend.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.swipe", summary: "Swipe through the configured backend.", risk: .safeWrite, requiredCapabilities: [GUIAutomationFeature.gestures.capabilityID], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.verify", summary: "Verify GUI postconditions through the configured backend.", risk: .readOnly, requiredCapabilities: [GUIAutomationFeature.verify.capabilityID], preferredRoute: .guiFallback)
    ]
}

public actor ToolRouter {
    private let registry: ToolRegistry
    private let executors: [ToolExecuting]
    private let executionLedger: ToolExecutionLedger?
    private let diagnosticLogger: DiagnosticLogStore?
    private var inFlight: [UUID: (call: ToolCall, task: Task<ToolResult, Error>)] = [:]

    public init(
        registry: ToolRegistry,
        executors: [ToolExecuting],
        executionLedger: ToolExecutionLedger? = nil,
        diagnosticLogger: DiagnosticLogStore? = nil
    ) {
        self.registry = registry
        self.executors = executors
        self.executionLedger = executionLedger
        self.diagnosticLogger = diagnosticLogger
    }

    public func chooseRoute(for call: ToolCall, capabilities: CapabilityProfile) async throws -> AppExecutionRoute {
        guard let descriptor = await registry.descriptor(named: call.name) else { throw ToolRouterError.unknownTool(call.name) }
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

        for route in routeOrder(preferred: descriptor.preferredRoute) {
            for executor in executors where executor.route == route {
                if !deferredCapabilities.isEmpty {
                    guard let selfValidating = executor as? any DeferredCapabilitySelfValidatingToolExecutor,
                          await selfValidating.allowsDeferredCapabilityAttempt(
                            deferredCapabilities,
                            for: descriptor,
                            capabilities: capabilities
                          ) else { continue }
                }
                if await executor.supports(descriptor, capabilities: capabilities) { return route }
            }
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
        let route: AppExecutionRoute
        do {
            route = try await chooseRoute(for: call, capabilities: context.capabilityProfile)
        } catch {
            try? await diagnosticLogger?.log(level: .error, subsystem: "tool", action: call.name, result: "route_failed", sessionID: call.sessionID, toolCallID: call.id, error: error)
            throw error
        }

        var selectedExecutor: ToolExecuting?
        for executor in executors where executor.route == route {
            if await executor.supports(descriptor, capabilities: context.capabilityProfile) {
                selectedExecutor = executor
                break
            }
        }
        guard let executor = selectedExecutor else { throw ToolRouterError.noExecutionRoute(call.name) }

        if descriptor.risk == .readOnly {
            do {
                let result = try await DiagnosticContext.$sessionID.withValue(call.sessionID) {
                    try await DiagnosticContext.$toolCallID.withValue(call.id) {
                        try await executor.execute(call, descriptor: descriptor, context: context)
                    }
                }
                try? await diagnosticLogger?.log(level: result.success ? .info : .warning, subsystem: "tool", action: call.name, result: result.success ? "completed" : "failed", sessionID: call.sessionID, toolCallID: call.id, diagnostic: result.summary, metadata: ["route": route.rawValue, "verification": result.verification.map { $0.passed ? "passed" : "failed" } ?? "none"])
                return result
            } catch {
                try? await diagnosticLogger?.log(level: .error, subsystem: "tool", action: call.name, result: "failed", sessionID: call.sessionID, toolCallID: call.id, error: error, metadata: ["route": route.rawValue])
                throw error
            }
        }

        if let existing = inFlight[call.id] {
            guard existing.call == call else { throw ToolExecutionLedgerError.idempotencyConflict(call.id) }
            return try await existing.task.value
        }

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
            try? await diagnosticLogger?.log(
                level: result.success ? .info : .warning,
                subsystem: "tool",
                action: call.name,
                result: result.success ? "completed" : "failed",
                sessionID: call.sessionID,
                toolCallID: call.id,
                diagnostic: result.summary,
                metadata: ["route": route.rawValue, "verification": result.verification.map { $0.passed ? "passed" : "failed" } ?? "none"]
            )
            return result
        } catch {
            try? await diagnosticLogger?.log(level: .error, subsystem: "tool", action: call.name, result: "failed", sessionID: call.sessionID, toolCallID: call.id, error: error, metadata: ["route": route.rawValue])
            throw error
        }
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
