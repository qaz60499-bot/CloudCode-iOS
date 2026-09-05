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

enum EmbeddedRootHelper {
    struct EnumeratedApp: Decodable {
        var bundleID: String
        var name: String
        var version: String
        var bundlePath: String
        var dataContainerPath: String
        var registered: Bool
    }

    struct EnumerationPayload: Decodable {
        var backend: String
        var apps: [EnumeratedApp]
    }

    struct GUIProbePayload: Decodable {
        var backend: String
        var touch: Bool
        var gestures: Bool
        var textInput: Bool
        var screenshot: Bool
        var tree: Bool
        var verify: Bool
        var screenWidth: Double
        var screenHeight: Double
    }

    struct FilesystemProbePayload: Decodable {
        var sharedUserFiles: Bool
        var unrestricted: Bool
        var detail: String
    }

    static let executableName = "CloudCodeRootHelper"
    static let expectedProtocolMarker = "cloudcode-root-helper-protocol=1"

    static var executablePath: String {
        Bundle.main.bundleURL.appendingPathComponent(executableName, isDirectory: false).path
    }

    private static let embeddedHelperMatchesExpectedProtocol: Bool = {
        guard let markerData = expectedProtocolMarker.data(using: .utf8),
              let helperData = try? Data(contentsOf: URL(fileURLWithPath: executablePath), options: [.mappedIfSafe]) else {
            return false
        }
        return helperData.range(of: markerData) != nil
    }()

    private enum PrivilegeMode {
        case isolatedUser
        case root
    }

