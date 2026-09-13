import Foundation
import SwiftUI
import UIKit
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

enum EmbeddedVisionHelper {
    static let executableName = "CloudCodeVisionHelper"
    static let expectedProtocolMarker = "cloudcode-vision-helper-protocol=1"

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

    static func guiOCR(jpegData: Data, maximumElements: Int, forcePrecise: Bool = false) -> (json: String?, detail: String) {
        guard embeddedHelperMatchesExpectedProtocol,
              FileManager.default.isExecutableFile(atPath: executablePath),
              GUIAutomationPayloadPolicy.isValidScreenshotJPEG(jpegData) else {
            return (nil, "轻量 Vision helper 当前不可用或输入不是有效 bounded JPEG。")
        }
        let boundedMaximum = min(max(maximumElements, 1), 48)
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCode-GUI-OCR-\(UUID().uuidString).jpg", isDirectory: false)
        guard FileManager.default.createFile(atPath: inputURL.path, contents: jpegData) else {
            return (nil, "无法为轻量 Vision helper 创建受控 tmp JPEG。")
        }
        // The ordinary helper runs under the same mobile user as the host App. Keep the transient
        // screenshot owner-only so introducing a non-root OCR fallback does not widen local read access.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        var standardOutput: NSString?
        var standardError: NSString?
        let helperTimeout: TimeInterval = 6
        let code = CloudCodeSpawnHelperWithSeparatedOutput(
            executablePath,
            ["ocr-file", inputURL.path, String(boundedMaximum), forcePrecise ? "accurate" : "fast"],
            false,
            helperTimeout,
            &standardOutput,
            &standardError
        )
        let stdout = (standardOutput as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = (standardError as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stdoutData = stdout.data(using: .utf8)
        let outputJSONValid = !stdout.isEmpty
            && stdout.utf8.count <= 64 * 1024
            && stdoutData.flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
#if canImport(Darwin)
        let parentTimeoutCode = -7000 - Int(ETIMEDOUT)
#else
        let parentTimeoutCode = Int.min
#endif
        // OCR is read-only. If a complete parseable JSON result was synchronously written before a
        // late parent-side reap timeout, preserve that observation rather than discarding it. This
        // mirrors the existing bounded AX read-only acceptance rule and never converts partial text
        // into success.
        if outputJSONValid, code == 0 || (code == parentTimeoutCode && stderr.contains("stdout-json-completed")) {
            let suffix = stderr.isEmpty ? "" : " helper diagnostics: \(stderr)"
            let completion = code == 0 ? "completed" : "completed_json_before_parent_timeout"
            return (stdout, "ocr_helper_status=\(completion); OCR 已在无 root/private GUI entitlement 的轻量 Vision helper 中执行。\(suffix)")
        }

        let failureClass: String
        if code == parentTimeoutCode || stderr.contains("helper timed out after") {
            failureClass = "helper_timeout"
        } else if stdout.isEmpty {
            failureClass = "no_json"
        } else if stdout.utf8.count > 64 * 1024 {
            failureClass = "json_oversized"
        } else if !outputJSONValid {
            failureClass = "invalid_json"
        } else {
            failureClass = "helper_exit_failure"
        }
        let diagnostic = stderr.isEmpty ? stdout : stderr
        let boundedDiagnostic = String(diagnostic.prefix(4_096))
        return (nil, "ocr_helper_status=\(failureClass); exit=\(code); \(boundedDiagnostic.isEmpty ? "no helper diagnostic" : boundedDiagnostic)")
    }
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

    struct AppIntrospectionPayload: Decodable, Sendable {
        var bundleID: String
        var displayName: String
        var version: String
        var build: String
        var bundlePath: String
        var dataContainerPath: String
        var executable: String
        var urlSchemes: [String]
        var documentTypes: [String]
        var utTypes: [String]
        var extensions: [String]
        var frameworks: [String]
        var appGroups: [String]
        var localData: [String: String]
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

    struct LaunchOutcome: Sendable, Equatable {
        var accepted: Bool
        var foregroundVerified: Bool
        var detail: String
    }

    struct FocusedTextInputPayload: Decodable, Sendable {
        var runtimeAvailable: Bool
        var focusedElementAvailable: Bool
        var focusedTextInput: Bool
        var role: String
        var backend: String
        var pid: Int32
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

        // RootHelperBridge appends transport/process evidence to stderr for CloudCode helpers.
        // Machine-readable helper payloads and exact probe markers live on stdout. Keeping the two
        // streams merged made a successful `enumerate-json` look like two concatenated JSON objects
        // and also made the exact protocol marker probe fail. Preserve stdout as the authoritative
        // success payload; only fold stderr into the diagnostic on failure (or when success has no
        // stdout payload at all).
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
        let stdout = (standardOutput as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = (standardError as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code == 0 {
            return (code, stdout)
        }
        if stdout.isEmpty { return (code, stderr) }
        if stderr.isEmpty { return (code, stdout) }
        return (code, stdout + "\n" + stderr)
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

    private static func mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: Int, diagnostic: String) -> Bool {
        let parentTimeoutCode = -7000 - Int(ETIMEDOUT)
        return code == parentTimeoutCode
            && diagnostic.contains("helper timed out after")
            && !diagnostic.contains("capture truncated")
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
        case 71: meaning = "隔离 helper 的本地 Vision OCR 输入或执行失败"
        case 73: meaning = "后台 assertion 目标进程不存在或无效"
        case 74: meaning = "后台 assertion worker 创建失败"
        case 75: meaning = "AssertionServices 拒绝或未建立后台保活 assertion"
        case 76: meaning = "后台 assertion worker 停止失败"
        case 77: meaning = "后台 assertion worker 已退出"
        case 78: meaning = "App Info.plist 无法读取或 Bundle ID 不匹配"
        case 79: meaning = "App introspection 输出无法安全序列化或超过上限"
        case 80: meaning = "URL 已被系统接受，但目标 App 前台状态无法验证"
        case 81: meaning = "URL 路由被系统拒绝"
        case 82: meaning = "IPA 路径、文件类型或期望 Bundle/Build 元数据无效"
        case 83: meaning = "未发现可信且可执行的 TrollStore trollstorehelper"
        case 84: meaning = "TrollStore 签名/安装 helper 执行失败或超时"
        case 85: meaning = "TrollStore 返回成功，但安装后的 Bundle/Build 最终状态不匹配"
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

        func decode(_ diagnostic: String) -> EnumerationPayload? {
            let decoder = JSONDecoder()
            if let data = diagnostic.data(using: .utf8), let payload = try? decoder.decode(EnumerationPayload.self, from: data) {
                return payload
            }
            if let start = diagnostic.firstIndex(of: "{"), let end = diagnostic.lastIndex(of: "}") {
                let json = String(diagnostic[start...end])
                if let data = json.data(using: .utf8), let payload = try? decoder.decode(EnumerationPayload.self, from: data) {
                    return payload
                }
            }
            return nil
        }

        func hasCrossAppEvidence(_ payload: EnumerationPayload) -> Bool {
            let ownBundleID = Bundle.main.bundleIdentifier
            return payload.apps.contains { !$0.bundleID.isEmpty && $0.bundleID != ownBundleID }
        }

        // Cross-App discovery is invoked only by an explicit apps.list/apps.inspect/container request,
        // never by the startup-safe path. On TrollStore, a detached non-root helper can receive a
        // partial LaunchServices view and then spend the full watchdog window walking hundreds of
        // Bundle containers, which made Build 99 collapse the live index back to Cloud Code itself.
        // Prefer the same embedded helper under the TrollStore root persona for this read-only,
        // bounded inventory operation; exact launch/uninstall still revalidate their own authority.
        let privileged = runSeparated(["enumerate-json"], privilege: .root, timeout: 7)
        if let payload = decode(privileged.stdout), hasCrossAppEvidence(payload) {
            if privileged.code == 0 {
                return (payload, "\(payload.backend) 已通过 bounded root helper 完成跨 App 枚举。")
            }
            if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: privileged.code, diagnostic: privileged.stderr) {
                return (payload, "\(payload.backend) 已返回可完整解码的跨 App 只读枚举；helper 随后在退出阶段触发父进程超时，因此保留已验证 payload，同时把退出超时留给诊断。")
            }
        }
        let privilegedDiagnostic = privileged.stderr.isEmpty ? privileged.stdout : privileged.stderr
        let privilegedDetail = privileged.code == 0
            ? "root helper 只返回 Cloud Code 自身或输出无法解析"
            : failureDetail(prefix: "\(executableName) root 枚举", code: privileged.code, diagnostic: privilegedDiagnostic)

        // Keep the isolated path as a compatibility fallback for runtimes where persona/root spawn is
        // unavailable but LaunchServices is still fully visible to the embedded helper.
        let isolated = runSeparated(["enumerate-json"], privilege: .isolatedUser, timeout: 5)
        if let payload = decode(isolated.stdout), hasCrossAppEvidence(payload) {
            if isolated.code == 0 {
                return (payload, "\(payload.backend) 已在隔离 helper 子进程内完成跨 App 枚举；root 路径未采用：\(privilegedDetail)")
            }
            if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: isolated.code, diagnostic: isolated.stderr) {
                return (payload, "\(payload.backend) 已返回可完整解码的隔离只读枚举；helper 随后在退出阶段触发父进程超时。root 路径未采用：\(privilegedDetail)")
            }
        }
        let isolatedDiagnostic = isolated.stderr.isEmpty ? isolated.stdout : isolated.stderr
        let isolatedDetail = isolated.code == 0
            ? "隔离 helper 只返回 Cloud Code 自身或输出无法解析"
            : failureDetail(prefix: "\(executableName) 隔离枚举", code: isolated.code, diagnostic: isolatedDiagnostic)
        return (nil, "跨 App 枚举未建立有效索引；root：\(privilegedDetail)；isolated：\(isolatedDetail)。")
    }

    static func appIntrospection(bundleID: String) -> (payload: AppIntrospectionPayload?, detail: String) {
        let result = runSeparated(["app-introspect-json", bundleID], privilege: .root, timeout: 5)
        guard let data = result.stdout.data(using: .utf8), data.count <= 256 * 1024,
              let payload = try? JSONDecoder().decode(AppIntrospectionPayload.self, from: data),
              payload.bundleID == bundleID else {
            if result.code != 0 {
                let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
                return (nil, failureDetail(prefix: "App introspection", code: result.code, diagnostic: diagnostic))
            }
            return (nil, "App introspection 返回内容无法验证；已按 fail-closed 处理。")
        }
        if result.code == 0 {
            return (payload, "已通过 bounded root helper 读取当前 App 静态 metadata；结果仅作为 discovery/performance hint。")
        }
        if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: result.code, diagnostic: result.stderr) {
            return (payload, "App introspection 已返回 bundleID 匹配且可完整解码的只读 metadata；helper 随后在退出阶段触发父进程超时，因此保留已验证 payload。")
        }
        let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
        return (nil, failureDetail(prefix: "App introspection", code: result.code, diagnostic: diagnostic))
    }

    static func uninstallCapability(bundleID: String) -> RootHelperCapabilitySnapshot {
        let result = run(["probe-uninstall", bundleID], privilege: .root, timeout: 6)
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "卸载后端、权威安装状态查询及必要的 Bundle 容器兜底访问已在 helper 子进程内验证。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "helper 卸载能力探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func ipaInstallCapability() -> RootHelperCapabilitySnapshot {
        // Discovery is filesystem-only inside the root helper. It does not invoke TrollStore or
        // install a canary, so privileged capability validation remains side-effect free.
        let result = run(["probe-ipa-install"], privilege: .root, timeout: 5)
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: true, detail: "已发现可信 TrollStore 安装包及其 trollstorehelper；实际 IPA 仍需 ToolRouter 系统变更审批。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "TrollStore IPA 安装能力探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func installIPA(path: String, bundleID: String, build: String) -> (success: Bool, detail: String) {
        let result = run(["install-ipa", path, bundleID, build], privilege: .root, timeout: 100)
        if result.code == 0 {
            return (true, result.diagnostic.isEmpty ? "TrollStore helper 已完成签名/安装并核对 Bundle/Build。" : result.diagnostic)
        }
        return (false, failureDetail(prefix: "TrollStore IPA 安装", code: result.code, diagnostic: result.diagnostic))
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

    static func verifyFrontmost(bundleID: String) -> (verified: Bool, detail: String) {
        let result = run(["is-frontmost", bundleID], privilege: .root, timeout: 3)
        if result.code == 0 { return (true, "root helper 已确认目标 App 成为前台。") }
        return (false, failureDetail(prefix: "目标 App 前台验证", code: result.code, diagnostic: result.diagnostic))
    }

    static func launch(bundleID: String) -> LaunchOutcome {
        func acceptedButUnverified(_ result: (code: Int, diagnostic: String)) -> Bool {
            result.code == 46
                && result.diagnostic.contains("accepted=1")
                && result.diagnostic.contains("foreground=unverified")
        }

        let isolated = run(["launch", bundleID], privilege: .isolatedUser, timeout: 5)
        if isolated.code == 0 {
            let route = isolated.diagnostic.isEmpty ? "" : " \(isolated.diagnostic)"
            return LaunchOutcome(accepted: true, foregroundVerified: true, detail: "隔离 helper 已验证目标安装状态并完成 App 启动路径。\(route)")
        }

        // LaunchServices returning "accepted" is not evidence that the requested App became the
        // foreground App. Build 129 physical-device evidence reproduced the failure mode directly:
        // WeChat remained installed and discoverable while an accepted-but-unverified isolated launch
        // left Cloud Code frontmost. Therefore an unverified isolated activation must always fall
        // through to the bounded root/FrontBoard/BackBoard path. The root helper first rechecks the
        // current frontmost bundle, so a late successful LaunchServices transition returns quickly;
        // otherwise the board-service fallback performs one exact, idempotent activation attempt.
        if isolated.code == 46 {
            let isolatedDetail = failureDetail(prefix: "隔离 helper 启动 App", code: isolated.code, diagnostic: isolated.diagnostic)
            let privileged = run(["launch", bundleID], privilege: .root, timeout: 6)
            if privileged.code == 0 {
                let route = privileged.diagnostic.isEmpty ? "" : " \(privileged.diagnostic)"
                return LaunchOutcome(accepted: true, foregroundVerified: true, detail: "隔离 LaunchServices 未建立可验证前台后，root helper 通过 bounded 系统启动路由完成目标 App 前台切换。\(route)")
            }
            let privilegedDetail = failureDetail(prefix: "root helper 启动 App", code: privileged.code, diagnostic: privileged.diagnostic)
            if acceptedButUnverified(privileged) || acceptedButUnverified(isolated) {
                return LaunchOutcome(
                    accepted: true,
                    foregroundVerified: false,
                    detail: "启动请求曾被系统接受但目标前台仍未被证明；已继续尝试一次 root/FrontBoard/BackBoard 激活，后续必须依赖 fresh observation 验证且不得把截图默认解释为目标 App。\(isolatedDetail)；root fallback：\(privilegedDetail)"
                )
            }
            return LaunchOutcome(accepted: false, foregroundVerified: false, detail: "\(isolatedDetail)；root fallback 同样失败：\(privilegedDetail)")
        }

        return LaunchOutcome(accepted: false, foregroundVerified: false, detail: failureDetail(prefix: "隔离 helper 启动 App", code: isolated.code, diagnostic: isolated.diagnostic))
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
        if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: result.code, diagnostic: result.diagnostic),
           String(result.diagnostic.split(separator: "\n", maxSplits: 1).first ?? "") == expectedProtocolMarker {
            return RootHelperCapabilitySnapshot(available: true, detail: "\(executableName) 已返回精确 helper 协议指纹；随后仅在退出阶段触发父进程超时，因此保留已验证的只读 capability 结果。")
        }
        if result.code == 0 {
            return RootHelperCapabilitySnapshot(available: false, detail: "\(executableName) root 探测返回了非预期协议指纹；拒绝使用可能过期的 helper。")
        }
        return RootHelperCapabilitySnapshot(available: false, detail: failureDetail(prefix: "\(executableName) root 探测", code: result.code, diagnostic: result.diagnostic))
    }

    static func filesystemCapability() -> PrivilegedFilesystemCapabilitySnapshot {
        // Keep the machine-readable capability payload separate from bridge timeout diagnostics so
        // a fully completed bounded canary cannot be confused with the helper's later exit timeout.
        let result = runSeparated(["probe-filesystem-json"], privilege: .root, timeout: 5)
        let payload = result.stdout.data(using: .utf8).flatMap { try? JSONDecoder().decode(FilesystemProbePayload.self, from: $0) }
        guard let payload else {
            let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
            return PrivilegedFilesystemCapabilitySnapshot(
                sharedUserFilesAvailable: false,
                unrestrictedAvailable: false,
                detail: result.code == 0
                    ? "helper 高权限文件系统探测输出无法解析；已按 fail-closed 处理。"
                    : failureDetail(prefix: "helper 高权限文件系统探测", code: result.code, diagnostic: diagnostic)
            )
        }
        if result.code == 0 {
            return PrivilegedFilesystemCapabilitySnapshot(
                sharedUserFilesAvailable: payload.sharedUserFiles,
                unrestrictedAvailable: payload.unrestricted,
                detail: payload.detail
            )
        }
        if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: result.code, diagnostic: result.stderr) {
            // The JSON is useful diagnostic evidence that the bounded canary finished, but this
            // capability gates later filesystem writes/deletes. A parent exit timeout must not turn
            // that evidence into destructive authority; keep both capabilities fail-closed.
            return PrivilegedFilesystemCapabilitySnapshot(
                sharedUserFilesAvailable: false,
                unrestrictedAvailable: false,
                detail: payload.detail + "；helper 随后在退出阶段触发父进程超时。完整 JSON 仅保留为诊断证据，不授予共享文件或 unrestricted 写/删权限"
            )
        }
        let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
        return PrivilegedFilesystemCapabilitySnapshot(
            sharedUserFilesAvailable: false,
            unrestrictedAvailable: false,
            detail: failureDetail(prefix: "helper 高权限文件系统探测", code: result.code, diagnostic: diagnostic)
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
        guard let payload = decodeGUIProbe(result.stdout) else {
            let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
            return (nil, failureDetail(prefix: "隔离 GUI readiness 探测", code: result.code, diagnostic: diagnostic))
        }
        if result.code == 0 {
            let diagnosticSuffix = result.stderr.isEmpty ? "" : " helper diagnostics: \(result.stderr)"
            return (payload, "\(payload.backend) 已在受限 root helper 内完成只读 readiness handshake。\(diagnosticSuffix)")
        }
        if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: result.code, diagnostic: result.stderr) {
            return (payload, "\(payload.backend) 已返回完整可解码的只读 readiness payload；helper 随后仅在退出阶段触发父进程超时，因此保留已验证结果。")
        }
        let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
        return (nil, failureDetail(prefix: "隔离 GUI readiness 探测", code: result.code, diagnostic: diagnostic))
    }

    static func guiTree() -> (tree: String?, detail: String) {
        func validatedTree(_ result: (code: Int, stdout: String, stderr: String)) -> String? {
            guard !result.stdout.isEmpty, result.stdout.utf8.count <= 256 * 1024,
                  let treeData = result.stdout.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: treeData)) != nil else { return nil }
            if result.code == 0 { return result.stdout }
            if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: result.code, diagnostic: result.stderr) { return result.stdout }
            return nil
        }

        // AX authority on TrollStore is runtime-dependent. The non-root bridge call is intercepted
        // inside the real System-app host first so semantic reads keep a registered RunningBoard/App
        // identity instead of relying on an anonymous one-shot helper. A single bounded persona-99
        // retry remains the fail-closed fallback. Neither route mutates AXManualAccessibility, so
        // this fallback cannot reintroduce the visible green scan frame.
        let isolated = runSeparated(["gui-tree-json"], privilege: .isolatedUser, timeout: 1.25)
        if let tree = validatedTree(isolated) {
            if isolated.code == 0 {
                let suffix = isolated.stderr.isEmpty ? "" : " helper diagnostics: \(isolated.stderr)"
                return (tree, "AXRuntime tree 已由 System-app host AX fast path 返回。\(suffix)")
            }
            return (tree, "AXRuntime tree 已由 non-root AX 路径返回完整可解析 JSON；退出阶段异常不影响这份已验证的只读 tree。")
        }
        if isolated.stdout.utf8.count > 256 * 1024 {
            return (nil, "GUI tree 输出超过 256 KiB 限制，已 fail closed。")
        }

        let privileged = runSeparated(["gui-tree-json"], privilege: .root, timeout: 0.7)
        if let tree = validatedTree(privileged) {
            let suffix = privileged.stderr.isEmpty ? "" : " helper diagnostics: \(privileged.stderr)"
            return (tree, "System-app host AX fast path 未返回可用语义树；persona-99 被动 AX fallback 返回了有效 tree。\(suffix)")
        }

        let isolatedDiagnostic = isolated.stderr.isEmpty ? isolated.stdout : isolated.stderr
        let privilegedDiagnostic = privileged.stderr.isEmpty ? privileged.stdout : privileged.stderr
        let isolatedDetail = failureDetail(prefix: "GUI tree (System-app host AX fast path)", code: isolated.code, diagnostic: isolatedDiagnostic)
        let privilegedDetail = failureDetail(prefix: "GUI tree (persona-99 passive fallback)", code: privileged.code, diagnostic: privilegedDiagnostic)
        return (nil, "\(isolatedDetail)；root fallback：\(privilegedDetail)")
    }

