import SwiftUI
import UIKit
import CryptoKit
import CloudCodeCore

// USB launch-argument entry to the existing perception probes. This is an explicit, bounded
// device test, never a persisted startup task or an Agent/provider execution path.
extension CloudCodeViewModel {
    @MainActor func runExplicitPerceptionRegressionIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--cloudcode-perception-regression") else { return }
        let runID = UUID().uuidString
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerceptionRegression-\(runID)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return }
        let token = UIApplication.shared.beginBackgroundTask(withName: "ExplicitPerceptionRegression")
        Task {
            func record(_ stage: String, _ body: [String: Any]) async {
                var value = body
                value["stage"] = stage
                value["timestamp"] = ISO8601DateFormatter().string(from: Date())
                value["hostState"] = UIApplication.shared.applicationState.rawValue
                guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                      data.count <= 256 * 1024 else { return }
                let file = directory.appendingPathComponent("\(stage).json")
                try? data.write(to: file, options: .atomic)
                await recordPerceptionProbe(id: runID, stage: stage, json: String(data: data, encoding: .utf8) ?? "{}")
            }
            await record("begin", ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "pid": getpid()])
            let assertion = await Task.detached { EmbeddedRootHelper.startBackgroundAssertion(targetPID: getpid()) }.value
            await record("assertion", ["workerPID": assertion.workerPID ?? 0, "detail": assertion.detail])
            let launch = await Task.detached { EmbeddedRootHelper.launch(bundleID: "com.tencent.xin") }.value
            await record("launch", ["accepted": launch.accepted, "foregroundVerified": launch.foregroundVerified, "detail": launch.detail])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            for iteration in 0..<30 {
                let stage = String(format: "request-%02d", iteration)
                switch iteration % 5 {
                case 0:
                    let result = await Task.detached { EmbeddedRootHelper.guiProbe() }.value
                    await record(stage, ["command": "gui-probe", "detail": String(describing: result)])
                case 1, 2:
                    let shot = await Task.detached { EmbeddedRootHelper.guiScreenshot() }.value
                    var body: [String: Any] = ["command": "screenshot-ocr", "screenshotDetail": shot.detail, "jpegBytes": shot.data?.count ?? 0]
                    if let data = shot.data {
                        try? data.write(to: directory.appendingPathComponent("\(stage).jpg"), options: .atomic)
                        let observation = await LocalVisionTextObservation.observe(for: data, maximumElements: 48, requiresText: true, forcePrecise: true)
                        body["ocr"] = observation.payload
                    }
                    await record(stage, body)
                case 3:
                    let tree = await Task.detached { EmbeddedRootHelper.guiTree() }.value
                    await record(stage, ["command": "gui-tree", "tree": tree.tree ?? "", "detail": tree.detail])
                default:
                    let focus = await Task.detached { EmbeddedRootHelper.focusedTextInput() }.value
                    await record(stage, ["command": "focused-text-input", "detail": focus.detail, "focusedTextInput": focus.payload?.focusedTextInput ?? false])
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if ProcessInfo.processInfo.arguments.contains("--cloudcode-ax-matrix") {
                var index = 0
                for root in [false, true] {
                    for seed in ["systemWide", "application", "pid0", "springboard"] {
                        for preparation in ["baseline", "requesting2", "associated"] {
                            let body = await Task.detached { () -> [String: String] in
                                var stdout: NSString?
                                var stderr: NSString?
                                let code = CloudCodeSpawnHelperWithSeparatedOutput(EmbeddedRootHelper.executablePath,
                                    ["gui-ax-probe-json", "attributes", seed, "0", preparation], root, 3, &stdout, &stderr)
                                return ["code": String(code), "stdout": stdout as String? ?? "", "stderr": stderr as String? ?? ""]
                            }.value
                            await record(String(format: "ax-%02d", index), ["seed": seed, "preparation": preparation, "root": root, "result": body])
                            index += 1
                        }
                    }
                }
            }
            if let pid = assertion.workerPID {
                let stopped = await Task.detached { EmbeddedRootHelper.stopBackgroundAssertion(workerPID: pid) }.value
                await record("assertion-stop", ["success": stopped.success, "detail": stopped.detail])
            }
            await record("completed", ["requests": 30, "status": "results_recorded_not_implicitly_passed"])
            if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
        }
    }
}

