import Foundation
import SwiftUI
import CloudCodeCore
import Security
import ObjectiveC.runtime
#if canImport(Darwin)
import Darwin
#endif

public actor IOSAppResolver: AppContainerResolving, AppEnumerationCapabilityProviding, AppUninstallCapabilityProviding {
    private var cachedApps: [ResourceNode] = []
    private var bundlePaths: [String: String] = [:]
    private var containerPaths: [String: String] = [:]
    private var lastRefresh: Date = .distantPast
    private var enumerationProven = false
    private var enumerationDetail = "尚未检测已安装 App 枚举能力。"
    private var uninstallDetail = "尚未检测 App 卸载后端。"

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

    public func installedAppEnumerationDetail() async -> String {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        return enumerationDetail
    }

    public func canUninstallInstalledApps() async -> Bool {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        guard enumerationProven else {
            uninstallDetail = "必须先验证跨 App 的 LaunchServices 可见性。"
            return false
        }
        guard let target = cachedApps.first(where: {
            guard let bundleID = $0.ownerBundleID, bundleID != Bundle.main.bundleIdentifier else { return false }
            return Self.isUserApplicationBundlePath($0.resolvedPath)
        }), let targetBundleID = target.ownerBundleID else {
            uninstallDetail = "没有可用于无损验证的普通用户 App。"
            return false
        }
        guard let (workspace, workspaceClass) = launchServicesWorkspace() else {
            uninstallDetail = "无法取得 LaunchServices workspace。"
            return false
        }
        let uninstallSelector = NSSelectorFromString("uninstallApplication:withOptions:")
        guard class_getInstanceMethod(workspaceClass, uninstallSelector) != nil else {
            uninstallDetail = "当前系统没有暴露 uninstallApplication:withOptions:。"
            return false
        }
        guard hasAuthoritativeInstallationQuery(workspaceClass) else {
            uninstallDetail = "当前系统没有暴露 applicationIsInstalled:，无法对卸载结果做权威校验。"
            return false
        }
        guard applicationIsInstalled(targetBundleID, workspace: workspace, workspaceClass: workspaceClass) == true else {
            uninstallDetail = "LaunchServices 无损安装状态查询未通过。"
            return false
        }
        uninstallDetail = "LaunchServices 可枚举其他 App、可权威查询安装状态，且卸载 selector 存在；实际卸载仍会做结果校验。"
        return true
    }

    public func installedAppUninstallDetail() async -> String {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        return uninstallDetail
    }

    public func uninstallApplication(bundleID: String) async -> Bool {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return false }
        forceRefresh()
        guard enumerationProven else { return false }
        guard cachedApps.contains(where: {
            $0.ownerBundleID == bundleID && Self.isUserApplicationBundlePath($0.resolvedPath)
        }) else { return false }
        guard await canUninstallInstalledApps(), let (workspace, workspaceClass) = launchServicesWorkspace() else { return false }
        guard applicationIsInstalled(bundleID, workspace: workspace, workspaceClass: workspaceClass) == true else { return false }

        let selector = NSSelectorFromString("uninstallApplication:withOptions:")
        guard let method = class_getInstanceMethod(workspaceClass, selector) else { return false }
        typealias UninstallMethod = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
        let implementation = method_getImplementation(method)
        let uninstall = unsafeBitCast(implementation, to: UninstallMethod.self)
        let accepted = uninstall(workspace, selector, bundleID as NSString, NSDictionary())
        guard accepted else { return false }

        for attempt in 0..<6 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            lastRefresh = .distantPast
            refresh()
            if let (verificationWorkspace, verificationClass) = launchServicesWorkspace(),
               applicationIsInstalled(bundleID, workspace: verificationWorkspace, workspaceClass: verificationClass) == false {
                return true
            }
        }
        return false
    }

    public func forceRefresh() {
        lastRefresh = .distantPast
        refresh()
    }

    private func refresh() {
        defer { lastRefresh = Date() }

        enumerationProven = false
        enumerationDetail = "已安装 App 枚举尚未得到跨 App 可见性的有效证据。"
        uninstallDetail = "正在根据本次 LaunchServices 探测重新判断卸载后端。"
        bundlePaths = [:]
        containerPaths = [:]

        Self.loadLaunchServicesIfNeeded()
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            enumerationDetail = "LSApplicationWorkspace 在当前运行环境中不可用。"
            cachedApps = fallbackOwnApp()
            return
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let classMethod = class_getClassMethod(workspaceClass, defaultSelector) else {
            enumerationDetail = "LSApplicationWorkspace.defaultWorkspace 不可用。"
            cachedApps = fallbackOwnApp()
            return
        }
        typealias ClassObjectMethod = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let classIMP = method_getImplementation(classMethod)
        let getDefaultWorkspace = unsafeBitCast(classIMP, to: ClassObjectMethod.self)
        guard let workspace = getDefaultWorkspace(workspaceClass, defaultSelector)?.takeUnretainedValue() as? NSObject else {
            enumerationDetail = "无法取得 LaunchServices 默认 workspace。"
            cachedApps = fallbackOwnApp()
            return
        }

        let (rawApps, backend) = collectInstalledApplicationProxies(workspace: workspace, workspaceClass: workspaceClass)
        guard !rawApps.isEmpty else {
            enumerationDetail = "\(backend) 未返回任何应用；不能把空数组视为可用能力。"
            cachedApps = fallbackOwnApp()
            return
        }

        var appsByBundleID: [String: ResourceNode] = [:]
        var bundles: [String: String] = [:]
        var containers: [String: String] = [:]
        for proxy in rawApps {
            guard let bundleID = safeString(proxy, key: "applicationIdentifier") ?? safeString(proxy, key: "bundleIdentifier"), !bundleID.isEmpty else { continue }
            let name = safeString(proxy, key: "localizedName") ?? safeString(proxy, key: "itemName") ?? bundleID
            let version = safeString(proxy, key: "shortVersionString")
            let bundleURL = safeURL(proxy, key: "bundleURL")
            let containerURL = safeURL(proxy, key: "dataContainerURL")
            if let bundleURL { bundles[bundleID] = bundleURL.path }
            if let containerURL { containers[bundleID] = containerURL.path }
            appsByBundleID[bundleID] = ResourceNode(
                id: ResourceID("app://\(bundleID)"),
                kind: .app,
                displayName: name,
                logicalLocation: "app://\(bundleID)",
                resolvedPath: bundleURL?.path,
                ownerBundleID: bundleID,
                metadata: ["version": version ?? "", "containerKnown": containerURL == nil ? "false" : "true"]
            )
        }

        let parsedApps = appsByBundleID.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let ownBundleID = Bundle.main.bundleIdentifier
        let crossAppCount = parsedApps.filter { $0.ownerBundleID != nil && $0.ownerBundleID != ownBundleID }.count
        guard crossAppCount > 0 else {
            enumerationDetail = "\(backend) 只暴露了 Cloud Code 自身或无法解析的记录；跨 App 枚举未通过。"
            cachedApps = fallbackOwnApp()
            return
        }

        enumerationProven = true
        enumerationDetail = "\(backend) 返回 \(parsedApps.count) 个有效应用，其中 \(crossAppCount) 个不是 Cloud Code 自身。"
        cachedApps = parsedApps
        bundlePaths = bundles
        containerPaths = containers
    }

    private func launchServicesWorkspace() -> (NSObject, AnyClass)? {
        Self.loadLaunchServicesIfNeeded()
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else { return nil }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let classMethod = class_getClassMethod(workspaceClass, defaultSelector) else { return nil }
        typealias ClassObjectMethod = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(classMethod)
        let getDefaultWorkspace = unsafeBitCast(implementation, to: ClassObjectMethod.self)
        guard let workspace = getDefaultWorkspace(workspaceClass, defaultSelector)?.takeUnretainedValue() as? NSObject else { return nil }
        return (workspace, workspaceClass)
    }

    private func hasAuthoritativeInstallationQuery(_ workspaceClass: AnyClass) -> Bool {
        class_getInstanceMethod(workspaceClass, NSSelectorFromString("applicationIsInstalled:")) != nil
    }

    private func applicationIsInstalled(_ bundleID: String, workspace: NSObject, workspaceClass: AnyClass) -> Bool? {
        let selector = NSSelectorFromString("applicationIsInstalled:")
        guard let method = class_getInstanceMethod(workspaceClass, selector) else { return nil }
        typealias IsInstalledMethod = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let implementation = method_getImplementation(method)
        let isInstalled = unsafeBitCast(implementation, to: IsInstalledMethod.self)
        return isInstalled(workspace, selector, bundleID as NSString)
    }

    private func collectInstalledApplicationProxies(workspace: NSObject, workspaceClass: AnyClass) -> ([NSObject], String) {
        let enumerateSelector = NSSelectorFromString("enumerateApplicationsOfType:block:")
        if let enumerateMethod = class_getInstanceMethod(workspaceClass, enumerateSelector) {
            typealias EnumerationBlock = @convention(block) (AnyObject) -> Void
            typealias EnumerateMethod = @convention(c) (AnyObject, Selector, UInt, EnumerationBlock) -> Void
            let implementation = method_getImplementation(enumerateMethod)
            let enumerate = unsafeBitCast(implementation, to: EnumerateMethod.self)
            var collected: [NSObject] = []
            let block: EnumerationBlock = { object in
                if let proxy = object as? NSObject { collected.append(proxy) }
            }
            enumerate(workspace, enumerateSelector, 0, block)
            enumerate(workspace, enumerateSelector, 1, block)
            if !collected.isEmpty {
                return (collected, "LaunchServices enumerateApplicationsOfType")
            }
        }

        typealias ObjectMethod = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        for selectorName in ["allInstalledApplications", "allApplications"] {
            let selector = NSSelectorFromString(selectorName)
            guard let instanceMethod = class_getInstanceMethod(workspaceClass, selector) else { continue }
            let implementation = method_getImplementation(instanceMethod)
            let getApplications = unsafeBitCast(implementation, to: ObjectMethod.self)
            if let raw = getApplications(workspace, selector)?.takeUnretainedValue() as? [NSObject], !raw.isEmpty {
                return (raw, "LaunchServices \(selectorName)")
            }
        }
        return ([], "LaunchServices")
    }

    private static func isUserApplicationBundlePath(_ path: String?) -> Bool {
        guard let normalized = path?.replacingOccurrences(of: "//", with: "/") else { return false }
        return normalized.hasPrefix("/var/containers/Bundle/Application/") || normalized.hasPrefix("/private/var/containers/Bundle/Application/")
    }

    private static func loadLaunchServicesIfNeeded() {
        #if canImport(Darwin)
        guard NSClassFromString("LSApplicationWorkspace") == nil else { return }
        _ = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL)
        if NSClassFromString("LSApplicationWorkspace") == nil {
            _ = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL)
        }
        #endif
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