    private static func run(_ arguments: [String], privilege: PrivilegeMode, timeout: TimeInterval = 6) -> (code: Int, diagnostic: String) {
        guard embeddedHelperMatchesExpectedProtocol else {
            return (69, "内嵌 CloudCodeRootHelper 与当前 App 协议不匹配；拒绝执行，避免误用旧 helper。")
        }
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
        case 48: meaning = "卸载后端存在，但 Bundle 容器读写兜底能力未验证"
        case 49: meaning = "残留清理被拒绝：目标仍处于已注册安装状态"
        case 61: meaning = "GUI readiness JSON 无法生成"
        case 62: meaning = "AXRuntime 前台 UI tree 当前不可用"
        case 63: meaning = "全局截图后端当前不可用或输出超限"
        case 64: meaning = "GUI 坐标/滚动参数越界或无效"
        case 65: meaning = "IOHID tap 注入失败"
        case 66: meaning = "IOHID swipe/scroll 注入失败"
        case 67: meaning = "文本输入参数无效或超出限制"
        case 68: meaning = "IOHID Unicode 文本输入后端不可用"
        case 69: meaning = "内嵌 root helper 协议/构建指纹不匹配"
        case 73: meaning = "后台 assertion 目标进程不存在或无效"
        case 74: meaning = "后台 assertion worker 创建失败"
        case 75: meaning = "AssertionServices 拒绝或未建立后台保活 assertion"
        case 76: meaning = "后台 assertion worker 停止失败"
        case 77: meaning = "后台 assertion worker 已退出"
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
            return RootHelperCapabilitySnapshot(available: true, detail: "卸载后端、权威安装状态查询及必要的 Bundle 容器兜底访问已在 helper 子进程内验证。")
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
        if result.code == 0, result.diagnostic == expectedProtocolMarker {
            return RootHelperCapabilitySnapshot(available: true, detail: "\(executableName) 已通过 persona 99 / UID 0 / GID 0 及 helper 协议指纹探测。")
        }
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: false, detail: "\(executableName) root 探测返回了非预期协议指纹；拒绝使用可能过期的 helper。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "\(executableName) root 探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func filesystemCapability() -> PrivilegedFilesystemCapabilitySnapshot {
        let result = run(["probe-filesystem-json"], privilege: .root, timeout: 5)
        guard result.code == 0 else {
            return PrivilegedFilesystemCapabilitySnapshot(
                sharedUserFilesAvailable: false,
                unrestrictedAvailable: false,
                detail: failureDetail(prefix: "helper 高权限文件系统探测", code: result.code, diagnostic: result.diagnostic)
            )
        }
        let decoder = JSONDecoder()
        var payload: FilesystemProbePayload?
        if let data = result.diagnostic.data(using: .utf8) {
            payload = try? decoder.decode(FilesystemProbePayload.self, from: data)
        }
        if payload == nil, let start = result.diagnostic.firstIndex(of: "{"), let end = result.diagnostic.lastIndex(of: "}") {
            let json = String(result.diagnostic[start...end])
            if let data = json.data(using: .utf8) {
                payload = try? decoder.decode(FilesystemProbePayload.self, from: data)
            }
        }
        guard let payload else {
            return PrivilegedFilesystemCapabilitySnapshot(
                sharedUserFilesAvailable: false,
                unrestrictedAvailable: false,
                detail: "helper 高权限文件系统探测输出无法解析；已按 fail-closed 处理。"
            )
        }
        return PrivilegedFilesystemCapabilitySnapshot(
            sharedUserFilesAvailable: payload.sharedUserFiles,
            unrestrictedAvailable: payload.unrestricted,
            detail: payload.detail
        )
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

    static func cleanupUnregistered(bundleID: String, bundlePath: String, dataPath: String?) -> (accepted: Bool, detail: String) {
        let capability = probe()
        guard capability.available else { return (false, capability.detail) }
        let result = run(["cleanup-unregistered", bundleID, bundlePath, dataPath ?? "-"], privilege: .root, timeout: 15)
        if result.code == 0 {
            return (true, result.diagnostic.isEmpty ? "Embedded root helper 已清理未注册的残留 App Bundle。" : "Embedded root helper 已清理未注册残留：\(result.diagnostic)")
        }
        return (false, failureDetail(prefix: "Embedded root helper 残留清理", code: result.code, diagnostic: result.diagnostic))
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

    private static func decodeGUIProbe(_ diagnostic: String) -> GUIProbePayload? {
        let decoder = JSONDecoder()
        if let data = diagnostic.data(using: .utf8), let payload = try? decoder.decode(GUIProbePayload.self, from: data) {
            return payload
        }
        guard let start = diagnostic.firstIndex(of: "{"), let end = diagnostic.lastIndex(of: "}") else { return nil }
        let json = String(diagnostic[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(GUIProbePayload.self, from: data)
    }

    static func guiProbe() -> (payload: GUIProbePayload?, detail: String) {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return (nil, "\(executableName) 不可执行；GUI backend 保持不可用。")
        }
        let result = run(["gui-probe-json"], privilege: .root, timeout: 6)
        guard result.code == 0, let payload = decodeGUIProbe(result.diagnostic) else {
            return (nil, failureDetail(prefix: "隔离 GUI readiness 探测", code: result.code, diagnostic: result.diagnostic))
        }
        return (payload, "\(payload.backend) 已在受限 root helper 内完成只读 readiness handshake。")
    }

    static func guiTree() -> (tree: String?, detail: String) {
        let result = run(["gui-tree-json"], privilege: .root, timeout: 5)
        guard result.code == 0, !result.diagnostic.isEmpty else {
            return (nil, failureDetail(prefix: "GUI tree", code: result.code, diagnostic: result.diagnostic))
        }
        guard result.diagnostic.utf8.count <= 256 * 1024 else {
            return (nil, "GUI tree 输出超过 256 KiB 限制，已 fail closed。")
        }
        return (result.diagnostic, "AXRuntime tree 已返回。")
    }

    static func guiScreenshot() -> (data: Data?, detail: String) {
        let result = run(["gui-screenshot-base64"], privilege: .root, timeout: 6)
        guard result.code == 0,
              let encoded = result.diagnostic.data(using: .utf8),
              let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              !data.isEmpty,
              data.count <= 700 * 1024 else {
            return (nil, failureDetail(prefix: "GUI screenshot", code: result.code, diagnostic: result.code == 0 ? "截图输出无法解码或超过 700 KiB" : result.diagnostic))
        }
        return (data, "全局截图已由隔离 helper 返回。")
    }

    static func guiTap(x: Double, y: Double) -> (success: Bool, detail: String) {
        let result = run(["gui-tap", String(x), String(y)], privilege: .root, timeout: 3)
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "IOHID tap 已提交。" : "IOHID tap 已提交：\(result.diagnostic)")
            : (false, failureDetail(prefix: "GUI tap", code: result.code, diagnostic: result.diagnostic))
    }

    static func guiSwipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double) -> (success: Bool, detail: String) {
        let result = run(["gui-swipe", String(fromX), String(fromY), String(toX), String(toY), String(duration)], privilege: .root, timeout: min(max(duration + 2.0, 3.0), 7.0))
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "IOHID swipe 已提交。" : "IOHID swipe 已提交：\(result.diagnostic)")
            : (false, failureDetail(prefix: "GUI swipe", code: result.code, diagnostic: result.diagnostic))
    }

    static func guiScroll(deltaX: Double, deltaY: Double) -> (success: Bool, detail: String) {
        let result = run(["gui-scroll", String(deltaX), String(deltaY)], privilege: .root, timeout: 4)
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "IOHID scroll gesture 已提交。" : "IOHID scroll gesture 已提交：\(result.diagnostic)")
            : (false, failureDetail(prefix: "GUI scroll", code: result.code, diagnostic: result.diagnostic))
    }