/// Explicit one-operation diagnostics. Uses the existing helper bridge and diagnostic log.
/// Nothing runs on view appearance and no provider or Agent task is started.
struct PerceptionProbeView: View {
    @ObservedObject var model: CloudCodeViewModel
    @State private var kind = "Vision"
    @State private var input = "english"
    @State private var initializer = "data"
    @State private var language = "en-US"
    @State private var helper = false
    @State private var cpuOnly = true
    @State private var delay = false
    @State private var axStage = "symbols"
    @State private var axSeed = "systemWide"
    @State private var axPreparation = "baseline"
    @State private var targetPID = "0"
    @State private var root = false
    @State private var running = false
    @State private var status = "每次只运行一个探针；结果写入现有诊断日志。"
    @State private var work: Task<Void, Never>?

    var body: some View {
        Form {
            Section("最小真机探针") {
                Picker("类型", selection: $kind) {
                    Text("Vision OCR").tag("Vision")
                    Text("AX 单阶段").tag("AX")
                }
                Toggle("延迟 5 秒运行（用于切到其他 App）", isOn: $delay)
                Text("先在电脑启动 USB 日志。延迟测试会记录实际 App 状态；若仍在前台，不计为后台测试。")
                    .font(.footnote)
            }
            if kind == "Vision" {
                Section("Vision 隔离变量") {
                    Picker("图像", selection: $input) {
                        Text("已知英文 JPEG").tag("english")
                        Text("已知中文 JPEG").tag("chinese")
                        Text("实时全局截图").tag("screenshot")
                    }.onChange(of: input) { value in
                        language = value == "chinese" ? "zh-Hans" : "en-US"
                    }
                    Picker("语言", selection: $language) {
                        Text("English").tag("en-US")
                        Text("简体中文").tag("zh-Hans")
                    }
                    Picker("解码入口", selection: $initializer) {
                        Text("VNImageRequestHandler(data:)").tag("data")
                        Text("ImageIO → CGImage").tag("cgImage")
                    }
                    Toggle("独立 Vision helper", isOn: $helper)
                    Toggle("usesCPUOnly", isOn: $cpuOnly)
                    Text("固定 accurate、单次识别，记录文字、置信度、坐标与错误链。英文 fixture 应含 CLOUD CODE 123；中文应含 文件传输助手。")
                        .font(.footnote)
                }
            } else {
                Section("AX 隔离变量") {
                    Picker("阶段", selection: $axStage) {
                        ForEach(["symbols", "frontmost", "root", "attributes", "hit-test", "application-at-point", "context-at-point"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Seed", selection: $axSeed) {
                        ForEach(["systemWide", "application", "pid0", "springboard"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("准备步骤", selection: $axPreparation) {
                        ForEach(["baseline", "requesting2", "associated"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("目标 PID（0 为尝试解析前台）", text: $targetPID).keyboardType(.numberPad)
                    Toggle("使用 root persona（默认 mobile）", isOn: $root)
                    Text("先测 symbols/frontmost，再测 application root。每次启动独立 helper；不会向第三方 App 派发手势。")
                        .font(.footnote)
                }
            }
            Section {
                Button(running ? "探针运行中…" : "运行一次并记录") { start() }.disabled(running)
                Text(status).font(.footnote).textSelection(.enabled)
            }
        }
        .navigationTitle("感知专项探针")
        .disabled(running)
    }

    @MainActor private func start() {
        guard !running else { return }
        let probeID = UUID().uuidString
        let selectedKind = kind, selectedInput = input, selectedInitializer = initializer, selectedLanguage = language
        let selectedHelper = helper, selectedCPU = cpuOnly, selectedDelay = delay
        let selectedStage = axStage, selectedSeed = axSeed, selectedPreparation = axPreparation, selectedRoot = root
        guard let pid = Int32(targetPID), pid >= 0 else { status = "PID 必须是非负整数。"; return }
        running = true
        status = selectedDelay ? "5 秒后运行，请切到待观察 App。" : "探针执行中。"
        work = Task { @MainActor in
            // Only the system's finite diagnostic grace period, not an unlimited assertion worker.
            var backgroundTask = UIBackgroundTaskIdentifier.invalid
            if selectedDelay {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CloudCode.PerceptionProbe") {
                    work?.cancel()
                }
            }
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
                running = false
                work = nil
            }
            await model.recordPerceptionProbe(id: probeID, stage: "begin", json: "{}")
            if selectedDelay {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { status = "探针延迟被取消。"; return }
            }
            guard !Task.isCancelled else { return }
            let before = UIApplication.shared.applicationState.rawValue
            let screen = UIScreen.main.bounds.size
            let scale = UIScreen.main.scale, nativeScale = UIScreen.main.nativeScale
            let result = await Task.detached(priority: .utility) { () -> String in
                if selectedKind == "AX" {
                    return Self.spawn(executable: EmbeddedRootHelper.executablePath,
                        arguments: ["gui-ax-probe-json", selectedStage, selectedSeed, String(pid), selectedPreparation], asRoot: selectedRoot)
                }
                let jpeg: Data
                if selectedInput == "screenshot" {
                    let capture = EmbeddedRootHelper.guiScreenshot()
                    guard let data = capture.data else {
                        return Self.json(["status": "capture_failed", "detail": capture.detail])
                    }
                    jpeg = data
                } else {
                    guard let url = Bundle.main.url(forResource: "perception-\(selectedInput)", withExtension: "jpg"),
                          let data = try? Data(contentsOf: url) else {
                        return Self.json(["status": "fixture_missing", "input": selectedInput])
                    }
                    jpeg = data
                }
                let body: String
                if selectedHelper {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCode-GUI-OCR-\(UUID().uuidString).jpg")
                    do {
                        try jpeg.write(to: url)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    } catch { return Self.json(["status": "fixture_write_failed"]) }
                    defer { try? FileManager.default.removeItem(at: url) }
                    body = Self.spawn(executable: EmbeddedVisionHelper.executablePath, arguments: ["probe-ocr-file", url.path,
                        selectedInitializer, selectedLanguage, selectedCPU ? "1" : "0", String(describing: screen.width), String(describing: screen.height)], asRoot: false)
                } else {
                    body = CloudCodeVisionProbeJSON(jpeg, selectedInitializer, selectedLanguage, selectedCPU, screen.width, screen.height)
                }
                return Self.json(["input": selectedInput, "sha256": SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined(),
                                  "result": Self.object(body)])
            }.value
            let after = UIApplication.shared.applicationState.rawValue
            let evidence = Self.json(["probeID": probeID, "kind": selectedKind, "hostPID": ProcessInfo.processInfo.processIdentifier,
                "hostStateBefore": before, "hostStateAfter": after, "delayed": selectedDelay,
                "hostStateLegend": "0=active,1=inactive,2=background", "scale": scale, "nativeScale": nativeScale,
                "result": Self.object(result)])
            await model.recordPerceptionProbe(id: probeID, stage: "result", json: evidence)
            status = "已记录 \(probeID)。请在诊断日志导出结果，并与 USB 日志对齐；记录成功不代表探针通过。"
        }
    }

    private static func spawn(executable: String, arguments: [String], asRoot: Bool) -> String {
        var stdout: NSString?, stderr: NSString?
        let code = CloudCodeSpawnHelperWithSeparatedOutput(executable, arguments, asRoot, 6, &stdout, &stderr)
        return json(["bridgeResult": code, "stdout": object((stdout as String?) ?? ""), "stderr": (stderr as String?) ?? ""])
    }

    private static func object(_ value: String) -> Any {
        guard let data = value.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) else { return value }
        return result
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= 30 * 1024 else { return "{\"status\":\"probe_output_exceeded_bound\"}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
