import Foundation

public protocol ToolExecuting: Sendable {
    var route: AppExecutionRoute { get }
    func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool
    func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult
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

public actor ToolRegistry {
    private var descriptors: [String: ToolDescriptor]

    public init(descriptors: [ToolDescriptor] = ToolRegistry.phaseOneDefaults) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) })
    }

    public func descriptor(named name: String) -> ToolDescriptor? { descriptors[name] }
    public func all() -> [ToolDescriptor] { descriptors.values.sorted { $0.name < $1.name } }
    public func register(_ descriptor: ToolDescriptor) { descriptors[descriptor.name] = descriptor }

    public static let phaseOneDefaults: [ToolDescriptor] = [
        ToolDescriptor(name: "capability.probe", summary: "Probe actual device capabilities before planning.", risk: .readOnly),
        ToolDescriptor(name: "apps.list", summary: "Enumerate installed apps when the runtime permits it.", risk: .readOnly, requiredCapabilities: ["apps.enumerate"]),
        ToolDescriptor(name: "apps.inspect", summary: "Inspect an installed app by bundle ID.", risk: .readOnly, requiredCapabilities: ["apps.resolve_bundle_path"]),
        ToolDescriptor(name: "container.resolve", summary: "Resolve the current data container for a bundle ID without caching UUID paths.", risk: .readOnly, requiredCapabilities: ["apps.resolve_data_container"]),
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
        ToolDescriptor(name: "apps.uninstall", summary: "Uninstall an app.", risk: .permanentDestructive, requiredCapabilities: ["apps.uninstall"], preferredRoute: .privateFramework),
        ToolDescriptor(name: "apps.terminate", summary: "Terminate an app/process.", risk: .systemChange, requiredCapabilities: ["apps.terminate"], preferredRoute: .privateFramework),
        ToolDescriptor(name: "advanced.shell", summary: "Execute an advanced shell command. High risk and never the default tool path.", risk: .systemChange, requiredCapabilities: ["execution.ios_system"], preferredRoute: .cli),
        ToolDescriptor(name: "gui.openApp", summary: "Open an app using the GUI automation fallback backend.", risk: .safeWrite, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.tree", summary: "Read the GUI accessibility tree from the configured automation backend.", risk: .readOnly, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.screenshot", summary: "Capture a screenshot through the GUI automation backend.", risk: .readOnly, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.tap", summary: "Tap a GUI coordinate/element through the configured backend.", risk: .safeWrite, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.type", summary: "Type text through the configured backend.", risk: .sensitiveWrite, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.scroll", summary: "Scroll through the configured backend.", risk: .safeWrite, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.swipe", summary: "Swipe through the configured backend.", risk: .safeWrite, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback),
        ToolDescriptor(name: "gui.verify", summary: "Verify GUI postconditions through the configured backend.", risk: .readOnly, requiredCapabilities: ["automation.gui"], preferredRoute: .guiFallback)
    ]
}

public actor ToolRouter {
    private let registry: ToolRegistry
    private let executors: [ToolExecuting]
    private let executionLedger: ToolExecutionLedger?
    private var inFlight: [UUID: (call: ToolCall, task: Task<ToolResult, Error>)] = [:]

    public init(registry: ToolRegistry, executors: [ToolExecuting], executionLedger: ToolExecutionLedger? = nil) {
        self.registry = registry
        self.executors = executors
        self.executionLedger = executionLedger
    }

    public func chooseRoute(for call: ToolCall, capabilities: CapabilityProfile) async throws -> AppExecutionRoute {
        guard let descriptor = await registry.descriptor(named: call.name) else { throw ToolRouterError.unknownTool(call.name) }
        for required in descriptor.requiredCapabilities {
            let status = capabilities.status(required)
            guard status == .available else {
                throw ToolRouterError.missingCapability(required)
            }
        }

        for route in routeOrder(preferred: descriptor.preferredRoute) {
            for executor in executors where executor.route == route {
                if await executor.supports(descriptor, capabilities: capabilities) { return route }
            }
        }
        throw ToolRouterError.noExecutionRoute(call.name)
    }

    public func execute(_ call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        guard let descriptor = await registry.descriptor(named: call.name) else { throw ToolRouterError.unknownTool(call.name) }
        let route = try await chooseRoute(for: call, capabilities: context.capabilityProfile)

        var selectedExecutor: ToolExecuting?
        for executor in executors where executor.route == route {
            if await executor.supports(descriptor, capabilities: context.capabilityProfile) {
                selectedExecutor = executor
                break
            }
        }
        guard let executor = selectedExecutor else { throw ToolRouterError.noExecutionRoute(call.name) }

        if descriptor.risk == .readOnly {
            return try await executor.execute(call, descriptor: descriptor, context: context)
        }

        if let existing = inFlight[call.id] {
            guard existing.call == call else { throw ToolExecutionLedgerError.idempotencyConflict(call.id) }
            return try await existing.task.value
        }

        let task = Task<ToolResult, Error> {
            if let executionLedger,
               let cached = try await executionLedger.prepare(call) {
                return cached
            }
            let result = try await executor.execute(call, descriptor: descriptor, context: context)
            if result.success, let executionLedger {
                try await executionLedger.complete(result, for: call)
            }
            return result
        }
        inFlight[call.id] = (call, task)
        defer { inFlight.removeValue(forKey: call.id) }
        return try await task.value
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

public protocol GUIAutomationBackend: Sendable {
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