    static func guiType(_ text: String) -> (success: Bool, detail: String) {
        guard !text.isEmpty, let utf8 = text.data(using: .utf8), utf8.count <= 16 * 1024 else {
            return (false, "GUI 文本输入为空或超过 16 KiB 限制。")
        }
        let encoded = utf8.base64EncodedString()
        let result = run(["gui-type-base64", encoded], privilege: .root, timeout: 6)
        return result.code == 0
            ? (true, "IOHID Unicode 文本输入已提交；输入内容未写入 helper 诊断输出。")
            : (false, failureDetail(prefix: "GUI type", code: result.code, diagnostic: result.diagnostic))
    }

    static func startBackgroundAssertion(targetPID: Int32) -> (workerPID: Int32?, detail: String) {
        guard targetPID > 1 else { return (nil, "后台 assertion 目标 PID 无效。") }
        let result = run(["background-assert-start", String(targetPID)], privilege: .root, timeout: 4)
        guard result.code == 0 else {
            return (nil, failureDetail(prefix: "后台 assertion worker", code: result.code, diagnostic: result.diagnostic))
        }
        let marker = "workerPID="
        guard let range = result.diagnostic.range(of: marker) else {
            return (nil, "后台 assertion worker 已返回成功，但没有提供 worker PID；按 fail-closed 处理。")
        }
        let suffix = result.diagnostic[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        guard let workerPID = Int32(digits), workerPID > 1 else {
            return (nil, "后台 assertion worker PID 无法解析；按 fail-closed 处理。")
        }
        return (workerPID, result.diagnostic)
    }

    static func backgroundAssertionIsAlive(workerPID: Int32) -> Bool {
        guard workerPID > 1 else { return false }
        return run(["background-assert-status", String(workerPID)], privilege: .root, timeout: 2).code == 0
    }

    static func stopBackgroundAssertion(workerPID: Int32) -> (success: Bool, detail: String) {
        guard workerPID > 1 else { return (true, "没有需要停止的后台 assertion worker。") }
        let result = run(["background-assert-stop", String(workerPID)], privilege: .root, timeout: 3)
        return result.code == 0
            ? (true, "后台 assertion worker 已停止。")
            : (false, failureDetail(prefix: "停止后台 assertion worker", code: result.code, diagnostic: result.diagnostic))
    }
}

public actor IOSAppResolver: AppContainerResolving, AppEnumerationCapabilityProviding, AppUninstallCapabilityProviding, RootHelperCapabilityProviding, PrivilegedFilesystemCapabilityProviding, AppLifecycleCapabilityProviding {
    private var cachedApps: [ResourceNode] = []
    private var bundlePaths: [String: String] = [:]
    private var containerPaths: [String: String] = [:]
    private var appIndexNeedsRefresh = true
    private var failedIndexRetryAfter: Date?
    private var negativeBundleIDs: Set<String> = []
    private var unregisteredBundleIDs: Set<String> = []
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
        appIndexNeedsRefresh = true
        failedIndexRetryAfter = nil
        negativeBundleIDs.removeAll()
        unregisteredBundleIDs.removeAll()
        return cachedApps
    }

