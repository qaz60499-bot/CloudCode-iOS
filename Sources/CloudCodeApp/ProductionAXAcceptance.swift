import Foundation
import UIKit
import CloudCodeCore

/// Explicit USB acceptance of the retained production router. Each launch runs one stage only;
/// the operator inspects its screenshot before launching the next stage. No ordinary launch probes AX.
@MainActor
final class ProductionAXAcceptance {
    private let router: ToolRouter
    private let backend: TrollStoreGUIBackend
    private let cliRuntime: IOSSystemRuntime
    private let cliRoot: URL
    private var started = false
    private let target = "com.apple.mobiletimer"

    init(router: ToolRouter, backend: TrollStoreGUIBackend, cliRuntime: IOSSystemRuntime, cliRoot: URL) {
        self.router = router
        self.backend = backend
        self.cliRuntime = cliRuntime
        self.cliRoot = cliRoot
    }

    func runIfRequested(capabilities: CapabilityProfile) {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, arguments.contains("--cloudcode-ax-exact-acceptance"),
              !arguments.contains("--cloudcode-perception-regression") else { return }
        started = true
        func argument(_ prefix: String) -> String? {
            arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        let stage = argument("--ax-acceptance-stage=") ?? "A"
        guard ["A", "B", "C", "D", "E", "F", "CLI"].contains(stage) else { return }
        let runID = argument("--ax-acceptance-run=").flatMap(UUID.init(uuidString:)) ?? UUID()
        let iteration = min(9, max(0, Int(argument("--ax-acceptance-iteration=") ?? "0") ?? 0))
        let key = stage == "F" ? "F-\(iteration)" : stage
        let directory = URL(fileURLWithPath: "/var/mobile/Media/CloudCodeAXAcceptance", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("\(key).json")
        // Reusing a completed stage/run cannot dispatch the action twice.
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return }
        let background = UIApplication.shared.beginBackgroundTask(withName: "ProductionAXAcceptance")
        Task {
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            var context = ToolExecutionContext(permissionMode: .full, capabilityProfile: capabilities,
                allowedRoot: cliRoot,
                currentUserRequest: "Explicit restricted AX acceptance: CloudCode and Clock only. Read tree/text, switch Clock tabs, and read-only CLI smoke. No timer start, account, send, purchase or delete.",
                currentAppBundleID: target)
            var records: [[String: Any]] = []
            var passed = false
            var failure = ""
            let startedAt = Date()
            func invoke(_ name: String, _ arguments: [String: String] = [:]) async throws -> ToolResult {
                try Task.checkCancellation()
                let start = Date()
                let call = ToolCall(name: name, arguments: arguments, sessionID: runID)
                do {
                    let result = try await self.router.execute(call, context: context)
                    let data = try JSONEncoder().encode(result)
                    records.append(["tool": name, "arguments": arguments,
                        "durationMS": Int(Date().timeIntervalSince(start) * 1_000),
                        "result": try JSONSerialization.jsonObject(with: data)])
                    for (index, attachment) in (result.attachments ?? []).enumerated() {
                        guard attachment.mimeType.hasPrefix("image/") else { continue }
                        let file = directory.appendingPathComponent("\(key)-\(records.count)-\(index).jpg")
                        if let bytes = try? Data(contentsOf: URL(fileURLWithPath: attachment.path)), bytes.count <= 16 * 1024 * 1024 {
                            try bytes.write(to: file, options: .atomic)
                        }
                    }
                    return result
                } catch {
                    records.append(["tool": name, "arguments": arguments,
                        "durationMS": Int(Date().timeIntervalSince(start) * 1_000), "error": String(describing: error)])
                    throw error
                }
            }
            func require(_ result: ToolResult, _ detail: String) throws {
                guard result.success else { throw ToolRouterError.noExecutionRoute(detail + ": " + result.summary) }
            }
            func open(_ bundle: String) async throws {
                // The fixed runner has no user-supplied target, URL, command or coordinates.
                guard bundle == self.target || bundle == "com.cloudcode.ios" else {
                    throw ToolRouterError.noExecutionRoute("Acceptance target outside two-app boundary")
                }
                let result = try await invoke("gui.openApp", ["bundleId": bundle])
                try require(result, "Foreground launch failed")
                guard result.payload["foregroundVerified"] == "true" else {
                    throw ToolRouterError.noExecutionRoute("Acceptance requires verified foreground identity")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            func tree() async throws -> ToolResult {
                let result = try await invoke("gui.tree")
                try require(result, "Production AX tree failed")
                guard result.payload["perceptionAXSucceeded"] == "true",
                      result.payload["axForegroundBundleID"] == self.target else {
                    throw ToolRouterError.noExecutionRoute("No verified Clock semantic tree")
                }
                return result
            }
            do {
                if stage != "CLI" { try await open(self.target) }
                switch stage {
                case "A":
                    _ = try await tree()
                case "B":
                    let result = try await invoke("gui.findElement", ["query": "秒表", "match": "exact"])
                    try require(result, "Safe tab semantic find failed")
                    guard result.payload["perceptionAXSucceeded"] == "true", let role = result.payload["role"], !role.isEmpty else {
                        throw ToolRouterError.noExecutionRoute("Safe tab find lacked AX role")
                    }
                    let constrained = try await invoke("gui.findElement", ["query": "秒表", "role": role, "match": "exact"])
                    try require(constrained, "Role-constrained find failed")
                    if let identifier = result.payload["identifier"], !identifier.isEmpty {
                        let identified = try await invoke("gui.findElement", ["query": "秒表", "identifier": identifier, "role": role])
                        try require(identified, "Identifier-constrained find failed")
                    }
                case "C":
                    guard await self.backend.forceNextTreeTimeoutForAcceptance() else {
                        throw ToolRouterError.noExecutionRoute("Acceptance timeout fault was not armed")
                    }
                    let result = try await invoke("gui.verify", ["assertion": "世界时钟"])
                    try require(result, "AX fault did not fall back to independent local OCR")
                    guard result.verification?.passed == true else {
                        throw ToolRouterError.noExecutionRoute("OCR assertion was not verified")
                    }
                case "D":
                    // Two inert tab selections; never press a timer/stopwatch start or delete control.
                    for label in ["世界时钟", "秒表"] {
                        let found = try await invoke("gui.findElement", ["query": label, "match": "exact"])
                        try require(found, "Tab find failed")
                        guard found.payload["perceptionAXSucceeded"] == "true", let role = found.payload["role"], !role.isEmpty else {
                            throw ToolRouterError.noExecutionRoute("Tab action requires a fresh AX role")
                        }
                        let action = try await invoke("gui.tapElementObserve", ["query": label, "role": role, "match": "exact"])
                        try require(action, "Safe tab action failed")
                        _ = try await tree()
                    }
                case "E":
                    _ = try await tree()
                    try await open("com.cloudcode.ios")
                    _ = try await invoke("gui.screenshot")
                    try await open(self.target)
                    _ = try await tree()
                case "F":
                    // One AX/OCR/AX/OCR cycle per invocation allows a visual gate between cycles.
                    for _ in 0..<2 {
                        _ = try await tree()
                        let screenshot = try await invoke("gui.screenshot")
                        try require(screenshot, "Independent OCR observation failed")
                        guard screenshot.payload["perceptionOCRSucceeded"] == "true" else {
                            throw ToolRouterError.noExecutionRoute("Independent local OCR evidence missing")
                        }
                    }
                case "CLI":
                    try await open("com.cloudcode.ios")
                    context.currentAppBundleID = "com.cloudcode.ios"
                    let snapshot = await self.cliRuntime.cliCommandCapability()
                    let catalog = Set(snapshot.commands)
                    guard snapshot.runtimeAvailable, CLICommandCatalog.packagedP0.isSubset(of: catalog) else {
                        throw ToolRouterError.noExecutionRoute("Existing CLI catalog is not available")
                    }
                    context.capabilityProfile.records.removeAll { $0.id == "cli.runtime" || $0.id.hasPrefix("cli.command.") }
                    context.capabilityProfile.records.append(CapabilityRecord(id: "cli.runtime", domain: .execution, status: .available, detail: snapshot.detail))
                    for command in catalog {
                        context.capabilityProfile.records.append(CapabilityRecord(id: "cli.command.\(command)", domain: .execution, status: .available, detail: snapshot.detail))
                    }
                    for command in ["pwd", "echo AX_ACCEPTANCE_READONLY", "ls", "echo AX_ACCEPTANCE_READONLY | grep AX_ACCEPTANCE", "echo AX_ACCEPTANCE_READONLY | head -n 1"] {
                        try require(try await invoke("cli.run", ["command": command]), "Read-only CLI smoke failed")
                    }
                default: break
                }
                _ = try await invoke("gui.screenshot")
                passed = true
            } catch {
                failure = String(describing: error)
                if !Task.isCancelled { _ = try? await invoke("gui.screenshot") }
            }
            let snapshot = await self.backend.guiCapabilitySnapshot()
            let evidence: [String: Any] = ["schemaVersion": 1, "runID": runID.uuidString, "stage": key,
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "hostPID": getpid(), "target": self.target, "phasePassed": passed, "failure": failure,
                "durationMS": Int(Date().timeIntervalSince(startedAt) * 1_000), "records": records,
                "treeCapability": snapshot.status(.tree).rawValue,
                "visualGate": "Operator must inspect all stage screenshots for residual green frame before next stage",
                "faultMode": stage == "C" ? "watchdog-stall-after-real-passive-semantic-read" : "none",
                "overallAcceptanceComplete": false]
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), data.count <= 2 * 1024 * 1024 {
                try? data.write(to: destination, options: .atomic)
            }
        }
    }
}
