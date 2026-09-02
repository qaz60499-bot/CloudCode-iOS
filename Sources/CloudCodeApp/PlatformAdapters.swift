import Foundation
import SwiftUI
import CloudCodeCore
import Security
import ObjectiveC.runtime
#if canImport(Darwin)
import Darwin
#endif

public final class KeychainAPIKeyVault: APIKeyVault, @unchecked Sendable {
    public init() {}

    public func set(_ value: String, for reference: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CloudCodeIOS.ProviderKey",
            kSecAttrAccount as String: reference
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func key(for reference: String) async throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CloudCodeIOS.ProviderKey",
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw ProviderError.missingAPIKey
        }
        return value
    }
}

public actor IOSAppResolver: AppContainerResolving, AppEnumerationCapabilityProviding {
    private var cachedApps: [ResourceNode] = []
    private var bundlePaths: [String: String] = [:]
    private var containerPaths: [String: String] = [:]
    private var lastRefresh: Date = .distantPast
    private var enumerationProven = false

    public init() {}

    public func installedApps() async -> [ResourceNode] {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        return cachedApps
    }

    public func bundlePath(for bundleID: String) async -> String? {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        return bundlePaths[bundleID]
    }

    public func dataContainerPath(for bundleID: String) async -> String? {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        if let value = containerPaths[bundleID] { return value }
        if bundleID == Bundle.main.bundleIdentifier { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path }
        return nil
    }

    public func canEnumerateInstalledApps() async -> Bool {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        return enumerationProven
    }

    private func refresh() {
        defer { lastRefresh = Date() }
        var apps: [ResourceNode] = []
        var bundles: [String: String] = [:]
        var containers: [String: String] = [:]

        enumerationProven = false
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            cachedApps = fallbackOwnApp()
            return
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let classMethod = class_getClassMethod(workspaceClass, defaultSelector) else {
            cachedApps = fallbackOwnApp()
            return
        }
        typealias ClassObjectMethod = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let classIMP = method_getImplementation(classMethod)
        let getDefaultWorkspace = unsafeBitCast(classIMP, to: ClassObjectMethod.self)
        guard let workspace = getDefaultWorkspace(workspaceClass, defaultSelector)?.takeUnretainedValue() as? NSObject else {
            cachedApps = fallbackOwnApp()
            return
        }
        let allSelector = NSSelectorFromString("allInstalledApplications")
        guard let instanceMethod = class_getInstanceMethod(workspaceClass, allSelector) else {
            cachedApps = fallbackOwnApp()
            return
        }
        typealias ObjectMethod = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let objectIMP = method_getImplementation(instanceMethod)
        let getAllInstalledApplications = unsafeBitCast(objectIMP, to: ObjectMethod.self)
        guard let rawApps = getAllInstalledApplications(workspace, allSelector)?.takeUnretainedValue() as? [NSObject] else {
            cachedApps = fallbackOwnApp()
            return
        }
        enumerationProven = true

        for proxy in rawApps {
            guard let bundleID = safeString(proxy, key: "applicationIdentifier") ?? safeString(proxy, key: "bundleIdentifier"), !bundleID.isEmpty else { continue }
            let name = safeString(proxy, key: "localizedName") ?? safeString(proxy, key: "itemName") ?? bundleID
            let version = safeString(proxy, key: "shortVersionString")
            let bundleURL = safeURL(proxy, key: "bundleURL")
            let containerURL = safeURL(proxy, key: "dataContainerURL")
            if let bundleURL { bundles[bundleID] = bundleURL.path }
            if let containerURL { containers[bundleID] = containerURL.path }
            apps.append(ResourceNode(
                id: ResourceID("app://\(bundleID)"),
                kind: .app,
                displayName: name,
                logicalLocation: "app://\(bundleID)",
                resolvedPath: bundleURL?.path,
                ownerBundleID: bundleID,
                metadata: ["version": version ?? "", "containerKnown": containerURL == nil ? "false" : "true"]
            ))
        }
        cachedApps = apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        bundlePaths = bundles
        containerPaths = containers
    }

    private func fallbackOwnApp() -> [ResourceNode] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        bundlePaths[bundleID] = Bundle.main.bundleURL.path
        containerPaths[bundleID] = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
        return [ResourceNode(id: ResourceID("app://\(bundleID)"), kind: .app, displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Cloud Code", logicalLocation: "app://\(bundleID)", resolvedPath: Bundle.main.bundleURL.path, ownerBundleID: bundleID)]
    }

    private func safeString(_ object: NSObject, key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private func safeURL(_ object: NSObject, key: String) -> URL? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? URL
    }
}

@MainActor
public final class ApprovalCenter: ObservableObject, ApprovalRequesting, @unchecked Sendable {
    @Published public private(set) var pending: ApprovalPreview?
    private var continuation: CheckedContinuation<Bool, Never>?

    public init() {}

    public func requestApproval(_ preview: ApprovalPreview) async -> Bool {
        if continuation != nil { return false }
        pending = preview
        return await withCheckedContinuation { continuation = $0 }
    }

    public func approve() {
        pending = nil
        continuation?.resume(returning: true)
        continuation = nil
    }

    public func deny() {
        pending = nil
        continuation?.resume(returning: false)
        continuation = nil
    }
}

public struct IOSSystemExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .cli
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting

    public init(policy: PolicyEngine, approval: ApprovalRequesting) {
        self.policy = policy
        self.approval = approval
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name == "advanced.shell" && capabilities.isAvailable("execution.ios_system")
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard let command = call.arguments["command"], !command.isEmpty else { throw ToolRouterError.noExecutionRoute("command missing") }
        let decision = policy.decision(mode: context.permissionMode, tool: descriptor)
        if decision == .requireConfirmation {
            let preview = ApprovalPreview(title: "Run advanced shell", target: command, originalSummary: nil, diff: nil, reason: "Generic shell bypasses typed-tool safety and is high risk", plan: ["Validate permission", "Execute ios_system", "Capture exit status"], risk: .systemChange)
            guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
        }
        #if canImport(Darwin)
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "ios_system") else { throw ToolRouterError.noExecutionRoute("ios_system symbol missing") }
        typealias IOSSystemFunction = @convention(c) (UnsafePointer<CChar>) -> Int32
        let function = unsafeBitCast(symbol, to: IOSSystemFunction.self)
        let code = command.withCString { function($0) }
        return ToolResult(toolCallID: call.id, success: code == 0, summary: "ios_system exited \(code)", payload: ["exitCode": String(code)])
        #else
        throw ToolRouterError.noExecutionRoute("ios_system unavailable")
        #endif
    }
}