    public func installedApps() async -> [ResourceNode] {
        // Installed-app discovery is relatively expensive on TrollStore devices and the result is
        // effectively an index. Do not rescan on a wall-clock TTL: a model that calls apps.list in
        // several tool rounds would otherwise enumerate hundreds of apps over and over. Refresh only
        // on the first cross-app read, an explicit invalidation, or after a bounded retry delay when
        // the previous helper enumeration failed.
        if shouldRefreshIndex() { refresh() }
        return cachedApps
    }

    public func bundlePath(for bundleID: String) async -> String? {
        if bundleID == Bundle.main.bundleIdentifier { return bundlePaths[bundleID] ?? Bundle.main.bundleURL.path }
        if shouldRefreshIndex() { refresh() }
        if let value = bundlePaths[bundleID] { return value }
        guard enumerationProven, !negativeBundleIDs.contains(bundleID) else { return nil }
        // A cache miss can mean a newly installed App. Permit one refresh for that bundle ID, then
        // remember a negative lookup so a stale/invalid ID cannot trigger a full 385-App scan forever.
        refresh()
        if let value = bundlePaths[bundleID] { return value }
        negativeBundleIDs.insert(bundleID)
        return nil
    }

    public func dataContainerPath(for bundleID: String) async -> String? {
        if bundleID == Bundle.main.bundleIdentifier { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path }
        if shouldRefreshIndex() { refresh() }
        if let value = containerPaths[bundleID] { return value }
        // If the bundle itself is already in the index, an absent container path is a known value,
        // not evidence that the whole App index is stale.
        if bundlePaths[bundleID] != nil { return nil }
        guard enumerationProven, !negativeBundleIDs.contains(bundleID) else { return nil }
        refresh()
        if let value = containerPaths[bundleID] { return value }
        if bundlePaths[bundleID] == nil { negativeBundleIDs.insert(bundleID) }
        return nil
    }

    public func canEnumerateInstalledApps() async -> Bool {
        if shouldRefreshIndex() { refresh() }
        return enumerationProven
    }

