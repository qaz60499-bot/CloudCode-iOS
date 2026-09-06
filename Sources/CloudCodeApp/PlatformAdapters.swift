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

    private static func runSeparated(_ arguments: [String], privilege: PrivilegeMode, timeout: TimeInterval = 6) -> (code: Int, stdout: String, stderr: String) {
        guard embeddedHelperMatchesExpectedProtocol else {
            return (69, "", "内嵌 CloudCodeRootHelper 与当前 App 协议不匹配；拒绝执行，避免误用旧 helper。")
        }
        var standardOutput: NSString?
        var standardError: NSString?
        let code = CloudCodeSpawnHelperWithSeparatedOutput(
            executablePath,
            arguments,
            privilege == .root,
            timeout,
            &standardOutput,
            &standardError
        )
        return (
            code,
            (standardOutput as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            (standardError as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
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
        case 46: meaning = "系统 App 启动路由未能将目标 App 置于前台"
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
        case 70: meaning = "文本输入事件已派发，但可读的聚焦输入框内容没有变化"
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
        let isolated = run(["launch", bundleID], privilege: .isolatedUser, timeout: 5)
        if isolated.code == 0 {
            let route = isolated.diagnostic.isEmpty ? "" : " \(isolated.diagnostic)"
            return (true, "隔离 helper 已验证目标安装状态并完成 App 启动路径。\(route)")
        }

        // Some third-party apps reject LSApplicationWorkspace activation from the isolated mobile
        // persona even though the exact same helper is privileged and device-validated. Retry only
        // the same bounded launch operation under the signed root helper; never broaden this into a
        // generic shell or arbitrary private-API executor.
        if isolated.code == 46 {
            let privileged = run(["launch", bundleID], privilege: .root, timeout: 6)
            if privileged.code == 0 {
                let route = privileged.diagnostic.isEmpty ? "" : " \(privileged.diagnostic)"
                return (true, "隔离 LaunchServices 路径被拒绝后，root helper 通过系统启动路由完成目标 App 前台切换。\(route)")
            }
            let isolatedDetail = failureDetail(prefix: "隔离 helper 启动 App", code: isolated.code, diagnostic: isolated.diagnostic)
            let privilegedDetail = failureDetail(prefix: "root helper 启动 App", code: privileged.code, diagnostic: privileged.diagnostic)
            return (false, "\(isolatedDetail)；root fallback 同样失败：\(privilegedDetail)")
        }

        return (false, failureDetail(prefix: "隔离 helper 启动 App", code: isolated.code, diagnostic: isolated.diagnostic))
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
        let result = runSeparated(["gui-probe-json"], privilege: .root, timeout: 6)
        guard result.code == 0, let payload = decodeGUIProbe(result.stdout) else {
            let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
            return (nil, failureDetail(prefix: "隔离 GUI readiness 探测", code: result.code, diagnostic: diagnostic))
        }
        let diagnosticSuffix = result.stderr.isEmpty ? "" : " helper diagnostics: \(result.stderr)"
        return (payload, "\(payload.backend) 已在受限 root helper 内完成只读 readiness handshake。\(diagnosticSuffix)")
    }

    static func guiTree() -> (tree: String?, detail: String) {
        // Structured UI is the preferred fast path, but an inaccessible/custom-rendered foreground
        // must fail quickly so the router can fall back to screenshot/Vision rather than burning a
        // provider-scale latency budget inside AX. The helper also applies sub-second AX request
        // timeouts per candidate root; this outer deadline bounds the whole fallback chain.
        let result = runSeparated(["gui-tree-json"], privilege: .root, timeout: 3)
        guard result.code == 0, !result.stdout.isEmpty else {
            let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
            return (nil, failureDetail(prefix: "GUI tree", code: result.code, diagnostic: diagnostic))
        }
        guard result.stdout.utf8.count <= 256 * 1024 else {
            return (nil, "GUI tree 输出超过 256 KiB 限制，已 fail closed。")
        }
        let diagnosticSuffix = result.stderr.isEmpty ? "" : " helper diagnostics: \(result.stderr)"
        return (result.stdout, "AXRuntime tree 已返回。\(diagnosticSuffix)")
    }

    static func guiScreenshot() -> (data: Data?, detail: String) {
        // Screenshot bytes must not share the helper diagnostic pipe. The bridge intentionally
        // merges stdout/stderr for ordinary text commands, and a successful fallback screenshot
        // can therefore be preceded by stderr from an earlier failed capture backend. Passing
        // JPEG bytes through a bounded file in this app's own tmp directory keeps diagnostics and
        // payload physically separate and also avoids the 1 MiB textual capture ceiling.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCode-GUI-\(UUID().uuidString).jpg", isDirectory: false)
        // Pre-create the destination as the app user. The privileged helper must overwrite this
        // inode in-place rather than atomically replacing it with a root-owned file, otherwise the
        // sandboxed app may be unable to read the returned JPEG even though capture succeeded.
        guard FileManager.default.createFile(atPath: outputURL.path, contents: Data()) else {
            return (nil, "GUI screenshot 无法在 App tmp 中创建受控输出文件。")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let result = run(["gui-screenshot-file", outputURL.path], privilege: .root, timeout: 6)
        guard result.code == 0 else {
            return (nil, failureDetail(prefix: "GUI screenshot", code: result.code, diagnostic: result.diagnostic))
        }
        guard let data = try? Data(contentsOf: outputURL, options: [.mappedIfSafe]),
              GUIAutomationPayloadPolicy.isValidScreenshotJPEG(data) else {
            return (nil, "GUI screenshot helper 返回成功，但 tmp 文件不是有效的 bounded JPEG；已按 fail-closed 处理。")
        }
        let routeDetail = result.diagnostic.isEmpty ? "" : " helper diagnostics: \(result.diagnostic)"
        return (data, "全局截图已通过独立 tmp JPEG 通道返回。\(routeDetail)")
    }

    static func guiTap(x: Double, y: Double) -> (success: Bool, detail: String) {
        let result = run(["gui-tap", String(x), String(y)], privilege: .root, timeout: 3)
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "IOHID tap 已派发，但尚未验证前台 UI 是否实际变化。" : "IOHID tap 已派发（结果未验证）：\(result.diagnostic)")
            : (false, failureDetail(prefix: "GUI tap", code: result.code, diagnostic: result.diagnostic))
    }

    static func guiSwipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double) -> (success: Bool, detail: String) {
        let result = run(["gui-swipe", String(fromX), String(fromY), String(toX), String(toY), String(duration)], privilege: .root, timeout: min(max(duration + 2.0, 3.0), 7.0))
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "IOHID swipe 已派发，但尚未验证前台 UI 是否实际变化。" : "IOHID swipe 已派发（结果未验证）：\(result.diagnostic)")
            : (false, failureDetail(prefix: "GUI swipe", code: result.code, diagnostic: result.diagnostic))
    }

    static func guiScroll(deltaX: Double, deltaY: Double) -> (success: Bool, detail: String) {
        let result = run(["gui-scroll", String(deltaX), String(deltaY)], privilege: .root, timeout: 4)
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "IOHID scroll gesture 已派发，但尚未验证前台 UI 是否实际变化。" : "IOHID scroll gesture 已派发（结果未验证）：\(result.diagnostic)")
            : (false, failureDetail(prefix: "GUI scroll", code: result.code, diagnostic: result.diagnostic))
    }

    static func guiNavigateBack(strategy: String) -> (success: Bool, detail: String) {
        guard strategy == "edge" || strategy == "dismissDown" else {
            return (false, "GUI navigate back strategy 必须是 edge 或 dismissDown。")
        }
        let result = run(["gui-navigate-back", strategy], privilege: .root, timeout: 4)
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "iOS 返回/关闭手势已派发；语义结果等待最终截图确认。" : "iOS 返回/关闭手势已派发：\(result.diagnostic)")
            : (false, failureDetail(prefix: "GUI navigate back", code: result.code, diagnostic: result.diagnostic))
    }

    static func guiType(_ text: String) -> (success: Bool, detail: String) {
        guard !text.isEmpty, let utf8 = text.data(using: .utf8), utf8.count <= 16 * 1024 else {
            return (false, "GUI 文本输入为空或超过 16 KiB 限制。")
        }
        let encoded = utf8.base64EncodedString()
        let result = run(["gui-type-base64", encoded], privilege: .root, timeout: 6)
        return result.code == 0
            ? (true, result.diagnostic.isEmpty ? "文本输入已通过受控 AX/HID 路径提交；输入内容未写入 helper 诊断输出。" : "文本输入已提交；输入内容未写入日志。\(result.diagnostic)")
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
    private var cachedLaunchCapability: AppLifecycleCapabilitySnapshot?
    private let diagnosticLogger: DiagnosticLogStore?

    public init(diagnosticLogger: DiagnosticLogStore? = nil) {
        self.diagnosticLogger = diagnosticLogger
    }

    public func startupSafeApps() -> [ResourceNode] {
        enumerationProven = false
        enumerationDetail = "自动启动阶段仅加载 Cloud Code 自身；跨 App 私有 API 探测已延后。"
        uninstallDetail = "卸载能力尚未进行显式设备验证。"
        cachedLaunchCapability = nil
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

    public func cachedVersion(for bundleID: String) -> String? {
        cachedApps.first(where: { $0.ownerBundleID == bundleID })?.metadata["version"]
    }

    public func cachedDisplayName(for bundleID: String) -> String? {
        cachedApps.first(where: { $0.ownerBundleID == bundleID })?.displayName
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
        if let cachedLaunchCapability, cachedLaunchCapability.available {
            return cachedLaunchCapability
        }
        let snapshot = EmbeddedRootHelper.launchCapability()
        let lifecycle = AppLifecycleCapabilitySnapshot(available: snapshot.available, detail: snapshot.detail)
        if lifecycle.available { cachedLaunchCapability = lifecycle }
        try? await diagnosticLogger?.log(
            level: snapshot.available ? .info : .warning,
            subsystem: "root-helper",
            action: "launch-capability",
            result: snapshot.available ? "available" : "unavailable",
            diagnostic: snapshot.detail
        )
        return lifecycle
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
                    plan: ["确认目标 Bundle ID", "调用有界系统启动路由", "验证目标 Bundle ID 已成为前台 App"],
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
            let version = await appResolver.cachedVersion(for: bundleID) ?? ""
            return ToolResult(
                toolCallID: call.id,
                success: outcome.success,
                summary: outcome.success ? "已请求启动 \(bundleID)" : "启动失败：\(outcome.detail)",
                payload: ["bundleId": bundleID, "detail": outcome.detail, "version": version],
                verification: VerificationResult(passed: outcome.success, checks: ["目标 App 已由有界系统启动路由确认进入前台"], failures: outcome.success ? [] : [outcome.detail])
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
        let displayName = await appResolver.cachedDisplayName(for: bundleID)
        guard ExplicitUserIntentGate.allowsAppUninstall(
            request: context.currentUserRequest,
            bundleID: bundleID,
            displayName: displayName
        ) else {
            try? await audit.append(AuditEvent(
                sessionID: call.sessionID,
                toolCallID: call.id,
                action: call.name,
                target: bundleID,
                risk: descriptor.risk,
                result: "request_rejected_missing_explicit_user_intent",
                detail: ["displayName": displayName ?? ""]
            ))
            throw ToolRouterError.noExecutionRoute("apps.uninstall requires explicit current-user uninstall intent naming the target app or Bundle ID")
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

private struct LocalGUIPlan: Decodable {
    var steps: [LocalGUIPlanStep]
}

private struct LocalGUIPlanStep: Decodable {
    var action: String
    var bundleId: String?
    var query: String?
    var role: String?
    var match: String?
    var text: String?
    var fromX: Double?
    var fromY: Double?
    var toX: Double?
    var toY: Double?
    var duration: Double?
    var strategy: String?
    var expectQuery: String?
    var expectRole: String?
    var expectMatch: String?
    var expect: String?
    var timeoutMs: Int?
}

private actor GUIElementLookupCache {
    private struct Entry: Sendable {
        var match: GUIElementMatch
        var lastUsedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let maximumEntries = 128
    private let retention: TimeInterval = 10 * 60

    func get(_ key: String, now: Date = Date()) -> GUIElementMatch? {
        prune(now: now)
        guard var entry = entries[key] else { return nil }
        entry.lastUsedAt = now
        entries[key] = entry
        return entry.match
    }

    func put(_ match: GUIElementMatch, key: String, now: Date = Date()) {
        prune(now: now)
        entries[key] = Entry(match: match, lastUsedAt: now)
        if entries.count > maximumEntries {
            let keep = Set(entries.sorted { $0.value.lastUsedAt > $1.value.lastUsedAt }.prefix(maximumEntries).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
    }

    private func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastUsedAt) <= retention }
    }
}

public struct GUIFallbackExecutor: DeferredCapabilitySelfValidatingToolExecutor, Sendable {
    public let route: AppExecutionRoute = .guiFallback
    private let backend: GUIAutomationBackend
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting
    private let attachmentRoot: URL?
    private let elementCache: GUIElementLookupCache

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
        self.elementCache = GUIElementLookupCache()
    }

    public func allowsDeferredCapabilityAttempt(
        _ capabilityIDs: [String],
        for tool: ToolDescriptor,
        capabilities: CapabilityProfile
    ) async -> Bool {
        guard let features = Self.features(for: tool.name) else { return false }
        let expected = Set(features.map(\.capabilityID))
        let deferred = Set(capabilityIDs)
        guard !deferred.isEmpty, deferred.isSubset(of: expected),
              capabilityIDs.allSatisfy({ capabilities.status($0) == .deviceValidationRequired }) else { return false }
        // Route selection stays side-effect free. The exact requested GUI operation below runs
        // in the bounded helper and is itself the runtime proof; helper failures remain fail-closed.
        return true
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        guard let features = Self.features(for: tool.name) else { return false }
        return features.allSatisfy {
            let status = capabilities.status($0.capabilityID)
            return status == .available || status == .deviceValidationRequired
        }
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        switch call.name {
        case "gui.openApp", "gui.openAppObserve":
            guard let bundle = call.arguments["bundleId"], Self.isValidBundleIdentifier(bundle) else {
                throw ToolRouterError.noExecutionRoute("bundleId missing or invalid")
            }
        case "gui.tree", "gui.screenshot":
            break
        case "gui.findElement", "gui.waitForElement", "gui.tapElementObserve", "gui.typeElementObserve":
            guard let query = call.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty, query.utf8.count <= 512 else {
                throw ToolRouterError.noExecutionRoute("element query missing, empty, or exceeds 512 bytes")
            }
            if let role = call.arguments["role"], role.utf8.count > 128 {
                throw ToolRouterError.noExecutionRoute("element role exceeds 128 bytes")
            }
            if let match = call.arguments["match"], GUIElementMatchMode(rawValue: match) == nil {
                throw ToolRouterError.noExecutionRoute("element match must be exact or contains")
            }
            if call.name == "gui.waitForElement" {
                let timeoutMS = Int(call.arguments["timeoutMs"] ?? "3000") ?? 0
                guard timeoutMS >= 100, timeoutMS <= 8_000 else {
                    throw ToolRouterError.noExecutionRoute("waitForElement timeoutMs must be 100...8000")
                }
            }
            if call.name == "gui.typeElementObserve" {
                guard let text = call.arguments["text"], !text.isEmpty,
                      (text.data(using: .utf8)?.count ?? Int.max) <= 16 * 1024 else {
                    throw ToolRouterError.noExecutionRoute("text missing, empty, or exceeds 16 KiB")
                }
            }
        case "gui.navigateBack":
            guard let strategy = call.arguments["strategy"], strategy == "edge" || strategy == "dismissDown" else {
                throw ToolRouterError.noExecutionRoute("navigateBack strategy must be edge or dismissDown")
            }
        case "gui.tap", "gui.tapObserve":
            guard let x = Double(call.arguments["x"] ?? ""), let y = Double(call.arguments["y"] ?? ""),
                  x.isFinite, y.isFinite, x >= 0, y >= 0, x <= 10_000, y <= 10_000 else {
                throw ToolRouterError.noExecutionRoute("tap coordinates missing, non-finite, negative, or outside bounded range")
            }
        case "gui.type", "gui.typeObserve":
            guard let text = call.arguments["text"], !text.isEmpty,
                  (text.data(using: .utf8)?.count ?? Int.max) <= 16 * 1024 else {
                throw ToolRouterError.noExecutionRoute("text missing, empty, or exceeds 16 KiB")
            }
        case "gui.scroll", "gui.scrollObserve":
            guard let dx = Double(call.arguments["dx"] ?? ""), let dy = Double(call.arguments["dy"] ?? ""),
                  dx.isFinite, dy.isFinite, abs(dx) <= 10_000, abs(dy) <= 10_000,
                  abs(dx) >= 0.5 || abs(dy) >= 0.5 else {
                throw ToolRouterError.noExecutionRoute("scroll delta missing, invalid, zero, or outside bounded range")
            }
        case "gui.swipe", "gui.swipeSequence", "gui.swipeObserve":
            let keys = ["fromX", "fromY", "toX", "toY"]
            let coordinates = keys.compactMap { Double(call.arguments[$0] ?? "") }
            let duration = Double(call.arguments["duration"] ?? "0.3")
            guard coordinates.count == keys.count, coordinates.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000 }),
                  let duration, duration.isFinite, duration >= 0.05, duration <= 5.0 else {
                throw ToolRouterError.noExecutionRoute("swipe coordinates/duration missing, invalid, or outside bounded range")
            }
            if call.name == "gui.swipeSequence" {
                guard let rawCount = Double(call.arguments["count"] ?? ""), rawCount.isFinite,
                      rawCount.rounded(.towardZero) == rawCount,
                      rawCount >= 2, rawCount <= 12 else {
                    throw ToolRouterError.noExecutionRoute("swipe sequence count must be an integer from 2 through 12")
                }
            }
        case "gui.runStructuredPlan":
            guard let plan = call.arguments["plan"], !plan.isEmpty, plan.utf8.count <= 16 * 1024 else {
                throw ToolRouterError.noExecutionRoute("structured plan missing, empty, or exceeds 16 KiB")
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
            return ToolResult(toolCallID: call.id, success: true, summary: "Opened app after target-foreground verification")
        case "gui.openAppObserve":
            guard let bundle = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            try await backend.openApp(bundleID: bundle)
            try await Task.sleep(nanoseconds: 200_000_000)
            try Task.checkCancellation()
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Target app became foreground and one fresh screenshot was captured locally for semantic planning.",
                payload: [
                    "bundleId": bundle,
                    "byteCount": String(data.count),
                    "sha256": GUIAutomationPayloadPolicy.sha256Hex(data),
                    "effectVerification": "target_foreground_verified_screenshot_semantic_required",
                    "localObservation": "final_screenshot_attached"
                ],
                attachments: attachment.map { [$0] }
            )
        case "gui.tree":
            let tree = try await backend.tree()
            return ToolResult(toolCallID: call.id, success: true, summary: "GUI tree read", payload: ["tree": ToolOutputEnvelope(trust: .untrustedData, source: "gui.tree", content: tree).promptSafeRepresentation])
        case "gui.findElement":
            let resolved = try await resolveElement(call)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Unique accessibility element resolved locally",
                payload: elementPayload(resolved.match, treeHash: resolved.treeHash, cacheHit: resolved.cacheHit)
            )
        case "gui.waitForElement":
            let timeoutMS = Int(call.arguments["timeoutMs"] ?? "3000") ?? 3000
            let resolved = try await waitForElement(call, timeoutMS: timeoutMS)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Unique accessibility element became available within bounded local wait",
                payload: elementPayload(resolved.match, treeHash: resolved.treeHash, cacheHit: resolved.cacheHit)
            )
        case "gui.tapElementObserve":
            let resolved = try await resolveElement(call)
            guard !Self.isProtectedElement(resolved.match) else {
                throw ToolRouterError.noExecutionRoute("protected/system-confirmation element cannot be automated")
            }
            try await backend.tap(x: resolved.match.frame.centerX, y: resolved.match.frame.centerY)
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            var payload = elementPayload(resolved.match, treeHash: resolved.treeHash, cacheHit: resolved.cacheHit)
            payload["sha256"] = GUIAutomationPayloadPolicy.sha256Hex(data)
            payload["effectVerification"] = "semantic_required"
            payload["localObservation"] = "final_screenshot_attached"
            payload["structuredPath"] = "accessibility_tree_element"
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Unique accessibility element tapped locally; final screenshot attached for semantic verification.",
                payload: payload,
                attachments: attachment.map { [$0] }
            )
        case "gui.typeElementObserve":
            let resolved = try await resolveElement(call)
            guard !Self.isProtectedElement(resolved.match) else {
                throw ToolRouterError.noExecutionRoute("protected/secure input element cannot be automated")
            }
            try await backend.tap(x: resolved.match.frame.centerX, y: resolved.match.frame.centerY)
            try await Task.sleep(nanoseconds: 120_000_000)
            try Task.checkCancellation()
            try await backend.type(call.arguments["text"] ?? "")
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            var payload = elementPayload(resolved.match, treeHash: resolved.treeHash, cacheHit: resolved.cacheHit)
            payload["sha256"] = GUIAutomationPayloadPolicy.sha256Hex(data)
            payload["effectVerification"] = "semantic_required"
            payload["localObservation"] = "final_screenshot_attached"
            payload["structuredPath"] = "accessibility_tree_element_input"
            payload["characters"] = String(call.arguments["text"]?.count ?? 0)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Unique non-protected accessibility element focused and text submitted locally; final screenshot attached for semantic verification.",
                payload: payload,
                attachments: attachment.map { [$0] }
            )
        case "gui.runStructuredPlan":
            return try await executeStructuredPlan(call)
        case "gui.screenshot":
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Screenshot captured",
                payload: [
                    "byteCount": String(data.count),
                    "sha256": GUIAutomationPayloadPolicy.sha256Hex(data)
                ],
                attachments: attachment.map { [$0] }
            )
        case "gui.tap":
            try await backend.tap(x: Double(call.arguments["x"] ?? "0") ?? 0, y: Double(call.arguments["y"] ?? "0") ?? 0)
            return ToolResult(toolCallID: call.id, success: true, summary: "Tap dispatched; foreground effect unverified", payload: ["effectVerification": "required"])
        case "gui.type":
            try await backend.type(call.arguments["text"] ?? "")
            return ToolResult(toolCallID: call.id, success: true, summary: "Text input dispatched; foreground effect unverified", payload: ["effectVerification": "required"])
        case "gui.scroll":
            try await backend.scroll(deltaX: Double(call.arguments["dx"] ?? "0") ?? 0, deltaY: Double(call.arguments["dy"] ?? "0") ?? 0)
            return ToolResult(toolCallID: call.id, success: true, summary: "Scroll dispatched; foreground effect unverified", payload: ["effectVerification": "required"])
        case "gui.swipe":
            try await backend.swipe(fromX: Double(call.arguments["fromX"] ?? "0") ?? 0, fromY: Double(call.arguments["fromY"] ?? "0") ?? 0, toX: Double(call.arguments["toX"] ?? "0") ?? 0, toY: Double(call.arguments["toY"] ?? "0") ?? 0, duration: Double(call.arguments["duration"] ?? "0.3") ?? 0.3)
            return ToolResult(toolCallID: call.id, success: true, summary: "Swipe dispatched; foreground effect unverified", payload: ["effectVerification": "required"])
        case "gui.swipeSequence":
            return try await executeSwipeSequence(call)
        case "gui.tapObserve", "gui.typeObserve", "gui.scrollObserve", "gui.swipeObserve":
            return try await executeActionObserve(call)
        case "gui.navigateBack":
            let baselineData = try await backend.screenshot()
            let baselineSHA256 = GUIAutomationPayloadPolicy.sha256Hex(baselineData)
            let strategy = call.arguments["strategy"] ?? ""
            try await backend.navigateBack(strategy: strategy)
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "iOS back/dismiss gesture changed the foreground frame; final screenshot attached for semantic return verification.",
                payload: [
                    "baselineSHA256": baselineSHA256,
                    "sha256": GUIAutomationPayloadPolicy.sha256Hex(data),
                    "strategy": strategy,
                    "effectVerification": "semantic_required",
                    "localObservation": "final_screenshot_attached"
                ],
                attachments: attachment.map { [$0] }
            )
        case "gui.verify":
            let result = try await backend.verify(call.arguments["assertion"] ?? "")
            return ToolResult(toolCallID: call.id, success: result.passed, summary: "GUI verification", verification: result)
        default:
            throw ToolRouterError.noExecutionRoute(call.name)
        }
    }

    private func executeSwipeSequence(_ call: ToolCall) async throws -> ToolResult {
        let fromX = Double(call.arguments["fromX"] ?? "0") ?? 0
        let fromY = Double(call.arguments["fromY"] ?? "0") ?? 0
        let toX = Double(call.arguments["toX"] ?? "0") ?? 0
        let toY = Double(call.arguments["toY"] ?? "0") ?? 0
        let duration = Double(call.arguments["duration"] ?? "0.3") ?? 0.3
        let count = Int(Double(call.arguments["count"] ?? "0") ?? 0)
        let settleSeconds = max(0.35, min(0.9, duration + 0.2))
        let settleNanoseconds = UInt64(settleSeconds * 1_000_000_000)

        // Capture once before the first gesture, then carry each post-gesture frame forward as the
        // next baseline. This keeps an N-swipe sequence to N+1 screenshots instead of 2N while still
        // stopping if a static foreground produces a byte-identical frame after a dispatched swipe.
        var latestScreenshot = try await backend.screenshot()
        let baselineSHA256 = GUIAutomationPayloadPolicy.sha256Hex(latestScreenshot)
        var previousSHA256 = baselineSHA256
        var dispatchedCount = 0
        var changedObservationCount = 0
        var stoppedAtGesture: Int?

        for gestureIndex in 1...count {
            try Task.checkCancellation()
            try await backend.swipe(
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                duration: duration
            )
            dispatchedCount += 1
            try await Task.sleep(nanoseconds: settleNanoseconds)
            try Task.checkCancellation()

            let observed = try await backend.screenshot()
            let observedSHA256 = GUIAutomationPayloadPolicy.sha256Hex(observed)
            latestScreenshot = observed
            if observedSHA256 == previousSHA256 {
                stoppedAtGesture = gestureIndex
                previousSHA256 = observedSHA256
                break
            }
            changedObservationCount += 1
            previousSHA256 = observedSHA256
        }

        let attachment = try persistScreenshotAttachment(latestScreenshot, sessionID: call.sessionID)
        let sequenceCompleted = dispatchedCount == count && stoppedAtGesture == nil
        var payload: [String: String] = [
            "requestedCount": String(count),
            "dispatchedCount": String(dispatchedCount),
            "changedObservationCount": String(changedObservationCount),
            "sequenceCompleted": sequenceCompleted ? "true" : "false",
            "baselineSHA256": baselineSHA256,
            "sha256": previousSHA256,
            "settleMs": String(Int((settleSeconds * 1000).rounded())),
            "effectVerification": "semantic_required",
            "localObservation": sequenceCompleted ? "changed_after_each_gesture" : "byte_identical_after_gesture"
        ]
        if let stoppedAtGesture {
            payload["stoppedAtGesture"] = String(stoppedAtGesture)
        }
        let summary = sequenceCompleted
            ? "Bounded swipe sequence dispatched \(dispatchedCount)/\(count); each local post-gesture frame changed. Final screenshot attached; semantic foreground outcome remains unverified."
            : "Bounded swipe sequence stopped after \(dispatchedCount)/\(count) gestures because the next local screenshot was byte-identical. Final screenshot attached for re-planning."
        return ToolResult(
            toolCallID: call.id,
            success: true,
            summary: summary,
            payload: payload,
            attachments: attachment.map { [$0] }
        )
    }

    private func executeActionObserve(_ call: ToolCall) async throws -> ToolResult {
        let baselineData = try await backend.screenshot()
        let baselineSHA256 = GUIAutomationPayloadPolicy.sha256Hex(baselineData)

        switch call.name {
        case "gui.tapObserve":
            try await backend.tap(
                x: Double(call.arguments["x"] ?? "0") ?? 0,
                y: Double(call.arguments["y"] ?? "0") ?? 0
            )
        case "gui.typeObserve":
            try await backend.type(call.arguments["text"] ?? "")
        case "gui.scrollObserve":
            try await backend.scroll(
                deltaX: Double(call.arguments["dx"] ?? "0") ?? 0,
                deltaY: Double(call.arguments["dy"] ?? "0") ?? 0
            )
        case "gui.swipeObserve":
            try await backend.swipe(
                fromX: Double(call.arguments["fromX"] ?? "0") ?? 0,
                fromY: Double(call.arguments["fromY"] ?? "0") ?? 0,
                toX: Double(call.arguments["toX"] ?? "0") ?? 0,
                toY: Double(call.arguments["toY"] ?? "0") ?? 0,
                duration: Double(call.arguments["duration"] ?? "0.3") ?? 0.3
            )
        default:
            throw ToolRouterError.noExecutionRoute(call.name)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        try Task.checkCancellation()
        let observed = try await backend.screenshot()
        let observedSHA256 = GUIAutomationPayloadPolicy.sha256Hex(observed)
        let attachment = try persistScreenshotAttachment(observed, sessionID: call.sessionID)
        return ToolResult(
            toolCallID: call.id,
            success: true,
            summary: "Bounded local action→observe micro-plan completed; final screenshot attached and semantic effect remains unverified.",
            payload: [
                "baselineSHA256": baselineSHA256,
                "sha256": observedSHA256,
                "screenChanged": observedSHA256 == baselineSHA256 ? "false" : "true",
                "effectVerification": "semantic_required",
                "localObservation": "final_screenshot_attached"
            ],
            attachments: attachment.map { [$0] }
        )
    }

    private func executeStructuredPlan(_ call: ToolCall) async throws -> ToolResult {
        guard let rawPlan = call.arguments["plan"], let data = rawPlan.data(using: .utf8),
              let plan = try? JSONDecoder().decode(LocalGUIPlan.self, from: data) else {
            throw ToolRouterError.noExecutionRoute("structured plan JSON is malformed")
        }
        try Self.validateStructuredPlan(plan)
        let startedAt = Date()
        var completedSteps = 0
        var elementCacheHits = 0
        var stateChanges = 0

        do {
            for (index, step) in plan.steps.enumerated() {
                try Task.checkCancellation()
                let isFinal = index == plan.steps.count - 1
                let timeoutMS = min(max(step.timeoutMs ?? 2_500, 100), 5_000)
                switch step.action {
                case "openApp":
                    guard let bundleID = step.bundleId else { throw ToolRouterError.noExecutionRoute("openApp step missing bundleId") }
                    try await backend.openApp(bundleID: bundleID)
                    stateChanges += 1
                case "waitForElement":
                    let elementCall = Self.elementLookupCall(from: step, sessionID: call.sessionID, toolName: "gui.waitForElement")
                    let resolved = try await waitForElement(elementCall, timeoutMS: timeoutMS)
                    if resolved.cacheHit { elementCacheHits += 1 }
                case "tapElement":
                    let elementCall = Self.elementLookupCall(from: step, sessionID: call.sessionID, toolName: "gui.findElement")
                    let resolved = try await resolveElement(elementCall)
                    if resolved.cacheHit { elementCacheHits += 1 }
                    guard !Self.isProtectedElement(resolved.match) else {
                        throw ToolRouterError.noExecutionRoute("structured plan stopped at protected/system-confirmation element")
                    }
                    guard !Self.isCommitElement(resolved.match) else {
                        throw ToolRouterError.noExecutionRoute("structured plan stopped before a commit/irreversible element; execute that action as a separately verified tool step")
                    }
                    try await backend.tap(x: resolved.match.frame.centerX, y: resolved.match.frame.centerY)
                    stateChanges += 1
                    if !isFinal || step.expectQuery != nil {
                        try await validateExpectation(step, timeoutMS: timeoutMS)
                    }
                case "typeElement":
                    let elementCall = Self.elementLookupCall(from: step, sessionID: call.sessionID, toolName: "gui.findElement")
                    let resolved = try await resolveElement(elementCall)
                    if resolved.cacheHit { elementCacheHits += 1 }
                    guard !Self.isProtectedElement(resolved.match) else {
                        throw ToolRouterError.noExecutionRoute("structured plan stopped at protected/secure input element")
                    }
                    try await backend.tap(x: resolved.match.frame.centerX, y: resolved.match.frame.centerY)
                    try await Task.sleep(nanoseconds: 120_000_000)
                    try Task.checkCancellation()
                    try await backend.type(step.text ?? "")
                    stateChanges += 1
                    if !isFinal || step.expectQuery != nil {
                        try await validateExpectation(step, timeoutMS: timeoutMS)
                    }
                case "swipe":
                    try await backend.swipe(
                        fromX: step.fromX ?? 0,
                        fromY: step.fromY ?? 0,
                        toX: step.toX ?? 0,
                        toY: step.toY ?? 0,
                        duration: step.duration ?? 0.3
                    )
                    stateChanges += 1
                    if !isFinal || step.expectQuery != nil {
                        try await validateExpectation(step, timeoutMS: timeoutMS)
                    }
                case "navigateBack":
                    try await backend.navigateBack(strategy: step.strategy ?? "")
                    stateChanges += 1
                    if !isFinal || step.expectQuery != nil {
                        try await validateExpectation(step, timeoutMS: timeoutMS)
                    }
                default:
                    throw ToolRouterError.noExecutionRoute("unsupported structured plan action: \(step.action)")
                }
                completedSteps += 1
            }
        } catch {
            let elapsedMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            let screenshot = try? await backend.screenshot()
            let attachment = try screenshot.flatMap { try persistScreenshotAttachment($0, sessionID: call.sessionID) }
            var payload: [String: String] = [
                "completedSteps": String(completedSteps),
                "requestedSteps": String(plan.steps.count),
                "stateChanges": String(stateChanges),
                "elementCacheHits": String(elementCacheHits),
                "localExecutionMS": String(elapsedMS),
                "replanRequired": "true",
                "failure": String(describing: error)
            ]
            if let screenshot { payload["sha256"] = GUIAutomationPayloadPolicy.sha256Hex(screenshot) }
            return ToolResult(
                toolCallID: call.id,
                success: false,
                summary: "Structured local plan stopped safely after \(completedSteps)/\(plan.steps.count) steps; fresh screenshot attached when available for re-planning.",
                payload: payload,
                attachments: attachment.map { [$0] }
            )
        }

        let screenshot = try await backend.screenshot()
        let attachment = try persistScreenshotAttachment(screenshot, sessionID: call.sessionID)
        let elapsedMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        return ToolResult(
            toolCallID: call.id,
            success: true,
            summary: "Structured local plan completed \(completedSteps) steps with local validation; one final screenshot is attached for semantic completion review.",
            payload: [
                "completedSteps": String(completedSteps),
                "requestedSteps": String(plan.steps.count),
                "stateChanges": String(stateChanges),
                "elementCacheHits": String(elementCacheHits),
                "localExecutionMS": String(elapsedMS),
                "sha256": GUIAutomationPayloadPolicy.sha256Hex(screenshot),
                "effectVerification": "local_structured_validators_passed_final_semantic_review_required",
                "localObservation": "final_screenshot_attached",
                "structuredPath": "local_plan"
            ],
            attachments: attachment.map { [$0] }
        )
    }

    private func validateExpectation(_ step: LocalGUIPlanStep, timeoutMS: Int) async throws {
        guard let query = step.expectQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ToolRouterError.noExecutionRoute("non-final state-changing structured plan step is missing expectQuery")
        }
        let expectation = step.expect ?? "present"
        guard expectation == "present" || expectation == "absent" else {
            throw ToolRouterError.noExecutionRoute("structured plan expect must be present or absent")
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000.0)
        let mode = GUIElementMatchMode(rawValue: step.expectMatch ?? "exact") ?? .exact
        repeat {
            try Task.checkCancellation()
            let tree = try await backend.tree()
            let matches = GUIElementResolver.find(in: tree, query: query, role: step.expectRole, mode: mode, maximumMatches: 3)
            if expectation == "present", matches.count == 1 { return }
            if expectation == "absent", matches.isEmpty { return }
            if expectation == "present", matches.count > 1 {
                throw ToolRouterError.noExecutionRoute("structured plan expectation is ambiguous; refine expectQuery/expectRole")
            }
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 180_000_000)
        } while Date() < deadline
        throw ToolRouterError.noExecutionRoute("structured plan local expectation did not become true before timeout")
    }

    private static func validateStructuredPlan(_ plan: LocalGUIPlan) throws {
        guard !plan.steps.isEmpty, plan.steps.count <= 8 else {
            throw ToolRouterError.noExecutionRoute("structured plan must contain 1...8 steps")
        }
        let supported = Set(["openApp", "waitForElement", "tapElement", "typeElement", "swipe", "navigateBack"])
        for (index, step) in plan.steps.enumerated() {
            guard supported.contains(step.action) else {
                throw ToolRouterError.noExecutionRoute("unsupported structured plan action: \(step.action)")
            }
            let timeoutMS = step.timeoutMs ?? 2_500
            guard timeoutMS >= 100, timeoutMS <= 5_000 else {
                throw ToolRouterError.noExecutionRoute("structured plan timeoutMs must be 100...5000")
            }
            if step.action == "openApp" {
                guard let bundleID = step.bundleId, isValidBundleIdentifier(bundleID) else {
                    throw ToolRouterError.noExecutionRoute("structured openApp bundleId missing or invalid")
                }
            }
            if ["waitForElement", "tapElement", "typeElement"].contains(step.action) {
                guard let query = step.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty, query.utf8.count <= 512 else {
                    throw ToolRouterError.noExecutionRoute("structured element step query missing or invalid")
                }
                if let match = step.match, GUIElementMatchMode(rawValue: match) == nil {
                    throw ToolRouterError.noExecutionRoute("structured element match must be exact or contains")
                }
            }
            if step.action == "typeElement" {
                guard let text = step.text, !text.isEmpty, text.utf8.count <= 16 * 1024 else {
                    throw ToolRouterError.noExecutionRoute("structured typeElement text missing or too large")
                }
            }
            if step.action == "swipe" {
                let values = [step.fromX, step.fromY, step.toX, step.toY].compactMap { $0 }
                let duration = step.duration ?? 0.3
                guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000 }),
                      duration.isFinite, duration >= 0.05, duration <= 5 else {
                    throw ToolRouterError.noExecutionRoute("structured swipe coordinates/duration invalid")
                }
            }
            if step.action == "navigateBack" {
                guard step.strategy == "edge" || step.strategy == "dismissDown" else {
                    throw ToolRouterError.noExecutionRoute("structured navigateBack strategy invalid")
                }
            }
            if ["tapElement", "typeElement", "swipe", "navigateBack"].contains(step.action) {
                guard let expectQuery = step.expectQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !expectQuery.isEmpty, expectQuery.utf8.count <= 512 else {
                    throw ToolRouterError.noExecutionRoute("every state-changing structured step requires expectQuery")
                }
                if let expect = step.expect, expect != "present" && expect != "absent" {
                    throw ToolRouterError.noExecutionRoute("structured expect must be present or absent")
                }
                if let match = step.expectMatch, GUIElementMatchMode(rawValue: match) == nil {
                    throw ToolRouterError.noExecutionRoute("structured expectMatch must be exact or contains")
                }
            }
        }
    }

    private static func elementLookupCall(from step: LocalGUIPlanStep, sessionID: UUID, toolName: String) -> ToolCall {
        var arguments: [String: String] = ["query": step.query ?? ""]
        if let role = step.role { arguments["role"] = role }
        if let match = step.match { arguments["match"] = match }
        if let timeoutMS = step.timeoutMs { arguments["timeoutMs"] = String(timeoutMS) }
        return ToolCall(name: toolName, arguments: arguments, sessionID: sessionID)
    }

    private func resolveElement(_ call: ToolCall) async throws -> (match: GUIElementMatch, treeHash: String, cacheHit: Bool) {
        let tree = try await backend.tree()
        let treeHash = GUIAutomationPayloadPolicy.sha256Hex(Data(tree.utf8))
        let query = call.arguments["query"] ?? ""
        let role = call.arguments["role"]
        let mode = GUIElementMatchMode(rawValue: call.arguments["match"] ?? "exact") ?? .exact
        let cacheKey = [treeHash, mode.rawValue, role ?? "", query].joined(separator: "|")
        if let cached = await elementCache.get(cacheKey) {
            return (cached, treeHash, true)
        }
        let matches = GUIElementResolver.find(in: tree, query: query, role: role, mode: mode, maximumMatches: 3)
        guard matches.count == 1 else {
            if matches.isEmpty {
                throw ToolRouterError.noExecutionRoute("structured element query returned no usable visible match")
            }
            throw ToolRouterError.noExecutionRoute("structured element query is ambiguous (\(matches.count)+ matches); refine query/role instead of guessing coordinates")
        }
        let match = matches[0]
        await elementCache.put(match, key: cacheKey)
        return (match, treeHash, false)
    }

    private func waitForElement(_ call: ToolCall, timeoutMS: Int) async throws -> (match: GUIElementMatch, treeHash: String, cacheHit: Bool) {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000.0)
        var lastError: Error?
        repeat {
            do {
                return try await resolveElement(call)
            } catch {
                lastError = error
            }
            try Task.checkCancellation()
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 180_000_000)
        } while Date() < deadline
        throw lastError ?? ToolRouterError.noExecutionRoute("structured element did not appear before timeout")
    }

    private func elementPayload(_ match: GUIElementMatch, treeHash: String, cacheHit: Bool) -> [String: String] {
        var payload: [String: String] = [
            "path": match.path,
            "treeSHA256": treeHash,
            "cache": cacheHit ? "tree_signature_hit" : "tree_signature_miss",
            "x": String(match.frame.x),
            "y": String(match.frame.y),
            "width": String(match.frame.width),
            "height": String(match.frame.height),
            "centerX": String(match.frame.centerX),
            "centerY": String(match.frame.centerY)
        ]
        if let role = match.role { payload["role"] = role }
        if let identifier = match.identifier { payload["identifier"] = identifier }
        if let label = match.label { payload["label"] = String(label.prefix(256)) }
        if let title = match.title { payload["title"] = String(title.prefix(256)) }
        if let placeholder = match.placeholder { payload["placeholder"] = String(placeholder.prefix(256)) }
        return payload
    }

    private static func isProtectedElement(_ match: GUIElementMatch) -> Bool {
        let haystack = match.searchableText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let protectedMarkers = [
            "face id", "touch id", "apple pay", "passcode", "password confirmation", "security code",
            "允许", "不允许", "系统权限", "密码确认", "支付确认", "面容 id", "触控 id"
        ]
        return protectedMarkers.contains(where: { haystack.contains($0) })
    }

    private static func isCommitElement(_ match: GUIElementMatch) -> Bool {
        let haystack = match.searchableText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let commitMarkers = [
            "send", "submit", "publish", "post", "delete", "remove", "purchase", "buy", "pay", "checkout", "confirm order",
            "发送", "提交", "发布", "删除", "移除", "购买", "支付", "结算", "确认订单", "卸载"
        ]
        return commitMarkers.contains(where: { haystack.contains($0) })
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

    private static func features(for toolName: String) -> [GUIAutomationFeature]? {
        switch toolName {
        case "gui.openApp": return [.openApp]
        case "gui.openAppObserve": return [.openApp, .screenshot]
        case "gui.tree", "gui.findElement", "gui.waitForElement": return [.tree]
        case "gui.tapElementObserve": return [.tree, .touch, .screenshot]
        case "gui.typeElementObserve": return [.tree, .touch, .textInput, .screenshot]
        case "gui.runStructuredPlan": return [.openApp, .tree, .screenshot, .touch, .textInput, .gestures]
        case "gui.screenshot": return [.screenshot]
        case "gui.tap": return [.touch]
        case "gui.type": return [.textInput]
        case "gui.scroll", "gui.swipe": return [.gestures]
        case "gui.swipeSequence", "gui.navigateBack", "gui.scrollObserve", "gui.swipeObserve": return [.gestures, .screenshot]
        case "gui.tapObserve": return [.touch, .screenshot]
        case "gui.typeObserve": return [.textInput, .screenshot]
        case "gui.verify": return [.verify]
        default: return nil
        }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