public struct IOSPrivateAppExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .privateFramework
    private let appResolver: IOSAppResolver
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting
    private let audit: AuditLogStore

    public init(appResolver: IOSAppResolver, policy: PolicyEngine, approval: ApprovalRequesting, audit: AuditLogStore) {
        self.appResolver = appResolver
        self.policy = policy
        self.approval = approval
        self.audit = audit
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name == "apps.uninstall" && capabilities.isAvailable("apps.uninstall")
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard call.name == "apps.uninstall" else { throw ToolRouterError.noExecutionRoute(call.name) }
        guard let bundleID = call.arguments["bundleId"], Self.isValidBundleIdentifier(bundleID) else {
            throw ToolRouterError.noExecutionRoute("bundleId missing or invalid")
        }
        guard bundleID != Bundle.main.bundleIdentifier else {
            throw ToolRouterError.noExecutionRoute("Cloud Code cannot uninstall itself through the active session")
        }

        let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: bundleID, explicitlyPermanent: true)
        if decision == .requireConfirmation {
            let preview = ApprovalPreview(
                title: "卸载 App",
                target: bundleID,
                reason: "卸载会永久移除目标 App 及其本地数据，无法由 Cloud Code 自动恢复。",
                plan: ["确认目标 Bundle ID", "调用已验证的 LaunchServices 卸载接口", "重新查询安装状态验证结果"],
                risk: .permanentDestructive
            )
            guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
        }

        let before = await appResolver.bundlePath(for: bundleID)
        guard let before, Self.isUserApplicationBundlePath(before) else {
            return ToolResult(
                toolCallID: call.id,
                success: false,
                summary: "未找到待卸载的 App：\(bundleID)",
                verification: VerificationResult(passed: false, checks: ["卸载前目标必须存在且属于普通用户 App 容器"], failures: ["LaunchServices 未解析到该 Bundle ID，或目标属于系统 App/非用户 App 路径"])
            )
        }

        let removed = await appResolver.uninstallApplication(bundleID: bundleID)
        let after = await appResolver.bundlePath(for: bundleID)
        let verified = removed && after == nil
        let verification = VerificationResult(
            passed: verified,
            checks: ["卸载请求被系统接受", "刷新 LaunchServices 后目标不再存在"],
            failures: verified ? [] : ["卸载后仍能解析到目标，或系统未接受卸载请求"]
        )
        try await audit.append(AuditEvent(
            sessionID: call.sessionID,
            toolCallID: call.id,
            action: call.name,
            target: bundleID,
            risk: descriptor.risk,
            result: verified ? "uninstalled" : "verification_failed"
        ))
        return ToolResult(
            toolCallID: call.id,
            success: verified,
            summary: verified ? "已卸载 \(bundleID)" : "卸载未通过结果校验：\(bundleID)",
            payload: ["bundleId": bundleID],
            verification: verification
        )
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isUserApplicationBundlePath(_ path: String?) -> Bool {
        guard let normalized = path?.replacingOccurrences(of: "//", with: "/") else { return false }
        return normalized.hasPrefix("/var/containers/Bundle/Application/") || normalized.hasPrefix("/private/var/containers/Bundle/Application/")
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
        guard tool.name.hasPrefix("gui.") else { return false }
        return await backend.isAvailable()
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