    public func installedAppEnumerationDetail() async -> String {
        if shouldRefreshIndex() { refresh() }
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

    public func privilegedFilesystemCapability() async -> PrivilegedFilesystemCapabilitySnapshot {
        let snapshot = EmbeddedRootHelper.filesystemCapability()
        try? await diagnosticLogger?.log(
            level: snapshot.unrestrictedAvailable ? .info : .warning,
            subsystem: "root-helper",
            action: "filesystem-capability",
            result: snapshot.unrestrictedAvailable ? "available" : "partial_or_unavailable",
            diagnostic: snapshot.detail,
            metadata: [
                "sharedUserFiles": String(snapshot.sharedUserFilesAvailable),
                "unrestricted": String(snapshot.unrestrictedAvailable)
            ]
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
        if shouldRefreshIndex() { refresh() }
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
        if shouldRefreshIndex() { refresh() }
        guard enumerationProven else {
            uninstallDetail = "必须先通过 helper 子进程验证跨 App 可见性。"
            return false
        }
        if let pendingBundleID = pendingUninstallBundleID {
            if unregisteredBundleIDs.contains(pendingBundleID), bundlePaths[pendingBundleID] != nil {
                uninstallDetail = "上一次卸载请求 \(pendingBundleID) 已由 LaunchServices 注销，但 Bundle 仍在磁盘；路径已保留为待清理残留。旧 Tool Call 不会重放，新的卸载仍需重新确认。"
            } else if cachedApps.contains(where: { $0.ownerBundleID == pendingBundleID }) {
                pendingUninstallBundleID = nil
                uninstallDetail = "上一次卸载请求 \(pendingBundleID) 已通过隔离枚举核对：目标仍处于已注册安装状态；旧 Tool Call 不会重放，新的卸载仍需重新确认。"
            } else {
                pendingUninstallBundleID = nil
                bundlePaths.removeValue(forKey: pendingBundleID)
                containerPaths.removeValue(forKey: pendingBundleID)
            }
        }
        guard let target = cachedApps.first(where: {
            guard let bundleID = $0.ownerBundleID, bundleID != Bundle.main.bundleIdentifier else { return false }
            guard !unregisteredBundleIDs.contains(bundleID) else { return false }
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
        if shouldRefreshIndex() { refresh() }
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

        // A previous system uninstall can remove the LaunchServices registration before the
        // physical bundle/data containers are gone. The helper enumerator marks those filesystem
        // orphans explicitly; a new approved uninstall request may reconcile only that known path,
        // and the root helper refuses this cleanup if the bundle becomes registered again.
        if unregisteredBundleIDs.contains(bundleID) {
            let cleanup = EmbeddedRootHelper.cleanupUnregistered(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath)
            try? await diagnosticLogger?.log(
                level: cleanup.accepted ? .info : .warning,
                subsystem: "root-helper",
                action: "cleanup-unregistered",
                result: cleanup.accepted ? "accepted" : "rejected",
                diagnostic: cleanup.detail,
                metadata: ["bundleID": bundleID, "bundlePath": bundlePath]
            )
            let reconciliation = reconcileUninstallState(bundleID: bundleID, bundlePath: bundlePath, dataPath: dataPath)
            switch reconciliation {
            case .removed:
                return .removed
            case .removedWithResidualData(let detail):
                return .removedWithResidualData(detail)
            case .stillInstalled:
                return .rejected("残留清理前后发现目标重新处于已安装状态；已停止清理。\(cleanup.detail)")
            case .inconsistent(let detail):
                pendingUninstallBundleID = bundleID
                uninstallDetail = "未注册残留清理后状态仍不一致：\(detail)。helper：\(cleanup.detail)"
                return .verificationTimedOut(uninstallDetail)
            }
        }

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
        appIndexNeedsRefresh = false
        negativeBundleIDs.insert(bundleID)
        uninstallDetail = "最近一次卸载已通过三项最终校验：LaunchServices 未安装、Bundle 已移除、已知数据容器已移除。"
    }

    public func forceRefresh() {
        appIndexNeedsRefresh = true
        failedIndexRetryAfter = nil
        negativeBundleIDs.removeAll()
        refresh()
    }

    private func shouldRefreshIndex(now: Date = Date()) -> Bool {
        if appIndexNeedsRefresh { return true }
        if enumerationProven { return false }
        guard let failedIndexRetryAfter else { return true }
        return now >= failedIndexRetryAfter
    }

    private func refresh() {
        defer { appIndexNeedsRefresh = false }

        enumerationProven = false
        enumerationDetail = "已安装 App 枚举尚未得到跨 App 可见性的有效证据。"
        uninstallDetail = "正在根据本次 helper 隔离探测重新判断卸载后端。"
        bundlePaths = [:]
        containerPaths = [:]
        unregisteredBundleIDs.removeAll()

        let isolated = EmbeddedRootHelper.enumerateInstalledApps()
        guard let payload = isolated.payload, !payload.apps.isEmpty else {
            enumerationDetail = isolated.detail + " 失败结果会缓存 30 秒，避免模型循环触发全量枚举。"
            cachedApps = fallbackOwnApp()
            failedIndexRetryAfter = Date().addingTimeInterval(30)
            return
        }

        var appsByBundleID: [String: ResourceNode] = [:]
        var bundles: [String: String] = [:]
        var containers: [String: String] = [:]
        var unregistered: Set<String> = []
        for app in payload.apps where !app.bundleID.isEmpty {
            if !app.bundlePath.isEmpty { bundles[app.bundleID] = app.bundlePath }
            if !app.dataContainerPath.isEmpty { containers[app.bundleID] = app.dataContainerPath }
            if !app.registered { unregistered.insert(app.bundleID) }
            appsByBundleID[app.bundleID] = ResourceNode(
                id: ResourceID("app://\(app.bundleID)"),
                kind: .app,
                displayName: app.name.isEmpty ? app.bundleID : app.name,
                logicalLocation: "app://\(app.bundleID)",
                resolvedPath: app.bundlePath.isEmpty ? nil : app.bundlePath,
                ownerBundleID: app.bundleID,
                metadata: [
                    "version": app.version,
                    "containerKnown": app.dataContainerPath.isEmpty ? "false" : "true",
                    "registration": app.registered ? "registered" : "filesystem-orphan"
                ]
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
        failedIndexRetryAfter = nil
        negativeBundleIDs.removeAll()
        enumerationDetail = "\(payload.backend) 已在 helper 子进程内返回 \(parsedApps.count) 个有效应用，其中 \(crossAppCount) 个不是 Cloud Code 自身；后续沿用内存索引直到显式失效。"
        cachedApps = parsedApps
        bundlePaths = bundles
        containerPaths = containers
        unregisteredBundleIDs = unregistered
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

public struct IOSPrivateAppExecutor: DeferredCapabilitySelfValidatingToolExecutor, Sendable {
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

    public func allowsDeferredCapabilityAttempt(
        _ capabilityIDs: [String],
        for tool: ToolDescriptor,
        capabilities: CapabilityProfile
    ) async -> Bool {
        guard capabilityIDs.count == 1, let capabilityID = capabilityIDs.first,
              capabilities.status(capabilityID) == .deviceValidationRequired else { return false }
        switch tool.name {
        case "apps.terminate": return capabilityID == "apps.terminate"
        case "apps.uninstall": return capabilityID == "apps.uninstall"
        default: return false
        }
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        switch tool.name {
        case "apps.launch":
            if capabilities.isAvailable("apps.launch") { return true }
            guard capabilities.status("apps.launch") != .unavailable else { return false }
            return await appResolver.appLaunchCapability().available
        case "apps.terminate":
            let status = capabilities.status("apps.terminate")
            return status == .available || status == .deviceValidationRequired
        case "apps.uninstall":
            let status = capabilities.status("apps.uninstall")
            return status == .available || status == .deviceValidationRequired
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

public struct GUIFallbackExecutor: DeferredCapabilitySelfValidatingToolExecutor, Sendable {
    public let route: AppExecutionRoute = .guiFallback
    private let backend: GUIAutomationBackend
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting
    private let attachmentRoot: URL?

    public init(
        backend: GUIAutomationBackend,
        policy: PolicyEngine,
        approval: ApprovalRequesting,
        attachmentRoot: URL? = nil
    ) {
        self.backend = backend
        self.policy = policy
        self.approval = approval
        self.attachmentRoot = attachmentRoot
    }

    public func allowsDeferredCapabilityAttempt(
        _ capabilityIDs: [String],
        for tool: ToolDescriptor,
        capabilities: CapabilityProfile
    ) async -> Bool {
        guard let feature = Self.feature(for: tool.name),
              capabilityIDs == [feature.capabilityID],
              capabilities.status(feature.capabilityID) == .deviceValidationRequired else { return false }
        // Route selection stays side-effect free. The exact requested GUI operation below runs
        // in the bounded helper and is itself the runtime proof; helper failures remain fail-closed.
        return true
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        guard let feature = Self.feature(for: tool.name) else { return false }
        let status = capabilities.status(feature.capabilityID)
        return status == .available || status == .deviceValidationRequired
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        switch call.name {
        case "gui.openApp":
            guard let bundle = call.arguments["bundleId"], Self.isValidBundleIdentifier(bundle) else {
                throw ToolRouterError.noExecutionRoute("bundleId missing or invalid")
            }
        case "gui.tree", "gui.screenshot":
            break
        case "gui.tap":
            guard let x = Double(call.arguments["x"] ?? ""), let y = Double(call.arguments["y"] ?? ""),
                  x.isFinite, y.isFinite, x >= 0, y >= 0, x <= 10_000, y <= 10_000 else {
                throw ToolRouterError.noExecutionRoute("tap coordinates missing, non-finite, negative, or outside bounded range")
            }
        case "gui.type":
            guard let text = call.arguments["text"], !text.isEmpty,
                  (text.data(using: .utf8)?.count ?? Int.max) <= 16 * 1024 else {
                throw ToolRouterError.noExecutionRoute("text missing, empty, or exceeds 16 KiB")
            }
        case "gui.scroll":
            guard let dx = Double(call.arguments["dx"] ?? ""), let dy = Double(call.arguments["dy"] ?? ""),
                  dx.isFinite, dy.isFinite, abs(dx) <= 10_000, abs(dy) <= 10_000,
                  abs(dx) >= 0.5 || abs(dy) >= 0.5 else {
                throw ToolRouterError.noExecutionRoute("scroll delta missing, invalid, zero, or outside bounded range")
            }
        case "gui.swipe":
            let keys = ["fromX", "fromY", "toX", "toY"]
            let coordinates = keys.compactMap { Double(call.arguments[$0] ?? "") }
            let duration = Double(call.arguments["duration"] ?? "0.3")
            guard coordinates.count == keys.count, coordinates.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000 }),
                  let duration, duration.isFinite, duration >= 0.05, duration <= 5.0 else {
                throw ToolRouterError.noExecutionRoute("swipe coordinates/duration missing, invalid, or outside bounded range")
            }
        case "gui.verify":
            guard let assertion = call.arguments["assertion"], !assertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  assertion.utf8.count <= 1_024 else {
                throw ToolRouterError.noExecutionRoute("assertion missing, empty, or too large")
            }
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
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Screenshot captured",
                payload: ["byteCount": String(data.count)],
                attachments: attachment.map { [$0] }
            )
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

    private func persistScreenshotAttachment(_ data: Data, sessionID: UUID) throws -> ChatAttachment? {
        guard let attachmentRoot else { return nil }
        guard !data.isEmpty, data.count <= ChatMessageAttachmentPolicy.maxImageBytes else {
            throw ToolRouterError.noExecutionRoute("GUI screenshot is empty or exceeds the provider image limit")
        }
        let sessionRoot = attachmentRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let filename = "gui-screenshot-\(UUID().uuidString).jpg"
        let target = sessionRoot.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: target, options: .atomic)
        return ChatAttachment(
            filename: "gui-screenshot.jpg",
            path: target.path,
            mimeType: "image/jpeg",
            byteSize: Int64(data.count)
        )
    }

    private static func feature(for toolName: String) -> GUIAutomationFeature? {
        switch toolName {
        case "gui.openApp": return .openApp
        case "gui.tree": return .tree
        case "gui.screenshot": return .screenshot
        case "gui.tap": return .touch
        case "gui.type": return .textInput
        case "gui.scroll", "gui.swipe": return .gestures
        case "gui.verify": return .verify
        default: return nil
        }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