public struct URLSchemeExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .urlScheme
    public init() {}
    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool { false }
    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        throw ToolRouterError.noExecutionRoute(call.name)
    }
}

public struct GUIFallbackExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .guiFallback
    private let backend: GUIAutomationBackend

    public init(backend: GUIAutomationBackend) { self.backend = backend }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name.hasPrefix("gui.") && await backend.isAvailable()
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        switch call.name {
        case "gui.openApp":
            guard let bundle = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            try await backend.openApp(bundleID: bundle)
            return ToolResult(toolCallID: call.id, success: true, summary: "Opened app")
        case "gui.tree":
            let tree = try await backend.tree()
            return ToolResult(toolCallID: call.id, success: true, summary: "GUI tree read", payload: ["tree": ToolOutputEnvelope(trust: .untrustedData, source: "gui.tree", content: tree).promptSafeRepresentation])
        case "gui.screenshot":
            let data = try await backend.screenshot()
            return ToolResult(toolCallID: call.id, success: true, summary: "Screenshot captured", payload: ["byteCount": String(data.count)])
        case "gui.tap":
            try await backend.tap(x: Double(call.arguments["x"] ?? "0") ?? 0, y: Double(call.arguments["y"] ?? "0") ?? 0)
            return ToolResult(toolCallID: call.id, success: true, summary: "Tap executed")
        case "gui.type":
            try await backend.type(call.arguments["text"] ?? "")
            return ToolResult(toolCallID: call.id, success: true, summary: "Text input executed")
        case "gui.scroll":
            try await backend.scroll(deltaX: Double(call.arguments["dx"] ?? "0") ?? 0, deltaY: Double(call.arguments["dy"] ?? "0") ?? 0)
            return ToolResult(toolCallID: call.id, success: true, summary: "Scroll executed")
        case "gui.swipe":
            try await backend.swipe(fromX: Double(call.arguments["fromX"] ?? "0") ?? 0, fromY: Double(call.arguments["fromY"] ?? "0") ?? 0, toX: Double(call.arguments["toX"] ?? "0") ?? 0, toY: Double(call.arguments["toY"] ?? "0") ?? 0, duration: Double(call.arguments["duration"] ?? "0.3") ?? 0.3)
            return ToolResult(toolCallID: call.id, success: true, summary: "Swipe executed")
        case "gui.verify":
            let result = try await backend.verify(call.arguments["assertion"] ?? "")
            return ToolResult(toolCallID: call.id, success: result.passed, summary: "GUI verification", verification: result)
        default:
            throw ToolRouterError.noExecutionRoute(call.name)
        }
    }
}