    static func focusedTextInput() -> (payload: FocusedTextInputPayload?, detail: String) {
        func decode(_ result: (code: Int, stdout: String, stderr: String)) -> FocusedTextInputPayload? {
            guard let data = result.stdout.data(using: .utf8), data.count <= 4 * 1024,
                  let payload = try? JSONDecoder().decode(FocusedTextInputPayload.self, from: data) else { return nil }
            if result.code == 0 { return payload }
            if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: result.code, diagnostic: result.stderr) { return payload }
            return nil
        }

        let isolated = runSeparated(["gui-focused-text-input-json"], privilege: .isolatedUser, timeout: 1.25)
        if let payload = decode(isolated) {
            if isolated.code == 0 {
                return (payload, isolated.stderr.isEmpty ? "AX focused-text probe completed via System-app host AX fast path." : "AX focused-text probe completed via System-app host AX fast path. diagnostics: \(isolated.stderr)")
            }
            return (payload, "AX focused-text probe 已由 non-root AX 路径返回完整可解码 payload；退出阶段异常不影响这份已验证的只读结果。")
        }

        let privileged = runSeparated(["gui-focused-text-input-json"], privilege: .root, timeout: 0.7)
        if let payload = decode(privileged) {
            return (payload, privileged.stderr.isEmpty ? "AX focused-text probe completed via persona-99 passive fallback." : "AX focused-text probe completed via persona-99 passive fallback. helper diagnostics: \(privileged.stderr)")
        }

