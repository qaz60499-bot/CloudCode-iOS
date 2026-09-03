import Foundation
import SwiftUI
import CloudCodeCore
import Security
import ObjectiveC.runtime
#if canImport(Darwin)
import Darwin
#endif

public enum AppUninstallOutcome: Sendable, Equatable {
    case removed
    case removedWithResidualData(String)
    case rejected(String)
    case verificationTimedOut(String)
}

private enum EmbeddedRootHelper {
    static let executableName = "CloudCodeRootHelper"

    static var executablePath: String {
        Bundle.main.bundleURL.appendingPathComponent(executableName, isDirectory: false).path
    }

    private static func run(_ arguments: [String]) -> (code: Int, diagnostic: String) {
        var diagnostic: NSString?
        let code = CloudCodeSpawnRootHelperWithOutput(executablePath, arguments, &diagnostic)
        let text = (diagnostic as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (code, text)
    }

    private static func failureDetail(prefix: String, code: Int, diagnostic: String) -> String {
        let meaning: String
        switch code {
        case 20: meaning = "目标 Bundle 路径未通过安全校验"
        case 21: meaning = "目标数据容器路径未通过安全校验"
        case 22: meaning = "目标 Bundle 容器路径未通过安全校验"
        case 23: meaning = "无法取得 LaunchServices workspace"
        case 30: meaning = "旧版 helper 的必需路径删除失败"
        case 31: meaning = "删除后的最终状态校验未通过"
        case 32: meaning = "目标 App 进程未能停止"
        case 33: meaning = "进程检查后端不可用"
        case 34: meaning = "Bundle 容器删除失败，数据容器保持未动"
        case 35: meaning = "App Bundle 已移除，但已知数据容器仍有残留"
        default: meaning = ""
        }
        let suffix = meaning.isEmpty ? "" : "（\(meaning)）"
        return diagnostic.isEmpty ? "\(prefix)退出码 \(code)\(suffix)。" : "\(prefix)退出码 \(code)\(suffix)：\(diagnostic)"
    }

    static func probe() -> RootHelperCapabilitySnapshot {
        let path = executablePath
        guard FileManager.default.fileExists(atPath: path) else {
            return RootHelperCapabilitySnapshot(available: false, detail: "\(executableName) 未包含在当前 App Bundle 中。")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return RootHelperCapabilitySnapshot(available: false, detail: "\(executableName) 存在但没有可执行权限。")
        }
        let result = run(["probe"])
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "\(executableName) 已通过 persona 99 / UID 0 / GID 0 探测。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "\(executableName) root 探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func uninstall(bundleID: String, bundlePath: String, dataPath: String?) -> (accepted: Bool, detail: String) {
        let capability = probe()
        guard capability.available else { return (false, capability.detail) }
        let result = run(["uninstall", bundleID, bundlePath, dataPath ?? "-"])
        if result.code == 0 {
            let detail = result.diagnostic.isEmpty ? "Embedded root helper 已执行受限卸载流程" : "Embedded root helper 已执行受限卸载流程：\(result.diagnostic)"
            return (true, detail)
        }
        return (false, failureDetail(prefix: "Embedded root helper 卸载", code: result.code, diagnostic: result.diagnostic))
    }

    static func terminateCapability() -> RootHelperCapabilitySnapshot {
        let root = probe()
        guard root.available else { return root }
        let result = run(["probe-terminate"])
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "Embedded root helper 已验证 root 身份及按进程路径定位能力。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "Embedded root helper 的进程定位后端探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func terminate(bundlePath: String) -> (success: Bool, detail: String) {
        let capability = terminateCapability()
        guard capability.available else { return (false, capability.detail) }
        let result = run(["terminate", bundlePath])
        if result.code == 0 {
            return (true, result.diagnostic.isEmpty ? "Embedded root helper 已确认目标 App 进程停止" : "Embedded root helper 已确认目标 App 进程停止：\(result.diagnostic)")
        }
        return (false, failureDetail(prefix: "Embedded root helper 停止 App", code: result.code, diagnostic: result.diagnostic))
    }
}

public actor IOSAppResolver: AppContainerResolving, AppEnumerationCapabilityProviding, AppUninstallCapabilityProviding, RootHelperCapabilityProviding, AppLifecycleCapabilityProviding {
    private var cachedApps: [ResourceNode] = []
    private var bundlePaths: [String: String] = [:]
    private var containerPaths: [String: String] = [:]
    private var lastRefresh: Date = .distantPast
    private var enumerationProven = false
    private var enumerationDetail = "尚未检测已安装 App 枚举能力。"
    private var uninstallDetail = "尚未检测 App 卸载后端。"
    private var pendingUninstallBundleID: String?
    private let diagnosticLogger: DiagnosticLogStore?

    public init(diagnosticLogger: DiagnosticLogStore? = nil) {
        self.diagnosticLogger = diagnosticLogger
    }

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

    public func rootHelperCapability() async -> RootHelperCapabilitySnapshot {
        let snapshot = EmbeddedRootHelper.probe()
        try? await diagnosticLogger?.log(
            level: snapshot.available ? .info : .warning,
            subsystem: "root-helper",
            action: "probe",
            result: snapshot.available ? "available" : "unavailable",
            diagnostic: snapshot.detail
        )
        return snapshot
    }

    public func appLaunchCapability() async -> AppLifecycleCapabilitySnapshot {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        guard enumerationProven else {
            return AppLifecycleCapabilitySnapshot(available: false, detail: "跨 App 枚举尚未验证，不能安全启动任意目标 App。")
        }
        guard let (_, workspaceClass) = launchServicesWorkspace() else {
            return AppLifecycleCapabilitySnapshot(available: false, detail: "无法取得 LaunchServices workspace。")
        }
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        let available = class_getInstanceMethod(workspaceClass, selector) != nil
        return AppLifecycleCapabilitySnapshot(
            available: available,
            detail: available ? "LaunchServices openApplicationWithBundleID: selector 可用。" : "当前系统未暴露 openApplicationWithBundleID:。"
        )
    }

    public func appTerminateCapability() async -> AppLifecycleCapabilitySnapshot {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        guard enumerationProven else {
            return AppLifecycleCapabilitySnapshot(available: false, detail: "跨 App 枚举尚未验证，不能安全定位待停止的 App。")
        }
        let helper = EmbeddedRootHelper.terminateCapability()
        try? await diagnosticLogger?.log(
            level: helper.available ? .info : .warning,
            subsystem: "root-helper",
            action: "terminate-capability",
            result: helper.available ? "available" : "unavailable",
            diagnostic: helper.detail
        )
        return AppLifecycleCapabilitySnapshot(
            available: helper.available,
            detail: helper.available ? "Embedded root helper 可按目标 Bundle 路径停止进程并验证结果。" : helper.detail
        )
    }

    public func launchApplication(bundleID: String) async -> (success: Bool, detail: String) {
        forceRefresh()
        guard let path = bundlePaths[bundleID], Self.isUserApplicationBundlePath(path) else {
            return (false, "目标不是当前可验证的普通用户 App，或已经不存在。")
        }
        let capability = await appLaunchCapability()
        guard capability.available else {
            return (false, "启动能力不可用：\(capability.detail)")
        }
        guard let (workspace, workspaceClass) = launchServicesWorkspace() else {
            return (false, "无法取得 LaunchServices workspace。")
        }
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard let method = class_getInstanceMethod(workspaceClass, selector) else {
            return (false, "当前系统没有暴露 openApplicationWithBundleID:。")
        }
        typealias OpenApplicationMethod = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let implementation = method_getImplementation(method)
        let openApplication = unsafeBitCast(implementation, to: OpenApplicationMethod.self)
        let success = openApplication(workspace, selector, bundleID as NSString)
        return (success, success ? "LaunchServices 已接受启动请求。" : "LaunchServices 拒绝启动请求。")
    }

    public func terminateApplication(bundleID: String) async -> (success: Bool, detail: String) {
        forceRefresh()
        guard let path = bundlePaths[bundleID], Self.isUserApplicationBundlePath(path) else {
            return (false, "目标不是当前可验证的普通用户 App，或已经不存在。")
        }
        let capability = await appTerminateCapability()
        guard capability.available else { return (false, "停止能力不可用：\(capability.detail)") }
        let outcome = EmbeddedRootHelper.terminate(bundlePath: path)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "root-helper",
            action: "terminate",
            result: outcome.success ? "success" : "failure",
            diagnostic: outcome.detail,
            metadata: ["bundleID": bundleID, "bundlePath": path]
        )
        return outcome
    }

    public func canUninstallInstalledApps() async -> Bool {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        guard enumerationProven else {
            uninstallDetail = "必须先验证跨 App 的 LaunchServices 可见性。"
            return false
        }
        if let pendingBundleID = pendingUninstallBundleID {
            guard let (workspace, workspaceClass) = launchServicesWorkspace(),
                  let installed = applicationIsInstalled(pendingBundleID, workspace: workspace, workspaceClass: workspaceClass) else {
                uninstallDetail = "上一次卸载请求 \(pendingBundleID) 的最终状态仍无法权威确认；在完成状态核对前不会开启新的卸载。"
                return false
            }
            if installed {
                // 这里已经完成了“先核对最终状态”：权威查询确认目标仍然安装，说明上一轮
                // 没有观察到删除生效。清除本轮内存态 pending，允许之后由新的、显式确认过的
                // Tool Call 再次尝试；持久化 execution ledger 仍会阻止旧 Tool Call ID 的盲目重放。
                pendingUninstallBundleID = nil
                uninstallDetail = "上一次卸载请求 \(pendingBundleID) 已完成状态核对：目标仍处于已安装状态；旧 Tool Call 不会重放，新的卸载仍需重新确认。"
            } else {
                pendingUninstallBundleID = nil
                cachedApps.removeAll { $0.ownerBundleID == pendingBundleID }
                bundlePaths.removeValue(forKey: pendingBundleID)
                containerPaths.removeValue(forKey: pendingBundleID)
            }
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
        let hasLaunchServicesUninstall = class_getInstanceMethod(workspaceClass, NSSelectorFromString("uninstallApplication:withOptions:error:")) != nil
            || class_getInstanceMethod(workspaceClass, NSSelectorFromString("uninstallApplication:withOptions:")) != nil
        let hasMobileInstallationFallback = Self.mobileInstallationUninstallSymbol() != nil
        let rootHelper = EmbeddedRootHelper.probe()
        guard hasLaunchServicesUninstall || hasMobileInstallationFallback || rootHelper.available else {
            uninstallDetail = "当前系统卸载 SPI 不可用，且嵌入式 root helper 未通过探测：\(rootHelper.detail)"
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
        var backends: [String] = []
        if hasLaunchServicesUninstall { backends.append("LaunchServices") }
        if hasMobileInstallationFallback { backends.append("MobileInstallation") }
        if rootHelper.available { backends.append("Embedded root helper") }
        uninstallDetail = "已验证跨 App 枚举和权威安装状态查询；可用卸载后端：\(backends.joined(separator: " + "))。root helper 状态：\(rootHelper.detail) 实际卸载仍会验证注册状态、Bundle 和数据容器。"
        return true
    }

    public func installedAppUninstallDetail() async -> String {
        if Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        return uninstallDetail
    }

    public func uninstallApplication(bundleID: String) async -> AppUninstallOutcome {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else {
            return .rejected("目标 Bundle ID 无效，或目标是 Cloud Code 自身。")
        }
        forceRefresh()
        guard enumerationProven else {
            return .rejected("跨 App 枚举能力当前未通过验证。")
        }
        guard let bundlePath = bundlePaths[bundleID], Self.isUserApplicationBundlePath(bundlePath) else {
            return .rejected("目标不是当前可验证的普通用户 App，或已经不存在。")
        }
        let dataPath = containerPaths[bundleID]
        guard await canUninstallInstalledApps(), let (workspace, workspaceClass) = launchServicesWorkspace() else {
            return .rejected(uninstallDetail)
        }
        guard applicationIsInstalled(bundleID, workspace: workspace, workspaceClass: workspaceClass) == true else {
            return .rejected("LaunchServices 在执行前未确认目标仍处于已安装状态。")
        }

        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "app-management",
            action: "uninstall",
            result: "started",
            metadata: ["bundleID": bundleID, "bundlePath": bundlePath]
        )
        var request = performUninstallRequest(bundleID: bundleID, workspace: workspace, workspaceClass: workspaceClass)
        if !request.accepted {
            let rootFallback = EmbeddedRootHelper.uninstall(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath)
            try? await diagnosticLogger?.log(
                level: rootFallback.accepted ? .info : .warning,
                subsystem: "root-helper",
                action: "uninstall-fallback",
                result: rootFallback.accepted ? "accepted" : "rejected",
                diagnostic: rootFallback.detail,
                metadata: ["bundleID": bundleID]
            )
            if rootFallback.accepted {
                request = rootFallback
            } else {
                let reconciliation = reconcileUninstallState(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath, workspace: workspace, workspaceClass: workspaceClass)
                switch reconciliation {
                case .removed:
                    return .removed
                case .removedWithResidualData(let detail):
                    return .removedWithResidualData(detail)
                case .stillInstalled:
                    uninstallDetail = "系统卸载 SPI 被拒绝，root helper fallback 也未成功。系统后端：\(request.detail)；root helper：\(rootFallback.detail)"
                    return .rejected(uninstallDetail)
                case .inconsistent(let detail):
                    uninstallDetail = "卸载 fallback 返回失败且最终状态不一致：\(detail)。系统后端：\(request.detail)；root helper：\(rootFallback.detail)"
                    pendingUninstallBundleID = bundleID
                    return .verificationTimedOut(uninstallDetail)
                }
            }
        }

        pendingUninstallBundleID = bundleID
        uninstallDetail = "卸载请求已由 \(request.detail) 接受；正在同时验证 LaunchServices 注册状态、Bundle 目录和数据容器。"
        if await verifyUninstallPostconditions(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath, attempts: 31) {
            finalizeVerifiedUninstall(bundleID: bundleID)
            try? await diagnosticLogger?.log(level: .info, subsystem: "verification", action: "apps.uninstall", result: "passed", diagnostic: uninstallDetail, metadata: ["bundleID": bundleID])
            return .removed
        }

        // 有些系统会先接受 LaunchServices 请求但迟迟不执行删除。只要这是同一个已经确认过的
        // Tool Call，就允许在完成第一次最终状态核对后升级到嵌入式 root helper；这不是盲目重放。
        if !request.detail.contains("root helper") {
            let rootFallback = EmbeddedRootHelper.uninstall(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath)
            try? await diagnosticLogger?.log(
                level: rootFallback.accepted ? .info : .error,
                subsystem: "root-helper",
                action: "uninstall-escalation",
                result: rootFallback.accepted ? "accepted" : "failed",
                diagnostic: rootFallback.detail,
                metadata: ["bundleID": bundleID]
            )
            if rootFallback.accepted {
                uninstallDetail = "LaunchServices 接受请求但未完成删除，已在同一确认操作内切换到 root helper fallback；正在再次验证最终状态。"
                if await verifyUninstallPostconditions(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath, attempts: 20) {
                    finalizeVerifiedUninstall(bundleID: bundleID)
                    try? await diagnosticLogger?.log(level: .info, subsystem: "verification", action: "apps.uninstall", result: "passed_after_root_fallback", diagnostic: uninstallDetail, metadata: ["bundleID": bundleID])
                    return .removed
                }
            } else {
                uninstallDetail = "LaunchServices 请求未在约 12 秒内完成；root helper fallback 也失败：\(rootFallback.detail)"
            }
        }

        let timeoutDetail = uninstallDetail + "。目标最终状态仍未满足‘注册消失 + Bundle 消失 + 已知数据容器消失’，因此不会误报卸载成功。"
        try? await diagnosticLogger?.log(level: .error, subsystem: "verification", action: "apps.uninstall", result: "timed_out", diagnostic: timeoutDetail, metadata: ["bundleID": bundleID])
        return .verificationTimedOut(timeoutDetail)
    }

    private enum UninstallReconciliation {
        case removed
        case removedWithResidualData(String)
        case stillInstalled
        case inconsistent(String)
    }

    private func reconcileUninstallState(bundleID: String, bundlePath: String, dataPath: String?, workspace: NSObject, workspaceClass: AnyClass) -> UninstallReconciliation {
        let fileManager = FileManager.default
        let installed = applicationIsInstalled(bundleID, workspace: workspace, workspaceClass: workspaceClass)
        let bundleExists = fileManager.fileExists(atPath: bundlePath)
        let dataExists = dataPath.map { fileManager.fileExists(atPath: $0) } ?? false

        if installed == false && !bundleExists {
            finalizeVerifiedUninstall(bundleID: bundleID)
            if dataExists {
                let detail = "目标 App 已从 LaunchServices 注册和 Bundle 路径移除，但已知数据容器仍存在：\(dataPath ?? "未知")。不会把残留数据误报为完整卸载。"
                uninstallDetail = detail
                return .removedWithResidualData(detail)
            }
            return .removed
        }
        if installed == true && bundleExists {
            return .stillInstalled
        }
        return .inconsistent("LaunchServices installed=\(installed.map { String(describing: $0) } ?? "unknown"), bundleExists=\(bundleExists), dataExists=\(dataExists)")
    }

    private func verifyUninstallPostconditions(bundleID: String, bundlePath: String, dataPath: String?, attempts: Int) async -> Bool {
        let fileManager = FileManager.default
        for attempt in 0..<attempts {
            if Task.isCancelled { return false }
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard let (verificationWorkspace, verificationClass) = launchServicesWorkspace() else { continue }
            let registrationGone = applicationIsInstalled(bundleID, workspace: verificationWorkspace, workspaceClass: verificationClass) == false
            let bundleGone = !fileManager.fileExists(atPath: bundlePath)
            let dataGone = dataPath.map { !fileManager.fileExists(atPath: $0) } ?? true
            if registrationGone && bundleGone && dataGone { return true }
        }
        return false
    }

    private func finalizeVerifiedUninstall(bundleID: String) {
        pendingUninstallBundleID = nil
        cachedApps.removeAll { $0.ownerBundleID == bundleID }
        bundlePaths.removeValue(forKey: bundleID)
        containerPaths.removeValue(forKey: bundleID)
        lastRefresh = .distantPast
        uninstallDetail = "最近一次卸载已通过三项最终校验：LaunchServices 未安装、Bundle 已移除、已知数据容器已移除。"
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

    private func performUninstallRequest(bundleID: String, workspace: NSObject, workspaceClass: AnyClass) -> (accepted: Bool, detail: String) {
        let errorSelector = NSSelectorFromString("uninstallApplication:withOptions:error:")
        if let method = class_getInstanceMethod(workspaceClass, errorSelector) {
            typealias UninstallErrorMethod = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, UnsafeMutablePointer<AnyObject?>?) -> Bool
            let implementation = method_getImplementation(method)
            let uninstall = unsafeBitCast(implementation, to: UninstallErrorMethod.self)
            var errorObject: AnyObject?
            let accepted = uninstall(workspace, errorSelector, bundleID as NSString, NSDictionary(), &errorObject)
            if accepted { return (true, "LaunchServices(error-aware)") }
            if let error = errorObject as? NSError {
                uninstallDetail = "LaunchServices(error-aware) 拒绝：\(error.domain) \(error.code) · \(error.localizedDescription)"
            } else {
                uninstallDetail = "LaunchServices(error-aware) 返回 rejected，未提供 NSError。"
            }
        }

        let legacySelector = NSSelectorFromString("uninstallApplication:withOptions:")
        if let method = class_getInstanceMethod(workspaceClass, legacySelector) {
            typealias UninstallMethod = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
            let implementation = method_getImplementation(method)
            let uninstall = unsafeBitCast(implementation, to: UninstallMethod.self)
            if uninstall(workspace, legacySelector, bundleID as NSString, NSDictionary()) {
                return (true, "LaunchServices(legacy)")
            }
            uninstallDetail += uninstallDetail.isEmpty ? "LaunchServices(legacy) 返回 rejected。" : "；LaunchServices(legacy) 也返回 rejected。"
        }

        #if canImport(Darwin)
        if let symbol = Self.mobileInstallationUninstallSymbol() {
            typealias MobileInstallationUninstall = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Int32
            let uninstall = unsafeBitCast(symbol, to: MobileInstallationUninstall.self)
            let identifier = bundleID as NSString
            let identifierPointer = UnsafeRawPointer(Unmanaged.passUnretained(identifier).toOpaque())
            let code = uninstall(identifierPointer, nil, nil)
            if code == 0 { return (true, "MobileInstallationUninstall") }
            uninstallDetail += uninstallDetail.isEmpty ? "MobileInstallationUninstall 返回 \(code)。" : "；MobileInstallationUninstall 返回 \(code)。"
        }
        #endif

        return (false, uninstallDetail.isEmpty ? "没有可执行的卸载后端。" : uninstallDetail)
    }

    private static func mobileInstallationUninstallSymbol() -> UnsafeMutableRawPointer? {
        #if canImport(Darwin)
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        return dlsym(handle, "MobileInstallationUninstall")
        #else
        return nil
        #endif
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
        if decision == .deny { throw TransactionError.confirmationDenied }
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
        switch tool.name {
        case "apps.launch": return capabilities.isAvailable("apps.launch")
        case "apps.terminate": return capabilities.isAvailable("apps.terminate")
        case "apps.uninstall": return capabilities.isAvailable("apps.uninstall")
        default: return false
        }
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard let bundleID = call.arguments["bundleId"], Self.isValidBundleIdentifier(bundleID) else {
            throw ToolRouterError.noExecutionRoute("bundleId missing or invalid")
        }

        if call.name == "apps.launch" {
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: bundleID)
            if decision == .deny { throw TransactionError.confirmationDenied }
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: "启动 App",
                    target: bundleID,
                    reason: "启动目标 App 会改变设备前台状态。",
                    plan: ["确认目标 Bundle ID", "调用已验证的 LaunchServices 启动接口", "记录启动结果"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let outcome = await appResolver.launchApplication(bundleID: bundleID)
            try await audit.append(AuditEvent(
                sessionID: call.sessionID,
                toolCallID: call.id,
                action: call.name,
                target: bundleID,
                risk: descriptor.risk,
                result: outcome.success ? "launch_accepted" : "launch_rejected",
                detail: ["diagnostic": outcome.detail]
            ))
            return ToolResult(
                toolCallID: call.id,
                success: outcome.success,
                summary: outcome.success ? "已请求启动 \(bundleID)" : "启动失败：\(outcome.detail)",
                payload: ["bundleId": bundleID, "detail": outcome.detail],
                verification: VerificationResult(passed: outcome.success, checks: ["LaunchServices 接受目标 App 启动请求"], failures: outcome.success ? [] : [outcome.detail])
            )
        }

        if call.name == "apps.terminate" {
            guard bundleID != Bundle.main.bundleIdentifier else {
                throw ToolRouterError.noExecutionRoute("Cloud Code cannot terminate itself through the active session")
            }
            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: bundleID)
            if decision == .deny { throw TransactionError.confirmationDenied }
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: "停止 App",
                    target: bundleID,
                    reason: "停止目标 App 会中断其当前前台或后台工作。",
                    plan: ["确认目标 Bundle ID", "通过受限 root helper 停止目标 App 进程", "确认目标进程已退出"],
                    risk: .systemChange
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }
            let outcome = await appResolver.terminateApplication(bundleID: bundleID)
            try await audit.append(AuditEvent(
                sessionID: call.sessionID,
                toolCallID: call.id,
                action: call.name,
                target: bundleID,
                risk: descriptor.risk,
                result: outcome.success ? "terminated" : "terminate_failed",
                detail: ["diagnostic": outcome.detail]
            ))
            return ToolResult(
                toolCallID: call.id,
                success: outcome.success,
                summary: outcome.success ? "已停止 \(bundleID)" : "停止失败：\(outcome.detail)",
                payload: ["bundleId": bundleID, "detail": outcome.detail],
                verification: VerificationResult(passed: outcome.success, checks: ["目标 Bundle 路径解析成功", "root helper 确认对应进程已退出"], failures: outcome.success ? [] : [outcome.detail])
            )
        }

        guard call.name == "apps.uninstall" else { throw ToolRouterError.noExecutionRoute(call.name) }
        guard bundleID != Bundle.main.bundleIdentifier else {
            throw ToolRouterError.noExecutionRoute("Cloud Code cannot uninstall itself through the active session")
        }

        let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: bundleID, explicitlyPermanent: true)
        if decision == .deny { throw TransactionError.confirmationDenied }
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

        let outcome = await appResolver.uninstallApplication(bundleID: bundleID)
        let verified: Bool
        let summary: String
        let auditResult: String
        let payloadStatus: String
        let failures: [String]
        switch outcome {
        case .removed:
            let after = await appResolver.bundlePath(for: bundleID)
            verified = after == nil
            summary = verified ? "已卸载 \(bundleID)" : "系统已确认卸载，但应用索引仍有陈旧记录：\(bundleID)"
            auditResult = verified ? "uninstalled" : "index_stale_after_uninstall"
            payloadStatus = verified ? "removed" : "removed_index_stale"
            failures = verified ? [] : ["LaunchServices 已确认未安装，但刷新后的应用索引仍返回目标路径"]
        case .removedWithResidualData(let reason):
            verified = false
            summary = "App 已移除，但数据清理不完整：\(bundleID) · \(reason)"
            auditResult = "removed_with_residual_data"
            payloadStatus = "removed_with_residual_data"
            failures = [reason]
        case .rejected(let reason):
            verified = false
            summary = "卸载请求未被系统接受：\(bundleID) · \(reason)"
            auditResult = "request_rejected"
            payloadStatus = "rejected"
            failures = [reason]
        case .verificationTimedOut(let reason):
            verified = false
            summary = "卸载请求已接受，但结果校验尚未完成：\(bundleID) · 请先重新检测/确认目标是否仍存在，不要直接重复卸载"
            auditResult = "verification_pending"
            payloadStatus = "verification_pending"
            failures = [reason]
        }
        let verification = VerificationResult(
            passed: verified,
            checks: ["卸载请求被系统接受", "通过 LaunchServices 权威安装状态反查", "刷新应用索引后目标路径消失"],
            failures: failures
        )
        try await audit.append(AuditEvent(
            sessionID: call.sessionID,
            toolCallID: call.id,
            action: call.name,
            target: bundleID,
            risk: descriptor.risk,
            result: auditResult,
            detail: [
                "status": payloadStatus,
                "diagnostic": failures.joined(separator: " | ")
            ]
        ))
        return ToolResult(
            toolCallID: call.id,
            success: verified,
            summary: summary,
            payload: [
                "bundleId": bundleID,
                "status": payloadStatus,
                "diagnostic": failures.joined(separator: " | ")
            ],
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
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting

    public init(backend: GUIAutomationBackend, policy: PolicyEngine, approval: ApprovalRequesting) {
        self.backend = backend
        self.policy = policy
        self.approval = approval
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        guard tool.name.hasPrefix("gui.") else { return false }
        return await backend.isAvailable()
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        switch call.name {
        case "gui.openApp":
            guard let bundle = call.arguments["bundleId"], !bundle.isEmpty else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
        case "gui.tree", "gui.screenshot":
            break
        case "gui.tap":
            guard Double(call.arguments["x"] ?? "") != nil, Double(call.arguments["y"] ?? "") != nil else {
                throw ToolRouterError.noExecutionRoute("tap coordinates missing or invalid")
            }
        case "gui.type":
            guard call.arguments["text"] != nil else { throw ToolRouterError.noExecutionRoute("text missing") }
        case "gui.scroll":
            guard Double(call.arguments["dx"] ?? "") != nil, Double(call.arguments["dy"] ?? "") != nil else {
                throw ToolRouterError.noExecutionRoute("scroll delta missing or invalid")
            }
        case "gui.swipe":
            let keys = ["fromX", "fromY", "toX", "toY"]
            guard keys.allSatisfy({ Double(call.arguments[$0] ?? "") != nil }) else {
                throw ToolRouterError.noExecutionRoute("swipe coordinates missing or invalid")
            }
        case "gui.verify":
            guard call.arguments["assertion"] != nil else { throw ToolRouterError.noExecutionRoute("assertion missing") }
        default:
            throw ToolRouterError.noExecutionRoute(call.name)
        }
        let approvalTarget = GUIApprovalTargetSanitizer.target(for: call)

        let decision = policy.decision(mode: context.permissionMode, tool: descriptor)
        if decision == .deny { throw TransactionError.confirmationDenied }
        if decision == .requireConfirmation {
            let preview = ApprovalPreview(
                title: "执行 GUI 操作",
                target: approvalTarget,
                reason: "GUI 写入可能影响前台 App 状态或输入敏感内容。",
                plan: ["验证操作参数", "确认操作类型", "执行受限 GUI 动作", "按需验证界面状态"],
                risk: descriptor.risk
            )
            guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
        }
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
