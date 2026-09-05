import Foundation
import SwiftUI
import CloudCodeCore
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
    struct EnumeratedApp: Decodable {
        var bundleID: String
        var name: String
        var version: String
        var bundlePath: String
        var dataContainerPath: String
    }

    struct EnumerationPayload: Decodable {
        var backend: String
        var apps: [EnumeratedApp]
    }

    static let executableName = "CloudCodeRootHelper"

    static var executablePath: String {
        Bundle.main.bundleURL.appendingPathComponent(executableName, isDirectory: false).path
    }

    private enum PrivilegeMode {
        case isolatedUser
        case root
    }

    private static func run(_ arguments: [String], privilege: PrivilegeMode, timeout: TimeInterval = 6) -> (code: Int, diagnostic: String) {
        var diagnostic: NSString?
        let code = CloudCodeSpawnHelperWithOutput(
            executablePath,
            arguments,
            privilege == .root,
            timeout,
            &diagnostic
        )
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
        case 40: meaning = "隔离 LaunchServices 枚举没有返回有效应用"
        case 41: meaning = "隔离枚举结果无法序列化"
        case 42: meaning = "App 启动 selector 不可用"
        case 43: meaning = "权威安装状态查询 selector 不可用"
        case 44: meaning = "用于卸载能力验证的目标 App 已不在安装状态"
        case 45: meaning = "LaunchServices/MobileInstallation 卸载后端均不可用"
        case 46: meaning = "LaunchServices 拒绝启动目标 App"
        case 47: meaning = "目标 App 已确认不在安装状态"
        default: meaning = ""
        }
        let suffix = meaning.isEmpty ? "" : "（\(meaning)）"
        return diagnostic.isEmpty ? "\(prefix)退出码 \(code)\(suffix)。" : "\(prefix)退出码 \(code)\(suffix)：\(diagnostic)"
    }

    static func enumerateInstalledApps() -> (payload: EnumerationPayload?, detail: String) {
        let path = executablePath
        guard FileManager.default.fileExists(atPath: path), FileManager.default.isExecutableFile(atPath: path) else {
            return (nil, "\(executableName) 不可执行；跨 App 枚举保持不可用。")
        }
        let result = run(["enumerate-json"], privilege: .isolatedUser, timeout: 5)
        guard result.code == 0 else {
            return (nil, failureDetail(prefix: "\(executableName) 隔离枚举", code: result.code, diagnostic: result.diagnostic))
        }
        let decoder = JSONDecoder()
        if let data = result.diagnostic.data(using: .utf8), let payload = try? decoder.decode(EnumerationPayload.self, from: data) {
            return (payload, "\(payload.backend) 已在 helper 子进程内完成枚举。")
        }
        if let start = result.diagnostic.firstIndex(of: "{"), let end = result.diagnostic.lastIndex(of: "}") {
            let json = String(result.diagnostic[start...end])
            if let data = json.data(using: .utf8), let payload = try? decoder.decode(EnumerationPayload.self, from: data) {
                return (payload, "\(payload.backend) 已在 helper 子进程内完成枚举。")
            }
        }
        return (nil, "\(executableName) 枚举输出无法解析；已按 fail-closed 处理。")
    }

    static func launchCapability() -> RootHelperCapabilitySnapshot {
        let result = run(["probe-launch"], privilege: .isolatedUser, timeout: 4)
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "LaunchServices 启动 selector 已在 helper 子进程内验证。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "helper 启动能力探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func uninstallCapability(bundleID: String) -> RootHelperCapabilitySnapshot {
        let result = run(["probe-uninstall", bundleID], privilege: .root, timeout: 6)
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "卸载 selector/symbol 与权威安装状态查询已在 helper 子进程内验证。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "helper 卸载能力探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func installationState(bundleID: String) -> (installed: Bool?, detail: String) {
        let result = run(["is-installed", bundleID], privilege: .root, timeout: 4)
        switch result.code {
        case 0:
            return (true, "helper 已确认目标 App 处于安装状态。")
        case 47:
            return (false, "helper 已确认目标 App 不在安装状态。")
        default:
            return (nil, failureDetail(prefix: "helper 安装状态查询", code: result.code, diagnostic: result.diagnostic))
        }
    }

    static func launch(bundleID: String) -> (success: Bool, detail: String) {
        let result = run(["launch", bundleID], privilege: .isolatedUser, timeout: 5)
        if result.code == 0 {
            return (true, "隔离 helper 已验证目标安装状态并提交 App 启动请求。")
        }
        return (false, failureDetail(prefix: "隔离 helper 启动 App", code: result.code, diagnostic: result.diagnostic))
    }

    static func probe() -> RootHelperCapabilitySnapshot {
        let path = executablePath
        guard FileManager.default.fileExists(atPath: path) else {
            return RootHelperCapabilitySnapshot(available: false, detail: "\(executableName) 未包含在当前 App Bundle 中。")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return RootHelperCapabilitySnapshot(available: false, detail: "\(executableName) 存在但没有可执行权限。")
        }
        let result = run(["probe"], privilege: .root, timeout: 5)
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "\(executableName) 已通过 persona 99 / UID 0 / GID 0 探测。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "\(executableName) root 探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func uninstall(bundleID: String, bundlePath: String, dataPath: String?) -> (accepted: Bool, detail: String) {
        let capability = probe()
        guard capability.available else { return (false, capability.detail) }
        let result = run(["uninstall", bundleID, bundlePath, dataPath ?? "-"], privilege: .root, timeout: 15)
        if result.code == 0 {
            let detail = result.diagnostic.isEmpty ? "Embedded root helper 已执行受限卸载流程" : "Embedded root helper 已执行受限卸载流程：\(result.diagnostic)"
            return (true, detail)
        }
        return (false, failureDetail(prefix: "Embedded root helper 卸载", code: result.code, diagnostic: result.diagnostic))
    }

    static func terminateCapability() -> RootHelperCapabilitySnapshot {
        let root = probe()
        guard root.available else { return root }
        let result = run(["probe-terminate"], privilege: .root, timeout: 5)
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "Embedded root helper 已验证 root 身份及按进程路径定位能力。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "Embedded root helper 的进程定位后端探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func terminate(bundlePath: String) -> (success: Bool, detail: String) {
        let capability = terminateCapability()
        guard capability.available else { return (false, capability.detail) }
        let result = run(["terminate", bundlePath], privilege: .root, timeout: 6)
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

    public func startupSafeApps() -> [ResourceNode] {
        enumerationProven = false
        enumerationDetail = "自动启动阶段仅加载 Cloud Code 自身；跨 App 私有 API 探测已延后。"
        uninstallDetail = "卸载能力尚未进行显式设备验证。"
        bundlePaths = [:]
        containerPaths = [:]
        cachedApps = fallbackOwnApp()
        lastRefresh = Date()
        return cachedApps
    }

    public func installedApps() async -> [ResourceNode] {
        if !enumerationProven || Date().timeIntervalSince(lastRefresh) > 30 { refresh() }
        return cachedApps
    }

    public func bundlePath(for bundleID: String) async -> String? {
        if bundleID != Bundle.main.bundleIdentifier, bundlePaths[bundleID] == nil {
            refresh()
        } else if Date().timeIntervalSince(lastRefresh) > 30 {
            refresh()
        }
        return bundlePaths[bundleID]
    }

    public func dataContainerPath(for bundleID: String) async -> String? {
        if bundleID != Bundle.main.bundleIdentifier, containerPaths[bundleID] == nil {
            refresh()
        } else if Date().timeIntervalSince(lastRefresh) > 30 {
            refresh()
        }
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
        let snapshot = EmbeddedRootHelper.launchCapability()
        try? await diagnosticLogger?.log(
            level: snapshot.available ? .info : .warning,
            subsystem: "root-helper",
            action: "launch-capability",
            result: snapshot.available ? "available" : "unavailable",
            diagnostic: snapshot.detail
        )
        return AppLifecycleCapabilitySnapshot(available: snapshot.available, detail: snapshot.detail)
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
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else {
            return (false, "目标 Bundle ID 无效，或目标是 Cloud Code 自身。")
        }
        let capability = await appLaunchCapability()
        guard capability.available else {
            return (false, "启动能力不可用：\(capability.detail)")
        }
        let outcome = EmbeddedRootHelper.launch(bundleID: bundleID)
        var metadata = ["bundleID": bundleID]
        if let path = bundlePaths[bundleID] { metadata["bundlePath"] = path }
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "root-helper",
            action: "launch",
            result: outcome.success ? "accepted" : "rejected",
            diagnostic: outcome.detail,
            metadata: metadata
        )
        return outcome
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
            uninstallDetail = "必须先通过 helper 子进程验证跨 App 可见性。"
            return false
        }
        if let pendingBundleID = pendingUninstallBundleID {
            let stillInstalled = cachedApps.contains { $0.ownerBundleID == pendingBundleID }
            pendingUninstallBundleID = nil
            if stillInstalled {
                uninstallDetail = "上一次卸载请求 \(pendingBundleID) 已通过隔离枚举核对：目标仍处于已安装状态；旧 Tool Call 不会重放，新的卸载仍需重新确认。"
            } else {
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
        let isolated = EmbeddedRootHelper.uninstallCapability(bundleID: targetBundleID)
        guard isolated.available else {
            uninstallDetail = "卸载能力的私有 selector/symbol 探测在 helper 子进程中失败：\(isolated.detail)"
            return false
        }
        uninstallDetail = "跨 App 枚举、权威安装状态查询和卸载后端均已在 helper 子进程内验证。实际卸载仍会执行最终状态校验。\(isolated.detail)"
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
        guard await canUninstallInstalledApps() else {
            return .rejected(uninstallDetail)
        }

        let preflight = EmbeddedRootHelper.installationState(bundleID: bundleID)
        guard preflight.installed == true else {
            return .rejected("helper 未能在执行前确认目标仍处于已安装状态：\(preflight.detail)")
        }

        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "app-management",
            action: "uninstall",
            result: "started",
            metadata: ["bundleID": bundleID, "bundlePath": bundlePath]
        )
        let request = EmbeddedRootHelper.uninstall(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath)
        try? await diagnosticLogger?.log(
            level: request.accepted ? .info : .warning,
            subsystem: "root-helper",
            action: "uninstall",
            result: request.accepted ? "accepted" : "rejected",
            diagnostic: request.detail,
            metadata: ["bundleID": bundleID]
        )

        if !request.accepted {
            let reconciliation = reconcileUninstallState(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath)
            switch reconciliation {
            case .removed:
                return .removed
            case .removedWithResidualData(let detail):
                return .removedWithResidualData(detail)
            case .stillInstalled:
                uninstallDetail = "隔离 root helper 未接受卸载，且最终核对确认目标仍处于安装状态：\(request.detail)"
                return .rejected(uninstallDetail)
            case .inconsistent(let detail):
                uninstallDetail = "隔离 root helper 返回失败，最终状态不一致：\(detail)。helper：\(request.detail)"
                pendingUninstallBundleID = bundleID
                return .verificationTimedOut(uninstallDetail)
            }
        }

        pendingUninstallBundleID = bundleID
        uninstallDetail = "卸载已完全委托给隔离 root helper；主 App 仅核对 helper 安装状态与 Bundle/数据容器最终文件系统状态。"
        if await verifyUninstallPostconditions(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath, attempts: 31) {
            finalizeVerifiedUninstall(bundleID: bundleID)
            try? await diagnosticLogger?.log(level: .info, subsystem: "verification", action: "apps.uninstall", result: "passed", diagnostic: uninstallDetail, metadata: ["bundleID": bundleID])
            return .removed
        }

        let reconciliation = reconcileUninstallState(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath)
        switch reconciliation {
        case .removed:
            return .removed
        case .removedWithResidualData(let detail):
            return .removedWithResidualData(detail)
        case .stillInstalled, .inconsistent:
            let timeoutDetail = uninstallDetail + "。目标最终状态仍未满足‘helper 确认未安装 + Bundle 消失 + 已知数据容器消失’，因此不会误报卸载成功。"
            try? await diagnosticLogger?.log(level: .error, subsystem: "verification", action: "apps.uninstall", result: "timed_out", diagnostic: timeoutDetail, metadata: ["bundleID": bundleID])
            return .verificationTimedOut(timeoutDetail)
        }
    }

    private enum UninstallReconciliation {
        case removed
        case removedWithResidualData(String)
        case stillInstalled
        case inconsistent(String)
    }

    private func reconcileUninstallState(bundleID: String, bundlePath: String, dataPath: String?) -> UninstallReconciliation {
        let fileManager = FileManager.default
        let installation = EmbeddedRootHelper.installationState(bundleID: bundleID)
        let bundleExists = fileManager.fileExists(atPath: bundlePath)
        let dataExists = dataPath.map { fileManager.fileExists(atPath: $0) } ?? false

        if installation.installed == false && !bundleExists {
            finalizeVerifiedUninstall(bundleID: bundleID)
            if dataExists {
                let detail = "目标 App 已由 helper 确认未安装且 Bundle 已移除，但已知数据容器仍存在：\(dataPath ?? "未知")。不会把残留数据误报为完整卸载。"
                uninstallDetail = detail
                return .removedWithResidualData(detail)
            }
            return .removed
        }
        if installation.installed == true && bundleExists {
            return .stillInstalled
        }
        return .inconsistent("helper installed=\(installation.installed.map { String(describing: $0) } ?? "unknown"), bundleExists=\(bundleExists), dataExists=\(dataExists), detail=\(installation.detail)")
    }

    private func verifyUninstallPostconditions(bundleID: String, bundlePath: String, dataPath: String?, attempts: Int) async -> Bool {
        let fileManager = FileManager.default
        for attempt in 0..<attempts {
            if Task.isCancelled { return false }
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            let registrationGone = EmbeddedRootHelper.installationState(bundleID: bundleID).installed == false
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
        uninstallDetail = "正在根据本次 helper 隔离探测重新判断卸载后端。"
        bundlePaths = [:]
        containerPaths = [:]

        let isolated = EmbeddedRootHelper.enumerateInstalledApps()
        guard let payload = isolated.payload, !payload.apps.isEmpty else {
            enumerationDetail = isolated.detail
            cachedApps = fallbackOwnApp()
            return
        }

        var appsByBundleID: [String: ResourceNode] = [:]
        var bundles: [String: String] = [:]
        var containers: [String: String] = [:]
        for app in payload.apps where !app.bundleID.isEmpty {
            if !app.bundlePath.isEmpty { bundles[app.bundleID] = app.bundlePath }
            if !app.dataContainerPath.isEmpty { containers[app.bundleID] = app.dataContainerPath }
            appsByBundleID[app.bundleID] = ResourceNode(
                id: ResourceID("app://\(app.bundleID)"),
                kind: .app,
                displayName: app.name.isEmpty ? app.bundleID : app.name,
                logicalLocation: "app://\(app.bundleID)",
                resolvedPath: app.bundlePath.isEmpty ? nil : app.bundlePath,
                ownerBundleID: app.bundleID,
                metadata: ["version": app.version, "containerKnown": app.dataContainerPath.isEmpty ? "false" : "true"]
            )
        }

        let parsedApps = appsByBundleID.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let ownBundleID = Bundle.main.bundleIdentifier
        let crossAppCount = parsedApps.filter { $0.ownerBundleID != nil && $0.ownerBundleID != ownBundleID }.count
        guard crossAppCount > 0 else {
            enumerationDetail = "\(payload.backend) helper 只返回 Cloud Code 自身或无法解析的记录；跨 App 枚举未通过。"
            cachedApps = fallbackOwnApp()
            return
        }

        enumerationProven = true
        enumerationDetail = "\(payload.backend) 已在 helper 子进程内返回 \(parsedApps.count) 个有效应用，其中 \(crossAppCount) 个不是 Cloud Code 自身。"
        cachedApps = parsedApps
        bundlePaths = bundles
        containerPaths = containers
    }

    private static func isUserApplicationBundlePath(_ path: String?) -> Bool {
        guard let normalized = path?.replacingOccurrences(of: "//", with: "/") else { return false }
        return normalized.hasPrefix("/var/containers/Bundle/Application/") || normalized.hasPrefix("/private/var/containers/Bundle/Application/")
    }

    private func fallbackOwnApp() -> [ResourceNode] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        bundlePaths[bundleID] = Bundle.main.bundleURL.path
        containerPaths[bundleID] = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
        return [ResourceNode(id: ResourceID("app://\(bundleID)"), kind: .app, displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Cloud Code", logicalLocation: "app://\(bundleID)", resolvedPath: Bundle.main.bundleURL.path, ownerBundleID: bundleID)]
    }

}

@MainActor
public final class ApprovalCenter: ObservableObject, ApprovalRequesting, @unchecked Sendable {
    @Published public private(set) var pending: ApprovalPreview?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var continuationID: UUID?

    public init() {}

    public func requestApproval(_ preview: ApprovalPreview) async -> Bool {
        if continuation != nil { return false }
        let requestID = UUID()
        pending = preview
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    pending = nil
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                continuationID = requestID
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingApproval(requestID: requestID)
            }
        }
    }

    public func approve() {
        finishPendingApproval(returning: true)
    }

    public func deny() {
        finishPendingApproval(returning: false)
    }

    private func cancelPendingApproval(requestID: UUID) {
        guard continuationID == requestID else { return }
        finishPendingApproval(returning: false)
    }

    private func finishPendingApproval(returning value: Bool) {
        let pendingContinuation = continuation
        continuation = nil
        continuationID = nil
        pending = nil
        pendingContinuation?.resume(returning: value)
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
        case "apps.launch":
            if capabilities.isAvailable("apps.launch") { return true }
            guard capabilities.status("apps.launch") != .unavailable else { return false }
            return await appResolver.appLaunchCapability().available
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