        let isolatedDiagnostic = isolated.stderr.isEmpty ? isolated.stdout : isolated.stderr
        let privilegedDiagnostic = privileged.stderr.isEmpty ? privileged.stdout : privileged.stderr
        return (nil, "\(failureDetail(prefix: "GUI focused text input (System-app host AX fast path)", code: isolated.code, diagnostic: isolatedDiagnostic))；root fallback：\(failureDetail(prefix: "GUI focused text input (persona-99 passive fallback)", code: privileged.code, diagnostic: privilegedDiagnostic))")
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
        // Root must overwrite this app-owned inode in place. Keep the transient screenshot private
        // to the mobile owner while still allowing the privileged helper to write it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let result = run(["gui-screenshot-file", outputURL.path], privilege: .root, timeout: 6)
        guard let data = try? Data(contentsOf: outputURL, options: [.mappedIfSafe]),
              GUIAutomationPayloadPolicy.isValidScreenshotJPEG(data) else {
            if result.code != 0 {
                return (nil, failureDetail(prefix: "GUI screenshot", code: result.code, diagnostic: result.diagnostic))
            }
            return (nil, "GUI screenshot helper 返回成功，但 tmp 文件不是有效的 bounded JPEG；已按 fail-closed 处理。")
        }
        if result.code == 0 {
            let routeDetail = result.diagnostic.isEmpty ? "" : " helper diagnostics: \(result.diagnostic)"
            return (data, "全局截图已通过独立 tmp JPEG 通道返回。\(routeDetail)")
        }
        if mayAcceptValidatedReadOnlyPayloadAfterParentTimeout(code: result.code, diagnostic: result.diagnostic) {
            return (data, "全局截图 JPEG 已完整写入并通过格式/大小校验；helper 随后仅在退出阶段触发父进程超时，因此保留已验证的只读截图。")
        }
        return (nil, failureDetail(prefix: "GUI screenshot", code: result.code, diagnostic: result.diagnostic))
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
        // `background-assert-start` writes its authoritative workerPID handshake to stderr before
        // hard-exiting. The generic run() intentionally discards stderr on code 0, which made Build
        // 113 create a real detached worker but then report "no worker PID" to the App. Every later
        // background transition therefore spawned another orphan worker. Preserve both streams for
        // this command and parse the success handshake from stderr (stdout remains accepted for old
        // helper compatibility).
        let result = runSeparated(["background-assert-start", String(targetPID)], privilege: .root, timeout: 4)
        let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
        guard result.code == 0 else {
            return (nil, failureDetail(prefix: "后台 assertion worker", code: result.code, diagnostic: diagnostic))
        }
        let marker = "workerPID="
        guard let range = diagnostic.range(of: marker) else {
            return (nil, "后台 assertion worker 已返回成功，但没有提供 worker PID；按 fail-closed 处理。")
        }
        let suffix = diagnostic[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        guard let workerPID = Int32(digits), workerPID > 1 else {
            return (nil, "后台 assertion worker PID 无法解析；按 fail-closed 处理。")
        }
        return (workerPID, diagnostic)
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

public actor IOSAppResolver: AppContainerResolving, AppIntrospectionProviding, AppEnumerationCapabilityProviding, AppUninstallCapabilityProviding, RootHelperCapabilityProviding, IPAInstallationCapabilityProviding, PrivilegedFilesystemCapabilityProviding, AppLifecycleCapabilityProviding {
    private var cachedApps: [ResourceNode] = []
    private var bundlePaths: [String: String] = [:]
    private var containerPaths: [String: String] = [:]
    private var appIndexNeedsRefresh = true
    private var failedIndexRetryAfter: Date?
    private var negativeBundleIDs: Set<String> = []
    private var unregisteredBundleIDs: Set<String> = []
    private var enumerationProven = false
    private var hasLastKnownGoodCrossAppIndex = false
    private var enumerationDetail = "尚未检测已安装 App 枚举能力。"
    private var uninstallDetail = "尚未检测 App 卸载后端。"
    private var pendingUninstallBundleID: String?
    private var cachedIntrospection: [String: AppStaticIntrospection] = [:]
    private let diagnosticLogger: DiagnosticLogStore?

    public init(diagnosticLogger: DiagnosticLogStore? = nil) {
        self.diagnosticLogger = diagnosticLogger
    }

    public func startupSafeApps() -> [ResourceNode] {
        enumerationProven = false
        hasLastKnownGoodCrossAppIndex = false
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

    public func cachedVersion(for bundleID: String) -> String? {
        cachedApps.first(where: { $0.ownerBundleID == bundleID })?.metadata["version"]
    }

    public func cachedDisplayName(for bundleID: String) -> String? {
        cachedApps.first(where: { $0.ownerBundleID == bundleID })?.displayName
    }

    public func appIntrospection(bundleID: String) async -> AppStaticIntrospection? {
        let indexedVersion = cachedVersion(for: bundleID)
        if let cached = cachedIntrospection[bundleID],
           let indexedVersion,
           cached.version == indexedVersion,
           bundlePaths[bundleID] == cached.bundlePath {
            return cached
        }
        let result = EmbeddedRootHelper.appIntrospection(bundleID: bundleID)
        guard let payload = result.payload else {
            try? await diagnosticLogger?.log(
                level: .warning,
                subsystem: "app-introspection",
                action: "metadata",
                result: "unavailable",
                diagnostic: result.detail,
                metadata: ["bundleID": bundleID]
            )
            return nil
        }
        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "app-introspection",
            action: "metadata",
            result: "completed",
            diagnostic: result.detail,
            metadata: [
                "bundleID": bundleID,
                "urlSchemeCount": String(payload.urlSchemes.count),
                "utiCount": String(payload.utTypes.count),
                "extensionCount": String(payload.extensions.count),
                "frameworkCount": String(payload.frameworks.count),
                "localDataAliasCount": String(payload.localData.count)
            ]
        )
        let introspection = AppStaticIntrospection(
            bundleID: payload.bundleID,
            displayName: payload.displayName,
            version: payload.version,
            build: payload.build,
            bundlePath: payload.bundlePath,
            dataContainerPath: payload.dataContainerPath,
            executable: payload.executable,
            urlSchemes: payload.urlSchemes,
            documentTypes: payload.documentTypes,
            utTypes: payload.utTypes,
            extensions: payload.extensions,
            frameworks: payload.frameworks,
            appGroups: payload.appGroups,
            localData: payload.localData
        )
        cachedIntrospection[bundleID] = introspection
        if !introspection.bundlePath.isEmpty { bundlePaths[bundleID] = introspection.bundlePath }
        if !introspection.dataContainerPath.isEmpty { containerPaths[bundleID] = introspection.dataContainerPath }
        negativeBundleIDs.remove(bundleID)
        return introspection
    }

    public func bundlePath(for bundleID: String) async -> String? {
        if bundleID == Bundle.main.bundleIdentifier { return bundlePaths[bundleID] ?? Bundle.main.bundleURL.path }
        if shouldRefreshIndex() { refresh() }
        if let value = bundlePaths[bundleID] { return value }

        // A full installed-App inventory is useful for discovery, but it is not a prerequisite for
        // an exact Bundle-ID lookup. Detached TrollStore helpers can occasionally lose the broad
        // LaunchServices enumeration view while an exact LSApplicationProxy lookup still resolves
        // the requested App correctly. Reuse the bounded single-App introspection path before
        // concluding that a known target such as WeChat is absent.
        if let exact = await appIntrospection(bundleID: bundleID), !exact.bundlePath.isEmpty {
            return exact.bundlePath
        }

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

        // Exact container resolution stays available even when broad installed-App enumeration is
        // temporarily degraded. The single-App helper verifies the current Bundle ID and returns the
        // current container UUID dynamically, so no historical UUID path is treated as identity.
        if let exact = await appIntrospection(bundleID: bundleID), !exact.dataContainerPath.isEmpty {
            return exact.dataContainerPath
        }

        guard enumerationProven, !negativeBundleIDs.contains(bundleID) else { return nil }
        refresh()
        if let value = containerPaths[bundleID] { return value }
        if bundlePaths[bundleID] == nil { negativeBundleIDs.insert(bundleID) }
        return nil
    }

    public func canEnumerateInstalledApps() async -> Bool {
        // Capability/status reads must not start a second broad scan. Callers such as apps.list
        // first obtain installedApps(), which is the single place allowed to perform the necessary
        // refresh for that read. This method only reports whether that completed refresh earned
        // fresh cross-App authority.
        return enumerationProven
    }

    public func canUseInstalledAppIndex() async -> Bool {
        // Same one-refresh rule as above: report whether the current in-memory snapshot is usable
        // for read-only discovery, including a retained last-known-good cross-App index.
        return enumerationProven || hasLastKnownGoodCrossAppIndex
    }

    public func installedAppEnumerationDetail() async -> String {
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

    public func ipaInstallationCapability() async -> RootHelperCapabilitySnapshot {
        let snapshot = EmbeddedRootHelper.ipaInstallCapability()
        try? await diagnosticLogger?.log(
            level: snapshot.available ? .info : .warning,
            subsystem: "root-helper",
            action: "ipa-install-capability",
            result: snapshot.available ? "available" : "device_validation_required",
            diagnostic: snapshot.detail
        )
        return snapshot
    }

    public func installIPA(path: String, bundleID: String, build: String) async -> (success: Bool, detail: String) {
        let outcome = EmbeddedRootHelper.installIPA(path: path, bundleID: bundleID, build: build)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "root-helper",
            action: "ipa-install",
            result: outcome.success ? "installed_verified" : "failed",
            diagnostic: outcome.detail,
            metadata: ["bundleID": bundleID, "build": build]
        )
        if outcome.success {
            // The app index is a rebuildable discovery cache. Force its next reader to observe the
            // newly installed bundle rather than serving the pre-install path/version snapshot.
            appIndexNeedsRefresh = true
            failedIndexRetryAfter = nil
            negativeBundleIDs.remove(bundleID)
            cachedIntrospection.removeValue(forKey: bundleID)
        }
        return outcome
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
        // Build 110 proved that asking LaunchServices a no-target capability question can block for
        // the entire helper watchdog even though exact app launches remain independently testable.
        // Keep the capability deferred and let the exact bundle-scoped operation self-validate.
        return AppLifecycleCapabilitySnapshot(
            available: false,
            detail: "Launch capability uses exact-operation self-validation; the no-target LaunchServices probe is intentionally disabled because it can block on this TrollStore runtime."
        )
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

    public func launchApplication(bundleID: String) async -> (accepted: Bool, foregroundVerified: Bool, detail: String) {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else {
            return (false, false, "目标 Bundle ID 无效，或目标是 Cloud Code 自身。")
        }
        // Do not run the old no-target launch capability probe here. The exact helper call below
        // validates installation state, dispatch acceptance and foreground state for this bundle.
        let helperOutcome = EmbeddedRootHelper.launch(bundleID: bundleID)
        let outcome = (accepted: helperOutcome.accepted, foregroundVerified: helperOutcome.foregroundVerified, detail: helperOutcome.detail)
        var metadata = ["bundleID": bundleID, "foregroundVerified": outcome.foregroundVerified ? "true" : "false"]
        if let path = bundlePaths[bundleID] { metadata["bundlePath"] = path }
        try? await diagnosticLogger?.log(
            level: outcome.accepted ? .info : .error,
            subsystem: "root-helper",
            action: "launch",
            result: outcome.accepted ? (outcome.foregroundVerified ? "verified" : "accepted_unverified") : "rejected",
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

        // A manual capability refresh is advisory discovery, not authority to erase a previously
        // verified installed-App index. Build 107 cleared the last-known-good cache before running
        // the helper; when the helper emitted a complete list but then hit its parent timeout, the
        // resolver collapsed to Cloud Code-only and subsequently reported real apps such as WeChat
        // as missing. Preserve the previous cross-app snapshot until a new snapshot is fully proven.
        let previousApps = cachedApps
        let previousBundlePaths = bundlePaths
        let previousContainerPaths = containerPaths
        let previousUnregisteredBundleIDs = unregisteredBundleIDs
        let ownBundleID = Bundle.main.bundleIdentifier
        let hadLastKnownGoodCrossAppIndex = hasLastKnownGoodCrossAppIndex && previousApps.contains {
            $0.ownerBundleID != nil && $0.ownerBundleID != ownBundleID
        }
        // Every refresh must earn fresh authority again. A retained last-known-good index remains
        // usable only for read-only discovery and exact routing hints.
        enumerationProven = false

        enumerationDetail = "正在根据本次 helper 隔离探测刷新已安装 App 索引。"
        uninstallDetail = "正在根据本次 helper 隔离探测重新判断卸载后端。"

        let isolated = EmbeddedRootHelper.enumerateInstalledApps()
        guard let payload = isolated.payload, !payload.apps.isEmpty else {
            failedIndexRetryAfter = Date().addingTimeInterval(30)
            if hadLastKnownGoodCrossAppIndex {
                cachedApps = previousApps
                bundlePaths = previousBundlePaths
                containerPaths = previousContainerPaths
                unregisteredBundleIDs = previousUnregisteredBundleIDs
                hasLastKnownGoodCrossAppIndex = true
                enumerationDetail = "本次重新检测失败；继续保留最近一次已验证的跨 App 内存索引，不把临时 helper 故障解释成 App 不存在。失败详情：\(isolated.detail.prefix(1200))。30 秒后才允许再次做全量枚举；当前枚举权威状态保持未验证，卸载/停止等状态改变操作不能使用这份旧索引作为授权依据。"
                uninstallDetail = "本次索引刷新失败；保留最近一次只读 App 索引。任何卸载仍必须重新通过精确安装状态和卸载后端验证。"
            } else {
                enumerationProven = false
                hasLastKnownGoodCrossAppIndex = false
                enumerationDetail = isolated.detail + " 失败结果会缓存 30 秒，避免模型循环触发全量枚举。"
                cachedApps = fallbackOwnApp()
                bundlePaths = Dictionary(uniqueKeysWithValues: cachedApps.compactMap { node in
                    guard let bundleID = node.ownerBundleID, let path = node.resolvedPath else { return nil }
                    return (bundleID, path)
                })
                containerPaths = [:]
                if let ownBundleID = Bundle.main.bundleIdentifier {
                    containerPaths[ownBundleID] = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
                }
                unregisteredBundleIDs.removeAll()
            }
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
        let crossAppCount = parsedApps.filter { $0.ownerBundleID != nil && $0.ownerBundleID != ownBundleID }.count
        guard crossAppCount > 0 else {
            failedIndexRetryAfter = Date().addingTimeInterval(30)
            if hadLastKnownGoodCrossAppIndex {
                cachedApps = previousApps
                bundlePaths = previousBundlePaths
                containerPaths = previousContainerPaths
                unregisteredBundleIDs = previousUnregisteredBundleIDs
                hasLastKnownGoodCrossAppIndex = true
                enumerationDetail = "\(payload.backend) 本次只返回 Cloud Code 自身或无法解析的记录；未覆盖最近一次已验证的跨 App 只读索引。当前枚举权威状态保持未验证，30 秒后允许重试。"
                uninstallDetail = "本次索引刷新未建立新的跨 App 权威快照；旧索引仅供只读发现，卸载仍要求新的设备验证。"
            } else {
                cachedApps = fallbackOwnApp()
                bundlePaths = Dictionary(uniqueKeysWithValues: cachedApps.compactMap { node in
                    guard let bundleID = node.ownerBundleID, let path = node.resolvedPath else { return nil }
                    return (bundleID, path)
                })
                containerPaths = [:]
                if let ownBundleID = Bundle.main.bundleIdentifier {
                    containerPaths[ownBundleID] = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
                }
                unregisteredBundleIDs.removeAll()
                hasLastKnownGoodCrossAppIndex = false
                enumerationDetail = "\(payload.backend) helper 只返回 Cloud Code 自身或无法解析的记录；跨 App 枚举未通过。失败结果缓存 30 秒，避免同一任务反复触发慢枚举。"
            }
            return
        }

        enumerationProven = true
        hasLastKnownGoodCrossAppIndex = true
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

public struct IOSPrivateAppExecutor: DeferredCapabilitySelfValidatingToolExecutor, Sendable {
    public let route: AppExecutionRoute = .privateFramework
    private let appResolver: IOSAppResolver
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting
    private let audit: AuditLogStore
    private let resourceIndex: ProgressiveResourceIndex?
    private let appKnowledgeRegistry: AppKnowledgeRegistry?
    private let ipaService: IPAService

    public init(
        appResolver: IOSAppResolver,
        policy: PolicyEngine,
        approval: ApprovalRequesting,
        audit: AuditLogStore,
        resourceIndex: ProgressiveResourceIndex? = nil,
        appKnowledgeRegistry: AppKnowledgeRegistry? = nil,
        ipaService: IPAService = IPAService()
    ) {
        self.appResolver = appResolver
        self.policy = policy
        self.approval = approval
        self.audit = audit
        self.resourceIndex = resourceIndex
        self.appKnowledgeRegistry = appKnowledgeRegistry
        self.ipaService = ipaService
    }

    public func allowsDeferredCapabilityAttempt(
        _ capabilityIDs: [String],
        for tool: ToolDescriptor,
        capabilities: CapabilityProfile
    ) async -> Bool {
        guard capabilityIDs.count == 1, let capabilityID = capabilityIDs.first,
              capabilities.status(capabilityID) == .deviceValidationRequired else { return false }
        switch tool.name {
        case "apps.launch": return capabilityID == "apps.launch"
        case "apps.terminate": return capabilityID == "apps.terminate"
        case "apps.uninstall": return capabilityID == "apps.uninstall"
        case "ipa.install": return capabilityID == "ipa.install"
        default: return false
        }
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        switch tool.name {
        case "apps.launch":
            let status = capabilities.status("apps.launch")
            return status == .available || status == .deviceValidationRequired
        case "apps.terminate":
            let status = capabilities.status("apps.terminate")
            return status == .available || status == .deviceValidationRequired
        case "apps.uninstall":
            let status = capabilities.status("apps.uninstall")
            return status == .available || status == .deviceValidationRequired
        case "ipa.install":
            let status = capabilities.status("ipa.install")
            return status == .available || status == .deviceValidationRequired
        default: return false
        }
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        if call.name == "ipa.install" {
            guard let rawPath = call.arguments["path"], !rawPath.isEmpty else {
                throw ToolRouterError.noExecutionRoute("ipa.install requires path")
            }
            let target = URL(fileURLWithPath: rawPath).standardizedFileURL
            let inspection = try ipaService.inspect(target, allowedRoot: context.allowedRoot)
            guard let bundleID = inspection.bundleIdentifier, Self.isValidBundleIdentifier(bundleID) else {
                throw ToolRouterError.noExecutionRoute("IPA does not contain a valid bundle identifier")
            }
            let build = inspection.build ?? ""
            guard !build.isEmpty else {
                throw ToolRouterError.noExecutionRoute("IPA does not contain CFBundleVersion; refusing an unverifiable self/update install")
            }

            let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: target.path)
            if decision == .deny { throw TransactionError.confirmationDenied }
            if decision == .requireConfirmation {
                let preview = ApprovalPreview(
                    title: bundleID == Bundle.main.bundleIdentifier ? "安装 Cloud Code 更新" : "安装 IPA",
                    target: "\(bundleID) · build \(build)",
                    reason: "TrollStore 将对该 IPA 执行 CoreTrust/ldid 签名处理并写入系统 App 安装状态。",
                    plan: ["检查 IPA 的 Bundle/Build 和归档结构", "通过受限 root helper 调用已安装 TrollStore 的 trollstorehelper", "重新读取安装后的 Bundle ID 与 Build，只有完全匹配才判定成功"],
                    risk: descriptor.risk
                )
                guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
            }

            let capability = await appResolver.ipaInstallationCapability()
            guard capability.available else {
                throw ToolRouterError.noExecutionRoute("ipa.install device validation failed: \(capability.detail)")
            }
            let outcome = await appResolver.installIPA(path: target.path, bundleID: bundleID, build: build)
            try await audit.append(AuditEvent(
                sessionID: call.sessionID,
                toolCallID: call.id,
                action: call.name,
                target: target.path,
                risk: descriptor.risk,
                result: outcome.success ? "installed_verified" : "install_failed",
                detail: ["bundleID": bundleID, "build": build, "diagnostic": outcome.detail]
            ))
            return ToolResult(
                toolCallID: call.id,
                success: outcome.success,
                summary: outcome.success
                    ? "已通过 TrollStore 安装并验证 \(bundleID) build \(build)"
                    : "IPA 安装失败：\(outcome.detail)",
                payload: [
                    "path": target.path,
                    "bundleId": bundleID,
                    "version": inspection.version ?? "",
                    "build": build,
                    "selfUpdate": bundleID == Bundle.main.bundleIdentifier ? "true" : "false",
                    "diagnostic": outcome.detail
                ],
                verification: VerificationResult(
                    passed: outcome.success,
                    checks: ["IPA 元数据和归档结构通过本地检查", "可信 TrollStore helper 完成签名/安装", "安装后 Bundle ID 与 CFBundleVersion 和 IPA 完全匹配"],
                    failures: outcome.success ? [] : [outcome.detail]
                )
            )
        }

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
            let launchStartedAt = Date()
            let outcome = await appResolver.launchApplication(bundleID: bundleID)
            let launchLatencyMS = max(0, Int(Date().timeIntervalSince(launchStartedAt) * 1_000))
            try await audit.append(AuditEvent(
                sessionID: call.sessionID,
                toolCallID: call.id,
                action: call.name,
                target: bundleID,
                risk: descriptor.risk,
                result: outcome.accepted ? (outcome.foregroundVerified ? "launch_verified" : "launch_accepted_unverified") : "launch_rejected",
                detail: ["diagnostic": outcome.detail, "foregroundVerified": outcome.foregroundVerified ? "true" : "false"]
            ))
            let version = await appResolver.cachedVersion(for: bundleID) ?? ""
            // Learn only from a semantically verified foreground transition, or from an outright
            // rejected launch. "Accepted but foreground unverified" is deliberately not training
            // evidence because dispatch acceptance is not proof that open_app succeeded.
            if outcome.foregroundVerified || !outcome.accepted {
                let environment = AppActionEnvironment(
                    appVersion: version.isEmpty ? nil : version,
                    iOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    deviceClass: nil
                )
                try? await appKnowledgeRegistry?.recordActionOutcome(
                    bundleID: bundleID,
                    semanticAction: "open_app",
                    route: .privateFramework,
                    environment: environment,
                    success: outcome.foregroundVerified,
                    latencyMS: launchLatencyMS
                )
            }
            return ToolResult(
                toolCallID: call.id,
                success: outcome.accepted,
                summary: outcome.accepted
                    ? (outcome.foregroundVerified ? "已启动 \(bundleID) 并验证前台" : "已派发启动 \(bundleID)；前台状态待下一次截图确认")
                    : "启动失败：\(outcome.detail)",
                payload: [
                    "bundleId": bundleID,
                    "detail": outcome.detail,
                    "version": version,
                    "foregroundVerified": outcome.foregroundVerified ? "true" : "false",
                    "effectVerification": outcome.foregroundVerified ? "verified" : "screenshot_required"
                ],
                verification: VerificationResult(
                    passed: outcome.foregroundVerified,
                    checks: outcome.foregroundVerified ? ["目标 App 已由有界系统启动路由确认进入前台"] : ["系统已接受目标 App 启动请求"],
                    failures: outcome.accepted && !outcome.foregroundVerified ? ["前台 Bundle ID 无法可靠读取；需要立即截图确认当前界面"] : (outcome.accepted ? [] : [outcome.detail])
                )
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
        switch outcome {
        case .removed, .removedWithResidualData(_):
            try? await resourceIndex?.invalidate(ownerBundleID: bundleID)
        case .rejected(_), .verificationTimedOut(_):
            break
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
    private let appKnowledgeRegistry: AppKnowledgeRegistry
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting

    public init(appKnowledgeRegistry: AppKnowledgeRegistry, policy: PolicyEngine, approval: ApprovalRequesting) {
        self.appKnowledgeRegistry = appKnowledgeRegistry
        self.policy = policy
        self.approval = approval
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name == "apps.openURL"
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard call.name == "apps.openURL" else { throw ToolRouterError.noExecutionRoute(call.name) }
        guard let bundleID = call.arguments["bundleId"], Self.isValidBundleIdentifier(bundleID),
              let rawURL = call.arguments["url"], rawURL.utf8.count <= 4_096,
              let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              url.user == nil, url.password == nil else {
            throw ToolRouterError.noExecutionRoute("apps.openURL requires a bounded URL without embedded credentials and a valid target bundleId")
        }

        let knowledge = await appKnowledgeRegistry.knowledge(for: bundleID)
        let discoveredScheme = knowledge?.urlSchemes.contains(where: { $0.caseInsensitiveCompare(scheme) == .orderedSame }) == true
        let exactUserProvided = context.currentUserRequest?.contains(rawURL) == true
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rootSchemeOnly = discoveredScheme
            && (components?.host?.isEmpty ?? true)
            && (components?.path.isEmpty ?? true)
            && components?.query == nil
            && components?.fragment == nil
        let sanitized = Self.sanitizedURLString(url)
        let knownPage = components?.query == nil && components?.fragment == nil
            && (knowledge?.knownPages.contains(where: { Self.sanitizedURLString(URL(string: $0)) == sanitized }) == true)
        guard exactUserProvided || rootSchemeOnly || knownPage else {
            throw ToolRouterError.noExecutionRoute("Deep link rejected: only an exact user-provided URL, a discovered root URL scheme, or a previously validated AppKnowledge page may execute. Provider-invented deep-link paths are not allowed.")
        }

        let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: sanitized)
        if decision == .deny { throw TransactionError.confirmationDenied }
        if decision == .requireConfirmation {
            let preview = ApprovalPreview(
                title: "打开 App 链接",
                target: sanitized,
                reason: "Deep link 会改变目标 App 的前台页面；只允许已发现/已验证或用户明确提供的 URL。",
                plan: ["验证 URL 来源", "调用现有系统 URL 路由", "验证目标 App 成为前台", "目标页面语义仍由后续观察确认"],
                risk: descriptor.risk
            )
            guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
        }

        let startedAt = Date()
        let accepted = await Self.openSystemURL(url)
        let foreground = accepted
            ? EmbeddedRootHelper.verifyFrontmost(bundleID: bundleID)
            : (verified: false, detail: "UIApplication.open rejected the URL")
        let latencyMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let environment = AppActionEnvironment(
            appVersion: knowledge?.appVersion,
            iOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            deviceClass: nil
        )
        try? await appKnowledgeRegistry.recordActionOutcome(
            bundleID: bundleID,
            semanticAction: "open_url",
            route: .urlScheme,
            environment: environment,
            success: foreground.verified,
            latencyMS: latencyMS
        )
        let verification = VerificationResult(
            passed: foreground.verified,
            checks: foreground.verified ? ["UIApplication.open 接受 URL", "目标 Bundle 已验证成为前台"] : (accepted ? ["UIApplication.open 接受 URL"] : []),
            failures: foreground.verified ? [] : [foreground.detail]
        )
        return ToolResult(
            toolCallID: call.id,
            success: foreground.verified,
            summary: foreground.verified
                ? "URL 路由已打开目标 App；具体目标页面仍需新鲜观察确认"
                : "URL 路由未能验证目标 App 前台：\(foreground.detail)",
            payload: [
                "bundleId": bundleID,
                "url": sanitized,
                "accepted": accepted ? "true" : "false",
                "foregroundVerified": foreground.verified ? "true" : "false",
                "effectVerification": foreground.verified ? "target_surface_observation_required" : "failed"
            ],
            verification: verification
        )
    }

    private static func openSystemURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                UIApplication.shared.open(url, options: [:]) { accepted in
                    continuation.resume(returning: accepted)
                }
            }
        }
    }

    private static func sanitizedURLString(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? ""
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

private enum FileSharePresentationError: Error {
    case appNotActive
    case noPresenter
    case fileTooLarge(Int64)
    case notRegularFile
}

/// App-layer bridge for a real iOS Share Sheet. This executor deliberately stops at presentation:
/// choosing WeChat/another target, choosing a recipient, committing the send, and verifying the
/// target App state remain separate GUI-authority actions.
public struct FileShareExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .structuredTool
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting
    private let maximumBytes: Int64 = 512 * 1024 * 1024

    public init(policy: PolicyEngine, approval: ApprovalRequesting) {
        self.policy = policy
        self.approval = approval
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name == "files.share" && capabilities.status("native.files") == .available
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard call.name == "files.share", let rawPath = call.arguments["path"], !rawPath.isEmpty else {
            throw ToolRouterError.noExecutionRoute("files.share requires path")
        }
        let target = try PathGuard().validate(
            target: URL(fileURLWithPath: rawPath),
            allowedRoot: context.allowedRoot,
            rejectSymlink: true
        )
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw FileSharePresentationError.notRegularFile }
        let byteSize = Int64(values.fileSize ?? 0)
        guard byteSize <= maximumBytes else { throw FileSharePresentationError.fileTooLarge(byteSize) }

        let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: target.path)
        if decision == .deny { throw TransactionError.confirmationDenied }
        if decision == .requireConfirmation {
            let preview = ApprovalPreview(
                title: "打开文件分享",
                target: target.lastPathComponent,
                reason: "这一步只会打开 iOS Share Sheet；不会把文件自动发送给任何联系人。后续选择目标 App、收件人和最终发送仍需真实 UI 操作与结果验证。",
                plan: ["重新校验本地文件路径/类型/大小", "打开系统 Share Sheet", "停止在分享面板，不宣称文件已经发送"],
                risk: descriptor.risk
            )
            guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
        }

        let presented = try await Self.presentShareSheet(for: target)
        return ToolResult(
            toolCallID: call.id,
            success: presented,
            summary: presented
                ? "已打开系统 Share Sheet；文件尚未发送，后续必须在目标 App 中选择收件人并验证真实发送结果。"
                : "系统 Share Sheet 未能确认呈现。",
            payload: [
                "path": target.path,
                "filename": target.lastPathComponent,
                "byteSize": String(byteSize),
                "shareSheetPresented": presented ? "true" : "false",
                "businessActionCompleted": "false",
                "effectVerification": "share_sheet_presented_only"
            ],
            verification: VerificationResult(
                passed: presented,
                checks: presented ? ["本地文件重新校验通过", "系统 Share Sheet 已呈现"] : ["本地文件重新校验通过"],
                failures: presented ? [] : ["Share Sheet presentation was not observed"]
            )
        )
    }

    @MainActor
    private static func presentShareSheet(for url: URL) throws -> Bool {
        guard UIApplication.shared.applicationState == .active else { throw FileSharePresentationError.appNotActive }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })
            ?? scenes.flatMap(\.windows).first(where: { !$0.isHidden && $0.alpha > 0 })
        guard var presenter = window?.rootViewController else { throw FileSharePresentationError.noPresenter }
        while let presented = presenter.presentedViewController { presenter = presented }
        if let navigation = presenter as? UINavigationController, let visible = navigation.visibleViewController {
            presenter = visible
        } else if let tab = presenter as? UITabBarController, let selected = tab.selectedViewController {
            presenter = selected
        }
        guard presenter.viewIfLoaded?.window != nil else { throw FileSharePresentationError.noPresenter }

        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
        return presenter.presentedViewController === sheet
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

private struct LocalSemanticTarget: Sendable {
    var centerX: Double
    var centerY: Double
    var searchableText: String
    var source: String
    var cacheHit: Bool
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
    private let appKnowledgeRegistry: AppKnowledgeRegistry?

    public init(
        backend: GUIAutomationBackend,
        policy: PolicyEngine,
        approval: ApprovalRequesting,
        attachmentRoot: URL? = nil,
        appKnowledgeRegistry: AppKnowledgeRegistry? = nil
    ) {
        self.backend = backend
        self.policy = policy
        self.approval = approval
        self.attachmentRoot = attachmentRoot
        self.elementCache = GUIElementLookupCache()
        self.appKnowledgeRegistry = appKnowledgeRegistry
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
        case "gui.focusComposerObserve":
            guard Self.requestLooksLikeMessaging(context.currentUserRequest ?? "") else {
                throw ToolRouterError.noExecutionRoute("focusComposerObserve is available only for an explicit messaging/chat request")
            }
        case "gui.findElement", "gui.waitForElement", "gui.tapElementObserve", "gui.typeElementObserve", "gui.tapTextObserve":
            guard let query = call.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty, query.utf8.count <= 512 else {
                throw ToolRouterError.noExecutionRoute("element query missing, empty, or exceeds 512 bytes")
            }
            if call.name != "gui.tapTextObserve", let role = call.arguments["role"], role.utf8.count > 128 {
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
        case "gui.feedSample":
            guard let direction = call.arguments["direction"], direction == "forward" || direction == "backward" else {
                throw ToolRouterError.noExecutionRoute("feedSample direction must be forward or backward")
            }
            guard let rawCount = Double(call.arguments["count"] ?? ""), rawCount.isFinite,
                  rawCount.rounded(.towardZero) == rawCount,
                  rawCount >= 2, rawCount <= 8 else {
                throw ToolRouterError.noExecutionRoute("feedSample count must be an integer from 2 through 8")
            }
            if let metric = call.arguments["metric"], !metric.isEmpty,
               LocalFeedMetric(rawValue: metric) == nil {
                throw ToolRouterError.noExecutionRoute("feedSample metric must be likeCount, commentCount, or shareCount")
            }
            if let selection = call.arguments["selection"], !selection.isEmpty,
               LocalFeedMetricSelection(rawValue: selection) == nil {
                throw ToolRouterError.noExecutionRoute("feedSample selection must be max or min")
            }
            if call.arguments["selection"] != nil, call.arguments["metric"] == nil {
                throw ToolRouterError.noExecutionRoute("feedSample selection requires a metric")
            }
            if let returnToSelected = call.arguments["returnToSelected"], returnToSelected != "true", returnToSelected != "false" {
                throw ToolRouterError.noExecutionRoute("feedSample returnToSelected must be boolean")
            }
        case "gui.swipe", "gui.swipeSequence", "gui.swipeObserve":
            let keys = ["fromX", "fromY", "toX", "toY"]
            let coordinates = keys.compactMap { Double(call.arguments[$0] ?? "") }
            let duration = GUIAutomationPayloadPolicy.normalizedSwipeDuration(call.arguments["duration"])
            guard coordinates.count == keys.count, coordinates.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000 }),
                  duration != nil else {
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
            let reusedForeground = call.arguments["_reuseVerifiedForeground"] == "true"
            let launchStartedAt = Date()
            let outcome = reusedForeground
                ? GUIOpenAppOutcome(accepted: true, foregroundVerified: true, detail: "current verified foreground reused")
                : try await backend.openApp(bundleID: bundle)
            let launchLatencyMS = max(0, Int(Date().timeIntervalSince(launchStartedAt) * 1_000))
            if !reusedForeground, outcome.foregroundVerified || !outcome.accepted {
                await recordActionOutcomeIfKnown(
                    bundleID: bundle,
                    semanticAction: "open_app",
                    success: outcome.foregroundVerified,
                    latencyMS: launchLatencyMS
                )
            }
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: outcome.foregroundVerified
                    ? "App launch accepted and target foreground verified"
                    : "App launch accepted; target foreground remains unverified",
                payload: [
                    "bundleId": bundle,
                    "foregroundVerified": outcome.foregroundVerified ? "true" : "false",
                    "effectVerification": outcome.foregroundVerified ? "verified" : "screenshot_required"
                ]
            )
        case "gui.openAppObserve":
            guard let bundle = call.arguments["bundleId"] else { throw ToolRouterError.noExecutionRoute("bundleId missing") }
            let reusedForeground = call.arguments["_reuseVerifiedForeground"] == "true"
            let reusedAcceptedLaunch = call.arguments["_reuseAcceptedLaunch"] == "true"
            let outcome: GUIOpenAppOutcome
            let launchStartedAt = Date()
            if reusedForeground {
                outcome = GUIOpenAppOutcome(accepted: true, foregroundVerified: true, detail: "current verified foreground reused")
            } else if reusedAcceptedLaunch {
                outcome = GUIOpenAppOutcome(accepted: true, foregroundVerified: false, detail: "prior accepted launch reused for fresh observation")
            } else {
                outcome = try await backend.openApp(bundleID: bundle)
            }
            let launchLatencyMS = max(0, Int(Date().timeIntervalSince(launchStartedAt) * 1_000))
            if !reusedForeground && !reusedAcceptedLaunch, outcome.foregroundVerified || !outcome.accepted {
                await recordActionOutcomeIfKnown(
                    bundleID: bundle,
                    semanticAction: "open_app",
                    success: outcome.foregroundVerified,
                    latencyMS: launchLatencyMS
                )
            }
            if !reusedForeground && !reusedAcceptedLaunch {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try Task.checkCancellation()
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            var payload: [String: String] = [
                "bundleId": bundle,
                "byteCount": String(data.count),
                "sha256": GUIAutomationPayloadPolicy.sha256Hex(data),
                "foregroundVerified": outcome.foregroundVerified ? "true" : "false",
                "effectVerification": outcome.foregroundVerified
                    ? "target_foreground_verified_screenshot_semantic_required"
                    : "launch_accepted_foreground_unverified_screenshot_semantic_required",
                "localObservation": "final_screenshot_attached"
            ]
            if outcome.foregroundVerified {
                await enrichWithLocalVision(&payload, screenshot: data)
            } else {
                // Foreground identity is not strong enough to authorize a semantic action, but the
                // freshly captured frame is still valuable as read-only local perception evidence.
                // Run OCR without dispatching any action and keep the result explicitly untrusted for
                // target identity. This avoids turning a flaky frontmost check into "OCR unavailable"
                // while preserving the fail-closed action boundary.
                await enrichWithLocalVision(&payload, screenshot: data)
                payload["perceptionAXAttempted"] = "false"
                payload["perceptionAXSucceeded"] = "false"
                payload["perceptionLocalSufficient"] = "false"
                payload["perceptionRemoteVisionRequired"] = "true"
                payload["perceptionFallbackReason"] = "foreground_unverified_local_ocr_observation_only"
                payload["providerVisualRoundTripAvoided"] = "0"
            }
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: outcome.foregroundVerified
                    ? "Target app became foreground and one fresh screenshot was captured locally for semantic planning."
                    : "App launch was accepted but foreground identity was not independently verified; a fresh screenshot was captured for bounded visual re-planning.",
                payload: payload,
                attachments: attachment.map { [$0] }
            )
        case "gui.tree":
            let axStartedAt = Date()
            let tree = try await backend.tree()
            let axLatencyMS = max(0, Int(Date().timeIntervalSince(axStartedAt) * 1_000))
            var payload: [String: String] = [
                "tree": ToolOutputEnvelope(trust: .untrustedData, source: "gui.tree", content: tree).promptSafeRepresentation,
                "perceptionClass": "accessibility_tree",
                "perceptionAXAttempted": "true",
                "perceptionAXSucceeded": "false",
                "perceptionOCRInvoked": "false",
                "perceptionOCRSucceeded": "false",
                "axStage": "direct_root_then_position_root_then_sampled_hit_test",
                "axLatencyMS": String(axLatencyMS)
            ]
            var semanticTreeUsable = false
            if let data = tree.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let scope = object["scope"] as? String ?? "unknown"
                let nodeCount = (object["nodeCount"] as? NSNumber)?.intValue ?? 0
                let semanticNodeCount = (object["semanticNodeCount"] as? NSNumber)?.intValue ?? 0
                let actionableNodeCount = (object["actionableNodeCount"] as? NSNumber)?.intValue ?? 0
                let bundleID = (object["bundleId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                semanticTreeUsable = nodeCount > 0 && semanticNodeCount > 0 && actionableNodeCount > 0
                payload["axScope"] = scope
                payload["axBackend"] = object["backend"] as? String ?? "unknown"
                payload["axNodeCount"] = String(nodeCount)
                payload["axSemanticNodeCount"] = String(semanticNodeCount)
                payload["axActionableNodeCount"] = String(actionableNodeCount)
                payload["axForegroundBundleID"] = bundleID
                payload["perceptionAXSucceeded"] = semanticTreeUsable ? "true" : "false"
                let fullApplicationScopes: Set<String> = ["full_application_tree_opportunistic", "full_application_tree_bounded"]
                let complete = semanticTreeUsable && fullApplicationScopes.contains(scope)
                payload["perceptionLocalSufficient"] = complete ? "true" : "false"
                payload["perceptionRemoteVisionRequired"] = complete ? "false" : "true"
                if !semanticTreeUsable {
                    payload["perceptionFallbackReason"] = "ax_transport_returned_semantically_empty_tree"
                } else {
                    payload["perceptionFallbackReason"] = complete ? "fresh_ax_application_tree" : "bounded_ax_sampled_semantics"
                }
                payload["providerVisualRoundTripAvoided"] = complete ? "1" : "0"
            } else {
                payload["axScope"] = "unknown"
                payload["perceptionLocalSufficient"] = "false"
                payload["perceptionRemoteVisionRequired"] = "true"
                payload["perceptionFallbackReason"] = "ax_tree_scope_unparsed"
                payload["providerVisualRoundTripAvoided"] = "0"
            }
            return ToolResult(
                toolCallID: call.id,
                success: semanticTreeUsable,
                summary: semanticTreeUsable ? "GUI tree read" : "AX transport responded without usable foreground semantics",
                payload: payload
            )
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
            payload["perceptionClass"] = "ax_element_action"
            payload["perceptionAXAttempted"] = "true"
            payload["perceptionAXSucceeded"] = "true"
            payload["perceptionOCRInvoked"] = "false"
            payload["perceptionOCRSucceeded"] = "false"
            payload["perceptionLocalSufficient"] = "false"
            payload["perceptionRemoteVisionRequired"] = "true"
            payload["perceptionFallbackReason"] = "ax_resolved_target_post_action_semantics_need_fresh_observation"
            payload["providerVisualRoundTripAvoided"] = "0"
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Unique accessibility element tapped locally; final screenshot attached for semantic verification.",
                payload: payload,
                attachments: attachment.map { [$0] }
            )
        case "gui.tapTextObserve":
            let baseline = try await backend.screenshot()
            let baselineSHA256 = GUIAutomationPayloadPolicy.sha256Hex(baseline)

            // Named visible text is exactly where AX and OCR should complement each other. Build 92
            // went straight to Vision here, so a background CoreVideo/CoreML allocation failure left
            // "文件传输助手" with no second local semantic path even when AX might expose it. Try one
            // bounded current-tree lookup first; TrollStoreGUIBackend already suppresses repeated AX
            // timeouts for the same foreground state. OCR remains the fallback and is not required for
            // the descriptor/capability gate, so devices without a usable AX backend still work.
            do {
                let axResolved = try await resolveElement(call)
                guard !Self.isProtectedElement(axResolved.match) else {
                    throw ToolRouterError.noExecutionRoute("protected/system-confirmation AX text cannot be automated")
                }
                try await backend.tap(x: axResolved.match.frame.centerX, y: axResolved.match.frame.centerY)
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                let data = try await backend.screenshot()
                let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
                var payload = elementPayload(axResolved.match, treeHash: axResolved.treeHash, cacheHit: axResolved.cacheHit)
                payload["baselineSHA256"] = baselineSHA256
                payload["sha256"] = GUIAutomationPayloadPolicy.sha256Hex(data)
                payload["effectVerification"] = "semantic_required"
                payload["localObservation"] = "final_screenshot_attached"
                payload["structuredPath"] = "ax_text_first"
                payload["perceptionClass"] = "ax_text_action"
                payload["perceptionAXAttempted"] = "true"
                payload["perceptionAXSucceeded"] = "true"
                payload["perceptionOCRInvoked"] = "false"
                payload["perceptionOCRSucceeded"] = "false"
                payload["perceptionLocalSufficient"] = "false"
                payload["perceptionRemoteVisionRequired"] = "true"
                payload["perceptionFallbackReason"] = "fresh_ax_unique_text_match_post_action_semantics_need_fresh_observation"
                payload["providerVisualRoundTripAvoided"] = "0"
                return ToolResult(
                    toolCallID: call.id,
                    success: true,
                    summary: "Unique visible text was resolved through the current accessibility tree and tapped locally; final screenshot attached for semantic verification.",
                    payload: payload,
                    attachments: attachment.map { [$0] }
                )
            } catch {
                // AX failure is expected on some third-party surfaces. Do not retry it here; continue
                // immediately to one OCR pass from the already-captured current frame.
            }

            var resolution = await resolveLocalVisionText(call, screenshot: baseline)
            if resolution.match == nil,
               resolution.observation.payload["localVisionPrecisionRecommended"] == "true" {
                resolution = await resolveLocalVisionText(call, screenshot: baseline, forcePrecise: true)
            }
            guard let resolved = resolution.match else {
                let attachment = try persistScreenshotAttachment(baseline, sessionID: call.sessionID)
                var payload: [String: String] = [
                    "sha256": baselineSHA256,
                    "baselineSHA256": baselineSHA256,
                    "effectVerification": "not_dispatched",
                    "localObservation": "baseline_screenshot_attached",
                    "perceptionClass": "ax_then_local_ocr_text_lookup",
                    "perceptionAXAttempted": "true",
                    "perceptionAXSucceeded": "false",
                    "perceptionAnchorCacheHit": "false",
                    "perceptionLocalSufficient": "false",
                    "perceptionRemoteVisionRequired": "true",
                    "perceptionFallbackReason": resolution.failureReason ?? "ocr_target_not_recognized",
                    "providerVisualRoundTripAvoided": "0"
                ]
                enrichWithLocalVision(&payload, observation: resolution.observation)
                payload["localVisionFailureClass"] = resolution.failureReason ?? "ocr_target_not_recognized"
                return ToolResult(
                    toolCallID: call.id,
                    success: false,
                    summary: resolution.failureSummary ?? "AX and local OCR did not produce one unique current-frame text target.",
                    payload: payload,
                    attachments: attachment.map { [$0] }
                )
            }
            guard !Self.isProtectedLocalVisionText(resolved.text) else {
                throw ToolRouterError.noExecutionRoute("protected/system-confirmation OCR text cannot be automated")
            }
            try await backend.tap(x: resolved.centerX, y: resolved.centerY)
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            var payload: [String: String] = [
                "matchedText": String(resolved.text.prefix(256)),
                "matchedConfidence": String(resolved.confidence),
                "x": String(resolved.x),
                "y": String(resolved.y),
                "width": String(resolved.width),
                "height": String(resolved.height),
                "centerX": String(resolved.centerX),
                "centerY": String(resolved.centerY),
                "baselineSHA256": baselineSHA256,
                "sha256": GUIAutomationPayloadPolicy.sha256Hex(data),
                "effectVerification": "semantic_required",
                "localObservation": "final_screenshot_attached",
                "perceptionClass": "ax_then_local_ocr_text_action",
                "perceptionAXAttempted": "true",
                "perceptionAXSucceeded": "false",
                "perceptionAnchorCacheHit": "false",
                "perceptionFallbackReason": "ax_unavailable_fresh_local_ocr_unique_text_match"
            ]
            await enrichWithLocalVision(&payload, screenshot: data)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "AX did not resolve the text, but one unique visible OCR label was resolved and tapped locally; final screenshot attached for semantic verification.",
                payload: payload,
                attachments: attachment.map { [$0] }
            )
        case "gui.focusComposerObserve":
            let baseline = try await backend.screenshot()
            guard let image = UIImage(data: baseline), image.size.width >= 100, image.size.height >= 200 else {
                throw ToolRouterError.noExecutionRoute("composer focus could not determine a valid current screen size")
            }
            let baselineSHA256 = GUIAutomationPayloadPolicy.sha256Hex(baseline)
            // The Provider never chooses this coordinate. This semantic micro-action owns one
            // conservative bottom-center candidate and verifies keyboard evidence before raw typing
            // is allowed. Side icons (voice/emoji/add) stay outside the center candidate.
            let focusX = Double(image.size.width * 0.50)
            let focusY = Double(image.size.height * 0.92)
            try await backend.tap(x: focusX, y: focusY)
            try await Task.sleep(nanoseconds: 350_000_000)
            try Task.checkCancellation()
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)

            // Prefer a structural focus proof before invoking Vision. On the real build-92 device,
            // Cloud Code is backgrounded while WeChat owns the keyboard; Vision frequently fails
            // there with CoreVideo/CoreML allocation errors even though AX can still expose the
            // focused text control. The probe intentionally returns no AXValue/text content.
            let axFocus = EmbeddedRootHelper.focusedTextInput()
            if let focused = axFocus.payload, focused.focusedTextInput {
                let payload: [String: String] = [
                    "baselineSHA256": baselineSHA256,
                    "sha256": GUIAutomationPayloadPolicy.sha256Hex(data),
                    "focusStrategy": "bounded_bottom_center_composer_candidate",
                    "focusX": String(focusX),
                    "focusY": String(focusY),
                    "composerFocusVerified": "true",
                    "keyboardLikely": "false",
                    "focusVerification": "ax_focused_text_input",
                    "focusedRole": String(focused.role.prefix(128)),
                    "effectVerification": "ax_focused_text_input_verified",
                    "localObservation": "final_screenshot_attached",
                    "perceptionClass": "semantic_composer_focus",
                    "perceptionAXAttempted": "true",
                    "perceptionAXSucceeded": "true",
                    "perceptionAnchorCacheHit": "false",
                    "perceptionOCRInvoked": "false",
                    "perceptionOCRSucceeded": "false",
                    "perceptionLocalSufficient": "true",
                    "perceptionRemoteVisionRequired": "false",
                    "perceptionFallbackReason": "ax_focused_text_input_verified_composer_focus",
                    "providerVisualRoundTripAvoided": "1"
                ]
                return ToolResult(
                    toolCallID: call.id,
                    success: true,
                    summary: "Chat composer focus was locally verified by a focused accessibility text-input element; OCR was not required.",
                    payload: payload,
                    attachments: attachment.map { [$0] }
                )
            }

            // Keyboard/composer verification is bottom-screen semantics. Restrict the first local
            // OCR pass to that region instead of paying for full-screen recognition. Vision ROI is
            // expressed in normalized lower-left coordinates internally; LocalVisionTextObservation
            // accepts top-left screen points and keeps all returned boxes in screen_points_top_left.
            let keyboardRegion = CGRect(
                x: 0,
                y: image.size.height * 0.42,
                width: image.size.width,
                height: image.size.height * 0.58
            )
            var observation = await LocalVisionTextObservation.observe(
                for: data,
                maximumElements: 48,
                regionInScreenPoints: keyboardRegion,
                requiresText: true
            )
            var screenHeight = Double(observation.payload["screenPointHeight"] ?? "") ?? Double(image.size.height)
            var keyboardLikely = LocalKeyboardHeuristic.isLikelyVisible(elements: observation.elements, screenHeight: screenHeight)
            if !keyboardLikely {
                observation = await LocalVisionTextObservation.observe(
                    for: data,
                    maximumElements: 48,
                    regionInScreenPoints: keyboardRegion,
                    requiresText: true,
                    forcePrecise: true
                )
                screenHeight = Double(observation.payload["screenPointHeight"] ?? "") ?? Double(image.size.height)
                keyboardLikely = LocalKeyboardHeuristic.isLikelyVisible(elements: observation.elements, screenHeight: screenHeight)
            }
            var payload: [String: String] = [
                "baselineSHA256": baselineSHA256,
                "sha256": GUIAutomationPayloadPolicy.sha256Hex(data),
                "focusStrategy": "bounded_bottom_center_composer_candidate",
                "focusX": String(focusX),
                "focusY": String(focusY),
                "composerFocusVerified": keyboardLikely ? "true" : "false",
                "keyboardLikely": keyboardLikely ? "true" : "false",
                "focusVerification": keyboardLikely ? "ocr_keyboard_heuristic" : "unverified",
                "effectVerification": keyboardLikely ? "local_keyboard_heuristic_passed" : "semantic_required",
                "localObservation": "final_screenshot_attached",
                "perceptionClass": "semantic_composer_focus",
                "perceptionAXAttempted": "true",
                "perceptionAXSucceeded": "false",
                "perceptionAnchorCacheHit": "false"
            ]
            enrichWithLocalVision(&payload, observation: observation)
            if keyboardLikely {
                payload["perceptionLocalSufficient"] = "true"
                payload["perceptionRemoteVisionRequired"] = "false"
                payload["perceptionFallbackReason"] = "ax_unavailable_local_keyboard_heuristic_verified_composer_focus"
                payload["providerVisualRoundTripAvoided"] = "1"
            } else {
                payload["perceptionLocalSufficient"] = "false"
                payload["perceptionRemoteVisionRequired"] = "true"
                payload["perceptionFallbackReason"] = "composer_focus_not_locally_verified"
                payload["providerVisualRoundTripAvoided"] = "0"
            }
            return ToolResult(
                toolCallID: call.id,
                success: keyboardLikely,
                summary: keyboardLikely
                    ? "AX did not prove text focus, but chat composer focus was locally verified by keyboard-like OCR evidence."
                    : "Composer candidate was tapped, but neither AX focus nor local keyboard evidence verified the composer; raw typing remains blocked.",
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
            payload["perceptionClass"] = "ax_element_input"
            payload["perceptionAXAttempted"] = "true"
            payload["perceptionAXSucceeded"] = "true"
            payload["perceptionOCRInvoked"] = "false"
            payload["perceptionOCRSucceeded"] = "false"
            payload["perceptionLocalSufficient"] = "false"
            payload["perceptionRemoteVisionRequired"] = "true"
            payload["perceptionFallbackReason"] = "ax_resolved_input_post_action_semantics_need_fresh_observation"
            payload["providerVisualRoundTripAvoided"] = "0"
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
            var payload: [String: String] = [
                "byteCount": String(data.count),
                "sha256": GUIAutomationPayloadPolicy.sha256Hex(data)
            ]
            await enrichWithLocalVision(&payload, screenshot: data)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "Screenshot captured with bounded on-device text observation when available",
                payload: payload,
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
            try await backend.swipe(fromX: Double(call.arguments["fromX"] ?? "0") ?? 0, fromY: Double(call.arguments["fromY"] ?? "0") ?? 0, toX: Double(call.arguments["toX"] ?? "0") ?? 0, toY: Double(call.arguments["toY"] ?? "0") ?? 0, duration: GUIAutomationPayloadPolicy.normalizedSwipeDuration(call.arguments["duration"]) ?? 0.3)
            return ToolResult(toolCallID: call.id, success: true, summary: "Swipe dispatched; foreground effect unverified", payload: ["effectVerification": "required"])
        case "gui.swipeSequence":
            return try await executeSwipeSequence(call)
        case "gui.feedSample":
            return try await executeFeedSample(call)
        case "gui.tapObserve", "gui.typeObserve", "gui.scrollObserve", "gui.swipeObserve":
            return try await executeActionObserve(call)
        case "gui.navigateBack":
            let baselineData = try await backend.screenshot()
            let baselineSHA256 = GUIAutomationPayloadPolicy.sha256Hex(baselineData)
            let strategy = call.arguments["strategy"] ?? ""
            try await backend.navigateBack(strategy: strategy)
            let data = try await backend.screenshot()
            let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID)
            var payload: [String: String] = [
                "baselineSHA256": baselineSHA256,
                "sha256": GUIAutomationPayloadPolicy.sha256Hex(data),
                "strategy": strategy,
                "effectVerification": "semantic_required",
                "localObservation": "final_screenshot_attached"
            ]
            await enrichWithLocalVision(&payload, screenshot: data)
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "iOS back/dismiss gesture changed the foreground frame; final screenshot attached for semantic return verification.",
                payload: payload,
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
        let duration = GUIAutomationPayloadPolicy.normalizedSwipeDuration(call.arguments["duration"]) ?? 0.3
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
        await enrichWithLocalVision(&payload, screenshot: latestScreenshot)
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

    private func executeFeedSample(_ call: ToolCall) async throws -> ToolResult {
        let count = Int(Double(call.arguments["count"] ?? "0") ?? 0)
        let direction = call.arguments["direction"] ?? "forward"
        let requestedMetric = call.arguments["metric"].flatMap(LocalFeedMetric.init(rawValue:))
        let requestedSelection = call.arguments["selection"].flatMap(LocalFeedMetricSelection.init(rawValue:))
        let returnToSelected = call.arguments["returnToSelected"].map { $0 == "true" } ?? (requestedMetric != nil && requestedSelection != nil)
        // Keep physical finger direction private to the executor. The provider only reasons in
        // semantic feed order (forward/backward), avoiding the common Chinese "往下刷" vs
        // "手指向上滑" ambiguity. Positive scroll delta means advancing the scroll/feed content;
        // the helper owns the inverse physical finger trajectory needed to produce that motion.
        let deltaY = direction == "forward" ? 600.0 : -600.0
        // Video pixels change continuously, so a whole-frame hash is not proof that the feed moved.
        // The physical scroll itself already occupies ~300 ms. A second fixed 950 ms pause made a
        // five-item scan spend several seconds doing nothing, even when the overlay was already
        // stable. Use a shorter bounded settle; incomplete semantic evidence still takes the slower
        // OCR/AX fallback below instead of making every successful sample pay the worst-case delay.
        let settleNanoseconds: UInt64 = 550_000_000
        let uncertainSettleRetryNanoseconds: UInt64 = 400_000_000

        var attachments: [ChatAttachment] = []
        var hashes: [String] = []
        var localVisionSamples: [[String: String]] = []
        var localElementSamples: [[LocalPerceptionTextElement]] = []
        var localScreenSamples: [LocalPerceptionScreenSize] = []
        var sampleIdentities: [String] = []
        var sampledCount = 0
        var stoppedAtSample: Int?
        var stoppedReason: String?
        var totalOCRLatencyMS = 0
        var successfulOCRSamples = 0
        var preciseMetricRegionSamples = 0
        var fullFrameOCRFallbackSamples = 0
        var axAttemptedSamples = 0
        var axSucceededSamples = 0
        var axSkippedLocalSufficientSamples = 0

        func captureSample() async throws -> (hash: String, identity: String?) {
            let data = try await backend.screenshot()
            let hash = GUIAutomationPayloadPolicy.sha256Hex(data)
            if let attachment = try persistScreenshotAttachment(data, sessionID: call.sessionID) {
                attachments.append(attachment)
            }
            hashes.append(hash)
            sampledCount += 1

            let image = UIImage(data: data)?.cgImage
            let imageScreenSize = LocalPerceptionScreenSize(
                width: Double(image?.width ?? 0),
                height: Double(image?.height ?? 0)
            )
            let metricRegion = requestedMetric.flatMap { _ in
                LocalFeedPerceptionPolicy.metricRegion(screenSize: imageScreenSize)
            }.map {
                CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.width), height: CGFloat($0.height))
            }

            // Metric sampling takes the precise recognizer over only the trailing action/count rail.
            // This is both cheaper and more accurate than full-screen accurate OCR: small decimal
            // counters occupy a much larger fraction of the cropped image (for example 21.0万),
            // which reduces dropped/reordered digits without making every generic OCR call precise.
            var observation = await LocalVisionTextObservation.observe(
                for: data,
                maximumElements: requestedMetric == nil ? 32 : 24,
                regionInScreenPoints: metricRegion,
                requiresText: requestedMetric != nil,
                forcePrecise: requestedMetric != nil && metricRegion != nil
            )
            if requestedMetric != nil && metricRegion != nil { preciseMetricRegionSamples += 1 }
            totalOCRLatencyMS += Int(observation.payload["localVisionLatencyMS"] ?? "0") ?? 0

            var screenSize = LocalPerceptionScreenSize(
                width: Double(observation.payload["screenPointWidth"] ?? "") ?? imageScreenSize.width,
                height: Double(observation.payload["screenPointHeight"] ?? "") ?? imageScreenSize.height
            )
            if screenSize.width <= 0 || screenSize.height <= 0 { screenSize = imageScreenSize }
            var ocrElements = observation.elements
            var ocrBackends = [observation.payload["localVisionBackend"] ?? "unknown"]
            var ocrStatuses = [observation.payload["localVisionOCR"] ?? "unavailable"]

            var localSufficient = LocalFeedPerceptionPolicy.observationIsSufficient(
                metric: requestedMetric,
                elements: ocrElements,
                screenSize: screenSize
            )
            if !localSufficient, metricRegion != nil {
                // The current app may not use a right-side metric rail, or the first crop may have
                // missed text during animation. Pay one full-frame *fast* OCR only for that sample.
                let fallback = await LocalVisionTextObservation.observe(
                    for: data,
                    maximumElements: 48,
                    requiresText: requestedMetric != nil,
                    forcePrecise: false
                )
                fullFrameOCRFallbackSamples += 1
                totalOCRLatencyMS += Int(fallback.payload["localVisionLatencyMS"] ?? "0") ?? 0
                ocrElements = LocalPerceptionFusion.merge(ax: ocrElements, ocr: fallback.elements)
                ocrBackends.append(fallback.payload["localVisionBackend"] ?? "unknown")
                ocrStatuses.append(fallback.payload["localVisionOCR"] ?? "unavailable")
                let fallbackWidth = Double(fallback.payload["screenPointWidth"] ?? "") ?? 0
                let fallbackHeight = Double(fallback.payload["screenPointHeight"] ?? "") ?? 0
                if fallbackWidth > 0, fallbackHeight > 0 {
                    screenSize = .init(width: fallbackWidth, height: fallbackHeight)
                }
                localSufficient = LocalFeedPerceptionPolicy.observationIsSufficient(
                    metric: requestedMetric,
                    elements: ocrElements,
                    screenSize: screenSize
                )
                observation = fallback
            }

            var axElements: [LocalPerceptionTextElement] = []
            var axStatus = "skipped_local_sufficient"
            if localSufficient {
                axSkippedLocalSufficientSamples += 1
            } else {
                // Full AX trees are the most expensive/fragile perception source on custom-drawn
                // video surfaces. Ask for one only after local OCR cannot prove this exact sample.
                axAttemptedSamples += 1
                axStatus = "unavailable"
                do {
                    let tree = try await backend.tree()
                    axElements = LocalAXTreeTextExtractor.extract(from: tree, maximumElements: 96)
                    if !axElements.isEmpty {
                        axSucceededSamples += 1
                        axStatus = "semantic_elements"
                    } else {
                        axStatus = "empty_tree"
                    }
                } catch {
                    axStatus = "unavailable"
                }
            }

            let fusedElements = LocalPerceptionFusion.merge(ax: axElements, ocr: ocrElements)
            localElementSamples.append(fusedElements)
            localScreenSamples.append(screenSize)
            let identity = LocalFeedIdentity.signature(elements: fusedElements, screenSize: screenSize)
            sampleIdentities.append(identity ?? "")
            if ocrStatuses.contains(where: { $0 == "recognized" || $0 == "available_empty" }) {
                successfulOCRSamples += 1
            }
            let encodedElements: String
            if let encoded = try? JSONEncoder().encode(Array(fusedElements.prefix(64))), encoded.count <= 12 * 1024 {
                encodedElements = String(data: encoded, encoding: .utf8) ?? "[]"
            } else {
                encodedElements = "[]"
            }
            localVisionSamples.append([
                "sample": String(sampledCount),
                "status": ocrStatuses.joined(separator: "+"),
                "text": String(fusedElements.map(\.text).joined(separator: " | ").prefix(1_600)),
                "elements": String(encodedElements.prefix(6_000)),
                "width": String(Int(screenSize.width)),
                "height": String(Int(screenSize.height)),
                "backend": ocrBackends.joined(separator: "+"),
                "region": metricRegion == nil ? "full_screen" : "metric_right_rail",
                "ax": axStatus,
                "semanticIdentity": identity.map { String($0.prefix(512)) } ?? ""
            ])
            return (hash, identity)
        }

        let baseline = try await captureSample()
        let baselineHash = baseline.hash
        var previousIdentity = baseline.identity
        if previousIdentity == nil {
            stoppedReason = "baseline_semantic_identity_unavailable"
        } else if count >= 2 {
            for sampleIndex in 2...count {
                try Task.checkCancellation()
                try await backend.scroll(deltaX: 0, deltaY: deltaY)
                try await Task.sleep(nanoseconds: settleNanoseconds)
                try Task.checkCancellation()
                let beforeAttachments = attachments.count
                let beforeHashes = hashes.count
                let beforeVision = localVisionSamples.count
                let beforeElements = localElementSamples.count
                let beforeScreens = localScreenSamples.count
                let beforeIdentities = sampleIdentities.count
                let beforeSampledCount = sampledCount
                let beforeOCRLatencyMS = totalOCRLatencyMS
                let beforeSuccessfulOCRSamples = successfulOCRSamples
                let beforePreciseMetricRegionSamples = preciseMetricRegionSamples
                let beforeFullFrameOCRFallbackSamples = fullFrameOCRFallbackSamples
                let beforeAXAttemptedSamples = axAttemptedSamples
                let beforeAXSucceededSamples = axSucceededSamples
                let beforeAXSkippedLocalSufficientSamples = axSkippedLocalSufficientSamples

                func rollbackCandidateCapture() {
                    if attachments.count > beforeAttachments { attachments.removeSubrange(beforeAttachments..<attachments.count) }
                    if hashes.count > beforeHashes { hashes.removeSubrange(beforeHashes..<hashes.count) }
                    if localVisionSamples.count > beforeVision { localVisionSamples.removeSubrange(beforeVision..<localVisionSamples.count) }
                    if localElementSamples.count > beforeElements { localElementSamples.removeSubrange(beforeElements..<localElementSamples.count) }
                    if localScreenSamples.count > beforeScreens { localScreenSamples.removeSubrange(beforeScreens..<localScreenSamples.count) }
                    if sampleIdentities.count > beforeIdentities { sampleIdentities.removeSubrange(beforeIdentities..<sampleIdentities.count) }
                    sampledCount = beforeSampledCount
                    totalOCRLatencyMS = beforeOCRLatencyMS
                    successfulOCRSamples = beforeSuccessfulOCRSamples
                    preciseMetricRegionSamples = beforePreciseMetricRegionSamples
                    fullFrameOCRFallbackSamples = beforeFullFrameOCRFallbackSamples
                    axAttemptedSamples = beforeAXAttemptedSamples
                    axSucceededSamples = beforeAXSucceededSamples
                    axSkippedLocalSufficientSamples = beforeAXSkippedLocalSufficientSamples
                }

                var candidate = try await captureSample()
                var semanticAdvanced = candidate.identity != nil && candidate.identity != previousIdentity
                if !semanticAdvanced {
                    // Do not make every item pay a one-second settle just because a slow-loading item
                    // occasionally needs it. Roll the uncertain observation back, grant that one item
                    // another 400 ms, then re-observe. Only the ambiguous path pays this retry.
                    rollbackCandidateCapture()
                    try await Task.sleep(nanoseconds: uncertainSettleRetryNanoseconds)
                    try Task.checkCancellation()
                    candidate = try await captureSample()
                    semanticAdvanced = candidate.identity != nil && candidate.identity != previousIdentity
                }
                if !semanticAdvanced {
                    stoppedAtSample = sampleIndex
                    stoppedReason = candidate.identity == nil ? "semantic_identity_unavailable" : "semantic_identity_unchanged"
                    rollbackCandidateCapture()
                    break
                }
                previousIdentity = candidate.identity
            }
        }

        let completed = sampledCount == count && stoppedAtSample == nil && stoppedReason == nil
        var payload: [String: String] = [
            "requestedCount": String(count),
            "sampledCount": String(sampledCount),
            "direction": direction,
            "sequenceCompleted": completed ? "true" : "false",
            "frameSHA256": hashes.joined(separator: ","),
            "baselineSHA256": baselineHash,
            "sha256": hashes.last ?? baselineHash,
            "settleMs": "550",
            "effectVerification": "semantic_review_required",
            "localObservation": "feed_samples_attached",
            "perceptionClass": "feed_sample",
            "perceptionAXAttempted": axAttemptedSamples > 0 ? "true" : "false",
            "perceptionAXSucceeded": axSucceededSamples > 0 ? "true" : "false",
            "perceptionAXSampleCount": String(axAttemptedSamples),
            "perceptionAXSuccessfulSampleCount": String(axSucceededSamples),
            "perceptionAXSkippedLocalSufficientSampleCount": String(axSkippedLocalSufficientSamples),
            "feedIdentityMode": "adaptive_precise_metric_roi_then_ocr_ax_fallback",
            "perceptionOCRInvoked": "true",
            "perceptionOCRPreciseMetricRegionSampleCount": String(preciseMetricRegionSamples),
            "perceptionOCRFullFrameFallbackSampleCount": String(fullFrameOCRFallbackSamples),
            "perceptionOCRSucceeded": successfulOCRSamples == sampledCount ? "true" : "false",
            "perceptionOCRLatencyMS": String(totalOCRLatencyMS),
            "perceptionLocalSufficient": "false",
            "perceptionRemoteVisionRequired": "true",
            "perceptionFallbackReason": requestedMetric == nil ? "no_local_metric_requested" : "local_metric_incomplete_or_ambiguous",
            "providerVisualRoundTripAvoided": "0"
        ]
        if let stoppedAtSample { payload["stoppedAtSample"] = String(stoppedAtSample) }
        if let stoppedReason { payload["stoppedReason"] = stoppedReason }
        if !sampleIdentities.isEmpty {
            payload["semanticIdentityCount"] = String(sampleIdentities.filter { !$0.isEmpty }.count)
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: localVisionSamples, options: []),
           encoded.count <= 48 * 1024,
           let json = String(data: encoded, encoding: .utf8) {
            payload["localVisionSamples"] = json
            payload["localVisionSampleCount"] = String(localVisionSamples.count)
        }

        var localMetricSelection: LocalFeedMetricSelectionResult?
        var lowConfidenceMetricEvidence = false
        if completed, let metric = requestedMetric, let selection = requestedSelection {
            localMetricSelection = LocalFeedMetricExtractor.select(
                metric: metric,
                selection: selection,
                samples: localElementSamples,
                screenSizes: localScreenSamples
            )
            if let candidate = localMetricSelection,
               !LocalFeedPerceptionPolicy.metricSelectionIsTrusted(candidate) {
                lowConfidenceMetricEvidence = true
                payload["localMetricConfidenceFloor"] = String(format: "%.3f", LocalFeedPerceptionPolicy.minimumTrustedMetricConfidence)
                payload["localMetricObservedConfidences"] = candidate.extractions
                    .map { String(format: "%.3f", $0.confidence) }
                    .joined(separator: ",")
                localMetricSelection = nil
            }
        }
        if let localMetricSelection {
            payload["localMetric"] = localMetricSelection.metric.rawValue
            payload["localMetricSelection"] = localMetricSelection.selection.rawValue
            payload["localMetricValues"] = localMetricSelection.values.map { String(format: "%.6f", $0) }.joined(separator: ",")
            payload["localMetricSelectedSample"] = String(localMetricSelection.selectedSample)
            payload["localMetricSelectedValue"] = String(format: "%.6f", localMetricSelection.selectedValue)
            payload["localMetricExtraction"] = "complete"

            var selectedReturnVerified = localMetricSelection.selectedSample == sampledCount
            if returnToSelected, localMetricSelection.selectedSample < sampledCount {
                let returnSteps = sampledCount - localMetricSelection.selectedSample
                let targetIdentity = sampleIdentities[localMetricSelection.selectedSample - 1]
                var completedReturnSteps = 0
                var returnFailureReason: String?

                // Returning to an already sampled item is a deterministic, reversible sequence.
                // Verifying every intermediate swipe previously repeated screenshot + OCR + AX and
                // multiplied latency. Dispatch the bounded return sequence, then verify the final
                // semantic identity once; a missed gesture still fails closed as a target mismatch.
                for _ in 0..<returnSteps {
                    try Task.checkCancellation()
                    try await backend.scroll(deltaX: 0, deltaY: -deltaY)
                    completedReturnSteps += 1
                    try await Task.sleep(nanoseconds: settleNanoseconds)
                }
                try Task.checkCancellation()
                let returnedFrameData = try await backend.screenshot()
                payload["sha256"] = GUIAutomationPayloadPolicy.sha256Hex(returnedFrameData)
                if let attachment = try persistScreenshotAttachment(returnedFrameData, sessionID: call.sessionID) {
                    attachments.append(attachment)
                }

                let returnedImage = UIImage(data: returnedFrameData)?.cgImage
                var returnedScreenSize = LocalPerceptionScreenSize(
                    width: Double(returnedImage?.width ?? 0),
                    height: Double(returnedImage?.height ?? 0)
                )
                let returnedMetricRegion = LocalFeedPerceptionPolicy.metricRegion(screenSize: returnedScreenSize).map {
                    CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.width), height: CGFloat($0.height))
                }
                var returnedObservation = await LocalVisionTextObservation.observe(
                    for: returnedFrameData,
                    maximumElements: 24,
                    regionInScreenPoints: returnedMetricRegion,
                    requiresText: true,
                    forcePrecise: returnedMetricRegion != nil
                )
                totalOCRLatencyMS += Int(returnedObservation.payload["localVisionLatencyMS"] ?? "0") ?? 0
                if returnedMetricRegion != nil { preciseMetricRegionSamples += 1 }
                var returnedElements = returnedObservation.elements
                let observedWidth = Double(returnedObservation.payload["screenPointWidth"] ?? "") ?? 0
                let observedHeight = Double(returnedObservation.payload["screenPointHeight"] ?? "") ?? 0
                if observedWidth > 0, observedHeight > 0 {
                    returnedScreenSize = .init(width: observedWidth, height: observedHeight)
                }

                var returnedSufficient = LocalFeedPerceptionPolicy.observationIsSufficient(
                    metric: requestedMetric,
                    elements: returnedElements,
                    screenSize: returnedScreenSize
                )
                if !returnedSufficient {
                    returnedObservation = await LocalVisionTextObservation.observe(
                        for: returnedFrameData,
                        maximumElements: 48,
                        requiresText: true,
                        forcePrecise: false
                    )
                    fullFrameOCRFallbackSamples += 1
                    totalOCRLatencyMS += Int(returnedObservation.payload["localVisionLatencyMS"] ?? "0") ?? 0
                    returnedElements = LocalPerceptionFusion.merge(ax: returnedElements, ocr: returnedObservation.elements)
                    returnedSufficient = LocalFeedPerceptionPolicy.observationIsSufficient(
                        metric: requestedMetric,
                        elements: returnedElements,
                        screenSize: returnedScreenSize
                    )
                }
                if !returnedSufficient {
                    axAttemptedSamples += 1
                    if let tree = try? await backend.tree() {
                        let returnedAX = LocalAXTreeTextExtractor.extract(from: tree, maximumElements: 96)
                        if !returnedAX.isEmpty { axSucceededSamples += 1 }
                        returnedElements = LocalPerceptionFusion.merge(ax: returnedAX, ocr: returnedElements)
                    }
                } else {
                    axSkippedLocalSufficientSamples += 1
                }

                if let returnIdentity = LocalFeedIdentity.signature(elements: returnedElements, screenSize: returnedScreenSize) {
                    selectedReturnVerified = returnIdentity == targetIdentity
                    if !selectedReturnVerified { returnFailureReason = "return_target_identity_mismatch" }
                } else {
                    selectedReturnVerified = false
                    returnFailureReason = "return_semantic_identity_unavailable"
                }
                payload["localMetricReturnSteps"] = String(returnSteps)
                payload["localMetricCompletedReturnSteps"] = String(completedReturnSteps)
                payload["localMetricReturnVerificationMode"] = "final_state_only"
                payload["localMetricReturnIdentityVerified"] = selectedReturnVerified ? "true" : "false"
                if let returnFailureReason { payload["localMetricReturnFailureReason"] = returnFailureReason }
            }
            payload["perceptionOCRLatencyMS"] = String(totalOCRLatencyMS)
            payload["perceptionOCRPreciseMetricRegionSampleCount"] = String(preciseMetricRegionSamples)
            payload["perceptionOCRFullFrameFallbackSampleCount"] = String(fullFrameOCRFallbackSamples)
            payload["perceptionAXAttempted"] = axAttemptedSamples > 0 ? "true" : "false"
            payload["perceptionAXSucceeded"] = axSucceededSamples > 0 ? "true" : "false"
            payload["perceptionAXSampleCount"] = String(axAttemptedSamples)
            payload["perceptionAXSuccessfulSampleCount"] = String(axSucceededSamples)
            payload["perceptionAXSkippedLocalSufficientSampleCount"] = String(axSkippedLocalSufficientSamples)
            payload["localMetricSelectedReturnVerified"] = selectedReturnVerified ? "true" : "false"
            if !returnToSelected || selectedReturnVerified {
                payload["perceptionLocalSufficient"] = "true"
                payload["perceptionRemoteVisionRequired"] = "false"
                payload["perceptionFallbackReason"] = "deterministic_local_metric_complete"
                payload["providerVisualRoundTripAvoided"] = "1"
                payload["effectVerification"] = returnToSelected ? "local_metric_selected_and_return_verified" : "local_metric_selection_complete"
            } else {
                payload["perceptionFallbackReason"] = "selected_item_return_unverified"
            }
        } else if let metric = requestedMetric, requestedSelection != nil {
            payload["localMetricExtraction"] = completed ? "incomplete_or_ambiguous" : "sequence_incomplete"
            if completed {
                let statuses = localVisionSamples.compactMap { $0["status"] }
                let failureReason: String
                if lowConfidenceMetricEvidence {
                    failureReason = "metric_confidence_below_threshold"
                } else if statuses.contains(where: { $0.hasPrefix("unavailable") }) {
                    failureReason = "ocr_request_failed"
                } else if statuses.contains("available_empty") {
                    failureReason = "ocr_completed_no_text"
                } else {
                    let reasons = localElementSamples.indices.compactMap { index in
                        LocalFeedMetricExtractor.failureReason(
                            metric: metric,
                            elements: localElementSamples[index],
                            screenSize: localScreenSamples.indices.contains(index) ? localScreenSamples[index] : nil
                        )
                    }
                    if reasons.contains("compact_count_normalization_failed") {
                        failureReason = "compact_count_normalization_failed"
                    } else if reasons.contains("right_rail_anchor_classification_failed") {
                        failureReason = "right_rail_anchor_classification_failed"
                    } else if let first = reasons.first {
                        failureReason = first
                    } else {
                        failureReason = "local_metric_incomplete_or_ambiguous"
                    }
                }
                payload["localVisionFailureClass"] = failureReason
                payload["perceptionFallbackReason"] = failureReason
            }
        }

        let localSufficient = payload["perceptionLocalSufficient"] == "true"
        let summary: String
        if localSufficient, let localMetricSelection {
            summary = "Locally sampled \(sampledCount) feed items and deterministically selected sample \(localMetricSelection.selectedSample) by \(localMetricSelection.metric.rawValue) \(localMetricSelection.selection.rawValue); remote visual comparison is not required."
        } else if completed {
            summary = "Locally sampled \(sampledCount) consecutive feed items in one bounded execution; local metric evidence was insufficient or not requested, so sample screenshots remain available for one semantic review."
        } else {
            summary = "Local feed sampling stopped at sample \(sampledCount) because semantic feed identity could not prove a distinct next item (\(stoppedReason ?? "unknown")); collected screenshots remain available for re-planning."
        }
        return ToolResult(
            toolCallID: call.id,
            success: true,
            summary: summary,
            payload: payload,
            attachments: attachments
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
                duration: GUIAutomationPayloadPolicy.normalizedSwipeDuration(call.arguments["duration"]) ?? 0.3
            )
        default:
            throw ToolRouterError.noExecutionRoute(call.name)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        try Task.checkCancellation()
        let observed = try await backend.screenshot()
        let observedSHA256 = GUIAutomationPayloadPolicy.sha256Hex(observed)
        let attachment = try persistScreenshotAttachment(observed, sessionID: call.sessionID)
        var payload: [String: String] = [
            "baselineSHA256": baselineSHA256,
            "sha256": observedSHA256,
            "screenChanged": observedSHA256 == baselineSHA256 ? "false" : "true",
            "effectVerification": "semantic_required",
            "localObservation": "final_screenshot_attached"
        ]
        await enrichWithLocalVision(&payload, screenshot: observed)
        return ToolResult(
            toolCallID: call.id,
            success: true,
            summary: "Bounded local action→observe micro-plan completed; final screenshot attached and semantic effect remains unverified.",
            payload: payload,
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
                    _ = try await backend.openApp(bundleID: bundleID)
                    stateChanges += 1
                case "waitForElement":
                    let elementCall = Self.elementLookupCall(from: step, sessionID: call.sessionID, toolName: "gui.waitForElement")
                    let resolved = try await waitForSemanticTarget(elementCall, timeoutMS: timeoutMS)
                    if resolved.cacheHit { elementCacheHits += 1 }
                case "tapElement":
                    let elementCall = Self.elementLookupCall(from: step, sessionID: call.sessionID, toolName: "gui.findElement")
                    let resolved = try await resolveSemanticTarget(elementCall)
                    if resolved.cacheHit { elementCacheHits += 1 }
                    guard !Self.isProtectedLocalVisionText(resolved.searchableText) else {
                        throw ToolRouterError.noExecutionRoute("structured plan stopped at protected/system-confirmation element")
                    }
                    guard !Self.isCommitLocalVisionText(resolved.searchableText) else {
                        throw ToolRouterError.noExecutionRoute("structured plan stopped before a commit/irreversible element; execute that action as a separately verified tool step")
                    }
                    try await backend.tap(x: resolved.centerX, y: resolved.centerY)
                    stateChanges += 1
                    if !isFinal || step.expectQuery != nil {
                        try await validateExpectation(step, timeoutMS: timeoutMS)
                    }
                case "typeElement":
                    let elementCall = Self.elementLookupCall(from: step, sessionID: call.sessionID, toolName: "gui.findElement")
                    let resolved = try await resolveSemanticTarget(elementCall)
                    if resolved.cacheHit { elementCacheHits += 1 }
                    guard !Self.isProtectedLocalVisionText(resolved.searchableText) else {
                        throw ToolRouterError.noExecutionRoute("structured plan stopped at protected/secure input element")
                    }
                    try await backend.tap(x: resolved.centerX, y: resolved.centerY)
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
            if let screenshot {
                payload["sha256"] = GUIAutomationPayloadPolicy.sha256Hex(screenshot)
                await enrichWithLocalVision(&payload, screenshot: screenshot)
            }
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
        var payload: [String: String] = [
            "completedSteps": String(completedSteps),
            "requestedSteps": String(plan.steps.count),
            "stateChanges": String(stateChanges),
            "elementCacheHits": String(elementCacheHits),
            "localExecutionMS": String(elapsedMS),
            "sha256": GUIAutomationPayloadPolicy.sha256Hex(screenshot),
            "effectVerification": "local_structured_validators_passed_final_semantic_review_required",
            "localObservation": "final_screenshot_attached",
            "structuredPath": "local_plan"
        ]
        await enrichWithLocalVision(&payload, screenshot: screenshot)
        return ToolResult(
            toolCallID: call.id,
            success: true,
            summary: "Structured local plan completed \(completedSteps) steps with local validation; one final screenshot is attached for semantic completion review.",
            payload: payload,
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

            var axResolved = false
            do {
                let tree = try await backend.tree()
                let matches = GUIElementResolver.find(in: tree, query: query, role: step.expectRole, mode: mode, maximumMatches: 3)
                if expectation == "present", matches.count == 1 { return }
                if expectation == "absent", matches.isEmpty { return }
                if matches.count > 1 {
                    throw ToolRouterError.noExecutionRoute("structured plan expectation is ambiguous; refine expectQuery/expectRole")
                }
                axResolved = true
            } catch let error as ToolRouterError {
                if String(describing: error).contains("ambiguous") { throw error }
            } catch {
                // AX is best-effort on standalone TrollStore. Continue immediately to same-frame OCR.
            }

            let screenshot = try await backend.screenshot()
            let ocrCall = ToolCall(
                name: "gui.findElement",
                arguments: ["query": query, "match": mode.rawValue],
                sessionID: UUID()
            )
            let first = await resolveLocalVisionText(ocrCall, screenshot: screenshot)
            var ocrResolution = first
            if first.match == nil,
               first.observation.payload["localVisionPrecisionRecommended"] == "true" {
                ocrResolution = await resolveLocalVisionText(ocrCall, screenshot: screenshot, forcePrecise: true)
            }
            if expectation == "present", ocrResolution.match != nil { return }
            if ocrResolution.failureReason == "ocr_unique_match_ambiguous" {
                throw ToolRouterError.noExecutionRoute("structured plan expectation is ambiguous in local OCR; refine expectQuery")
            }
            if expectation == "absent" {
                let status = ocrResolution.observation.payload["localVisionOCR"] ?? ""
                if ocrResolution.match == nil, (status == "recognized" || status == "available_empty") { return }
            }

            if Date() >= deadline { break }
            if axResolved {
                try await Task.sleep(nanoseconds: 120_000_000)
            } else {
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        } while Date() < deadline
        throw ToolRouterError.noExecutionRoute("structured plan local semantic expectation did not become true before timeout")
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

    private func resolveSemanticTarget(_ call: ToolCall) async throws -> LocalSemanticTarget {
        do {
            let resolved = try await resolveElement(call)
            return LocalSemanticTarget(
                centerX: resolved.match.frame.centerX,
                centerY: resolved.match.frame.centerY,
                searchableText: resolved.match.searchableText,
                source: "ax",
                cacheHit: resolved.cacheHit
            )
        } catch {
            let screenshot = try await backend.screenshot()
            var resolution = await resolveLocalVisionText(call, screenshot: screenshot)
            if resolution.match == nil,
               resolution.observation.payload["localVisionPrecisionRecommended"] == "true" {
                resolution = await resolveLocalVisionText(call, screenshot: screenshot, forcePrecise: true)
            }
            guard let match = resolution.match else {
                throw ToolRouterError.noExecutionRoute(resolution.failureSummary ?? "AX and local OCR could not resolve one unique semantic target")
            }
            return LocalSemanticTarget(
                centerX: match.centerX,
                centerY: match.centerY,
                searchableText: match.text,
                source: "ocr",
                cacheHit: resolution.observation.payload["localVisionCacheHit"] == "true"
            )
        }
    }

    private func waitForSemanticTarget(_ call: ToolCall, timeoutMS: Int) async throws -> LocalSemanticTarget {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000.0)
        var lastError: Error?
        repeat {
            do {
                return try await resolveSemanticTarget(call)
            } catch {
                lastError = error
            }
            try Task.checkCancellation()
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 120_000_000)
        } while Date() < deadline
        throw lastError ?? ToolRouterError.noExecutionRoute("local semantic target did not appear before timeout")
    }

    private func resolveLocalVisionText(
        _ call: ToolCall,
        screenshot: Data,
        forcePrecise: Bool = false
    ) async -> (match: LocalPerceptionTextElement?, observation: LocalVisionTextObservation.Observation, failureReason: String?, failureSummary: String?) {
        let query = call.arguments["query"] ?? ""
        let mode = GUIElementMatchMode(rawValue: call.arguments["match"] ?? "exact") ?? .exact
        let regions: [CGRect?] = forcePrecise ? [nil] : Self.semanticOCRRegions(query: query, screenshot: screenshot)
        var attemptLabels: [String] = []
        var lastObservation = LocalVisionTextObservation.Observation(
            payload: ["localVisionOCR": "unavailable_not_attempted"],
            elements: []
        )
        var lastFailureReason = "ocr_request_failed"
        var lastFailureSummary = "Local OCR text lookup did not run."

        for (index, region) in regions.enumerated() {
            var observation = await LocalVisionTextObservation.observe(
                for: screenshot,
                maximumElements: 48,
                regionInScreenPoints: region,
                requiresText: true,
                forcePrecise: forcePrecise
            )
            let regionLabel = observation.payload["localVisionRegion"] ?? (region == nil ? "full_screen" : "roi")
            let passLabel = forcePrecise ? "precise" : "fast"
            attemptLabels.append("\(index + 1):\(passLabel):\(regionLabel)")
            observation.payload["localVisionAttemptSequence"] = attemptLabels.joined(separator: " -> ")
            lastObservation = observation

            let status = observation.payload["localVisionOCR"] ?? "unavailable"
            guard status == "recognized" else {
                lastFailureReason = status == "available_empty" ? "ocr_completed_no_text" : "ocr_request_failed"
                lastFailureSummary = "Local OCR text lookup could not resolve a target: \(status)."
                continue
            }

            switch LocalPerceptionTextMatcher.resolve(query: query, mode: mode, elements: observation.elements) {
            case .unique(let match):
                observation.payload["localVisionPrecisionRecommended"] = "false"
                observation.payload["localVisionAttemptSequence"] = attemptLabels.joined(separator: " -> ")
                return (match, observation, nil, nil)
            case .ambiguous(let count):
                observation.payload["localVisionPrecisionRecommended"] = "false"
                observation.payload["localVisionAttemptSequence"] = attemptLabels.joined(separator: " -> ")
                return (
                    nil,
                    observation,
                    "ocr_unique_match_ambiguous",
                    "Local OCR text query is ambiguous (\(count) matches); refine the query instead of guessing coordinates."
                )
            case .notFound:
                lastObservation = observation
                lastFailureReason = "ocr_target_not_recognized"
                lastFailureSummary = "Local OCR completed, but the requested visible text did not produce one unique current-frame match."
            }
        }

        if !forcePrecise {
            let shortSemanticTarget = query.trimmingCharacters(in: .whitespacesAndNewlines).count <= 6
            let sparseFastResult = lastObservation.elements.count < 12
            let noText = lastObservation.payload["localVisionOCR"] == "available_empty"
            let preciseRecommended = noText || (shortSemanticTarget && sparseFastResult)
            lastObservation.payload["localVisionPrecisionRecommended"] = preciseRecommended ? "true" : "false"
            lastObservation.payload["localVisionPrecisionReason"] = preciseRecommended
                ? (noText ? "fast_completed_no_text" : "short_target_sparse_fast_result")
                : "fast_elements_sufficient_do_not_repeat_same_frame_precise"
        } else {
            lastObservation.payload["localVisionPrecisionRecommended"] = "false"
            lastObservation.payload["localVisionPrecisionReason"] = "precise_already_attempted"
        }
        lastObservation.payload["localVisionAttemptSequence"] = attemptLabels.joined(separator: " -> ")
        return (nil, lastObservation, lastFailureReason, lastFailureSummary)
    }

    private static func semanticOCRRegions(query: String, screenshot: Data) -> [CGRect?] {
        guard let image = UIImage(data: screenshot), image.size.width >= 100, image.size.height >= 200 else {
            return [nil]
        }
        let width = image.size.width
        let height = image.size.height
        let normalized = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let searchMarkers = ["搜索", "搜", "查找", "search", "find"]
        let commitMarkers = ["发送", "回复", "send", "reply"]
        let conversationMarkers = ["文件传输助手", "联系人", "群聊", "conversation", "contact", "chat"]

        if searchMarkers.contains(where: normalized.contains) {
            return [
                CGRect(x: 0, y: 0, width: width, height: height * 0.34),
                CGRect(x: 0, y: 0, width: width, height: height * 0.56),
                nil
            ]
        }
        if commitMarkers.contains(where: normalized.contains) {
            return [
                CGRect(x: 0, y: height * 0.62, width: width, height: height * 0.38),
                CGRect(x: 0, y: height * 0.44, width: width, height: height * 0.56),
                nil
            ]
        }
        if conversationMarkers.contains(where: normalized.contains) {
            return [
                CGRect(x: 0, y: height * 0.10, width: width, height: height * 0.68),
                CGRect(x: 0, y: height * 0.04, width: width, height: height * 0.86),
                nil
            ]
        }
        return [nil]
    }

    private func elementPayload(_ match: GUIElementMatch, treeHash: String, cacheHit: Bool) -> [String: String] {
        var payload: [String: String] = [
            "path": match.path,
            "treeSHA256": treeHash,
            "cache": cacheHit ? "tree_signature_hit" : "tree_signature_miss",
            "perceptionClass": "accessibility_element",
            "perceptionAXAttempted": "true",
            "perceptionAXSucceeded": "true",
            "perceptionAnchorCacheHit": cacheHit ? "true" : "false",
            "perceptionOCRInvoked": "false",
            "perceptionOCRSucceeded": "false",
            "perceptionLocalSufficient": "true",
            "perceptionRemoteVisionRequired": "false",
            "perceptionFallbackReason": cacheHit ? "validated_ax_cache_hit" : "fresh_ax_unique_match",
            "providerVisualRoundTripAvoided": "1",
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
        isProtectedLocalVisionText(match.searchableText)
    }

    private static func isProtectedLocalVisionText(_ text: String) -> Bool {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let protectedMarkers = [
            "face id", "touch id", "apple pay", "passcode", "password confirmation", "security code",
            "允许", "不允许", "系统权限", "密码确认", "支付确认", "面容 id", "触控 id"
        ]
        return protectedMarkers.contains(where: { haystack.contains($0) })
    }

    private static func isCommitElement(_ match: GUIElementMatch) -> Bool {
        isCommitLocalVisionText(match.searchableText)
    }

    private static func isCommitLocalVisionText(_ text: String) -> Bool {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let commitMarkers = [
            "send", "submit", "publish", "post", "delete", "remove", "purchase", "buy", "pay", "checkout", "confirm order",
            "发送", "提交", "发布", "删除", "移除", "购买", "支付", "结算", "确认订单", "卸载"
        ]
        return commitMarkers.contains(where: { haystack.contains($0) })
    }

    private func enrichWithLocalVision(_ payload: inout [String: String], screenshot: Data) async {
        let observation = await LocalVisionTextObservation.observe(for: screenshot)
        enrichWithLocalVision(&payload, observation: observation)
    }

    private func enrichWithLocalVision(_ payload: inout [String: String], observation: LocalVisionTextObservation.Observation) {
        let local = observation.payload
        for (key, value) in local {
            payload[key] = value
        }
        payload["perceptionOCRInvoked"] = "true"
        let ocrStatus = local["localVisionOCR"] ?? ""
        payload["perceptionOCRSucceeded"] = (ocrStatus == "recognized" || ocrStatus == "available_empty") ? "true" : "false"
        payload["perceptionOCRLatencyMS"] = local["localVisionLatencyMS"] ?? "0"
        if payload["perceptionAXAttempted"] == nil { payload["perceptionAXAttempted"] = "false" }
        if payload["perceptionAXSucceeded"] == nil { payload["perceptionAXSucceeded"] = "false" }
        if payload["perceptionAnchorCacheHit"] == nil { payload["perceptionAnchorCacheHit"] = "false" }
        if payload["perceptionLocalSufficient"] == nil { payload["perceptionLocalSufficient"] = "false" }
        if payload["perceptionRemoteVisionRequired"] == nil { payload["perceptionRemoteVisionRequired"] = "true" }
        if payload["perceptionFallbackReason"] == nil { payload["perceptionFallbackReason"] = "local_ocr_observation_requires_task_semantic_review" }
        if payload["providerVisualRoundTripAvoided"] == nil { payload["providerVisualRoundTripAvoided"] = "0" }
    }

    private func recordActionOutcomeIfKnown(
        bundleID: String,
        semanticAction: String,
        success: Bool,
        latencyMS: Int
    ) async {
        guard let appKnowledgeRegistry,
              let knowledge = await appKnowledgeRegistry.knowledge(for: bundleID) else { return }
        let environment = AppActionEnvironment(
            appVersion: knowledge.appVersion,
            iOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            deviceClass: nil
        )
        try? await appKnowledgeRegistry.recordActionOutcome(
            bundleID: bundleID,
            semanticAction: semanticAction,
            route: .guiFallback,
            environment: environment,
            success: success,
            latencyMS: latencyMS
        )
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
        case "gui.tapTextObserve", "gui.focusComposerObserve": return [.screenshot, .touch]
        case "gui.typeElementObserve": return [.tree, .touch, .textInput, .screenshot]
        case "gui.runStructuredPlan": return [.openApp, .screenshot, .touch, .textInput, .gestures]
        case "gui.screenshot": return [.screenshot]
        case "gui.tap": return [.touch]
        case "gui.type": return [.textInput]
        case "gui.scroll", "gui.swipe": return [.gestures]
        case "gui.swipeSequence", "gui.feedSample", "gui.navigateBack", "gui.scrollObserve", "gui.swipeObserve": return [.gestures, .screenshot]
        case "gui.tapObserve": return [.touch, .screenshot]
        case "gui.typeObserve": return [.textInput, .screenshot]
        case "gui.verify": return [.verify]
        default: return nil
        }
    }

    private static func requestLooksLikeMessaging(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let markers = ["微信", "wechat", "聊天", "消息", "文件传输助手", "发给", "发送", "回复", "message", "chat", "reply", "send"]
        return markers.contains(where: normalized.contains)
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
