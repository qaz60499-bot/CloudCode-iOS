import Foundation
import CloudCodeCore

/// TrollStore-native GUI adapter. All private runtime work is executed in the embedded,
/// bounded helper process so a missing/blocked private API cannot wedge the SwiftUI host.
public actor TrollStoreGUIBackend: GUIAutomationBackend {
    public nonisolated let identifier = "trollstore-root-helper"
    private var cachedSnapshot: GUIAutomationCapabilitySnapshot?
    private var cachedSnapshotAt: Date?
    private var exactRuntimeStatuses: [GUIAutomationFeature: CapabilityStatus] = [:]
    private var exactRuntimeDetails: [GUIAutomationFeature: String] = [:]
    private var treeRetryAfter: Date?
    private var lastTreeFailureClass: ObservationFrame.AXFailureClass?
    private let snapshotTTL: TimeInterval = 2
    private let treeFailureCooldown: TimeInterval = 30
    private let unknownClientCooldown: TimeInterval = 120
    private let diagnosticLogger: DiagnosticLogStore?

    public init(diagnosticLogger: DiagnosticLogStore? = nil) {
        self.diagnosticLogger = diagnosticLogger
    }

    public func isAvailable() async -> Bool {
        // Never initiate a root/persona readiness probe from a generic availability check.
        // Once an explicit capability refresh populated the cache, deviceValidationRequired is
        // routable: every concrete GUI operation owns a bounded exact-operation self-validation
        // path. Treating that state as backend-unavailable prevents those validators from ever
        // running and can report OCR/screenshot as unavailable even after a physical success.
        guard let status = cachedSnapshot?.compositeStatus else { return false }
        return status == .available || status == .deviceValidationRequired
    }

    public func guiCapabilitySnapshot() async -> GUIAutomationCapabilitySnapshot {
        if let cachedSnapshot, let cachedSnapshotAt,
           Date().timeIntervalSince(cachedSnapshotAt) <= snapshotTTL {
            return cachedSnapshot
        }
        // Build 110 showed that a no-target LaunchServices readiness query can consume the full
        // helper watchdog. Opening an App already has an exact bundle-scoped route with its own
        // acceptance + foreground verification, so keep this feature deferred instead of probing.
        let probe = EmbeddedRootHelper.guiProbe()
        let localVisionEvidence = await LocalVisionTextObservation.capabilityEvidence()
        var statuses: [GUIAutomationFeature: CapabilityStatus] = [
            .openApp: .deviceValidationRequired,
            .tree: .deviceValidationRequired,
            .screenshot: .deviceValidationRequired,
            .ocr: localVisionEvidence.status,
            .touch: .deviceValidationRequired,
            .textInput: .deviceValidationRequired,
            .gestures: .deviceValidationRequired,
            .verify: .deviceValidationRequired
        ]
        var details: [GUIAutomationFeature: String] = [
            .openApp: "App launch uses exact bundle-scoped self-validation; no-target LaunchServices probing is intentionally disabled on this TrollStore runtime.",
            .tree: probe.detail,
            .screenshot: probe.detail,
            .ocr: localVisionEvidence.detail,
            .touch: probe.detail,
            .textInput: probe.detail,
            .gestures: probe.detail,
            .verify: probe.detail
        ]

        if let payload = probe.payload {
            // Explicit refresh intentionally performs only a lightweight helper handshake. The
            // private observation and coordinate runtimes below stay deferred until the exact
            // requested operation executes in its own bounded helper process.
            statuses[.tree] = .deviceValidationRequired
            statuses[.screenshot] = .deviceValidationRequired
            // OCR is intentionally not derived from AX/tree or the root-helper handshake. Its
            // independent Vision-helper evidence is retained above and promoted only by an exact
            // OCR operation that actually completed on this runtime.
            statuses[.touch] = .deviceValidationRequired
            statuses[.textInput] = .deviceValidationRequired
            statuses[.gestures] = .deviceValidationRequired
            statuses[.verify] = .deviceValidationRequired
            details[.tree] = "AXRuntime tree probing is deferred to the exact gui.tree/gui.verify request to keep device refresh crash-isolated."
            details[.screenshot] = "Global screenshot probing is deferred to the exact gui.screenshot request to keep device refresh crash-isolated."
            details[.touch] = "IOHID touch dispatch and coordinate-space validation are deferred to the exact gui.tap request."
            details[.textInput] = payload.textInput
                ? "IOHID Unicode symbols are present, but symbol presence alone is not proof that the current focused field accepts text. Exact gui.type execution now prefers focused AX value injection with read-back verification, then falls back to HID Unicode with bounded postcondition checks when AX can observe the field."
                : "Text input remains deferred until an exact gui.type request proves a focused AX or HID Unicode route at runtime."
            details[.gestures] = "IOHID gesture dispatch and coordinate-space validation are deferred to the exact gui.scroll/gui.swipe request."
            details[.verify] = "Verification is deferred with AX tree observation and runs only for an exact gui.verify request."
        }

        for (feature, status) in exactRuntimeStatuses {
            statuses[feature] = status
        }
        for (feature, detail) in exactRuntimeDetails {
            details[feature] = detail
        }
        let snapshot = GUIAutomationCapabilitySnapshot(
            backendIdentifier: identifier,
            statuses: statuses,
            details: details
        )
        cachedSnapshot = snapshot
        cachedSnapshotAt = Date()
        return snapshot
    }

    public func openApp(bundleID: String) async throws -> GUIOpenAppOutcome {
        let outcome = EmbeddedRootHelper.launch(bundleID: bundleID)
        guard outcome.accepted else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
        // Only a verified foreground transition invalidates the previous AX timeout state. An
        // accepted-but-unverified LaunchServices request must not reset the AX cooldown and trigger
        // another expensive tree probe loop.
        if outcome.foregroundVerified {
            treeRetryAfter = nil
            lastTreeFailureClass = nil
        }
        return GUIOpenAppOutcome(
            accepted: outcome.accepted,
            foregroundVerified: outcome.foregroundVerified,
            detail: outcome.detail
        )
    }

    public func tree() async throws -> String {
        if let treeRetryAfter, treeRetryAfter > Date() {
            let seconds = max(1, Int(treeRetryAfter.timeIntervalSinceNow.rounded(.up)))
            let failureClass = lastTreeFailureClass?.rawValue ?? "temporary_failure"
            throw ToolRouterError.noExecutionRoute("AX tree circuit is open after \(failureClass); retry is suppressed for \(seconds)s so local OCR/screenshot execution can continue until foreground state changes.")
        }
        let startedAt = Date()
        let outcome = EmbeddedRootHelper.guiTree()
        let latencyMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        guard let tree = outcome.tree else {
            let failureClass = PerceptionBrokerFacade.classifyAXFailure(
                attempted: true,
                succeeded: false,
                text: outcome.detail
            )
            lastTreeFailureClass = failureClass
            treeRetryAfter = Date().addingTimeInterval(failureClass == .unknownClient ? unknownClientCooldown : treeFailureCooldown)
            try? await diagnosticLogger?.log(
                level: .warning,
                subsystem: "gui",
                action: "tree.helper",
                result: "unavailable",
                diagnostic: outcome.detail,
                metadata: [
                    "axBackend": "host_system_app_then_persona99_fallback",
                    "axStage": "host_semantic_tree_then_bounded_persona99_fallback",
                    "axScope": "unavailable",
                    "axLatencyMS": String(latencyMS),
                    "axFailureClass": failureClass.rawValue
                ]
            )
            throw ToolRouterError.noExecutionRoute(outcome.detail)
        }
        guard tree.utf8.count <= 256 * 1024 else {
            lastTreeFailureClass = .temporaryFailure
            treeRetryAfter = Date().addingTimeInterval(treeFailureCooldown)
            throw ToolRouterError.noExecutionRoute("GUI tree exceeded the 256 KiB app-layer output limit")
        }
        var axBackend = "host_system_app_then_persona99_fallback"
        var axScope = "unknown"
        if let data = tree.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            axBackend = object["backend"] as? String ?? axBackend
            axScope = object["scope"] as? String ?? axScope
        }
        treeRetryAfter = nil
        lastTreeFailureClass = nil
        exactRuntimeStatuses[.tree] = .available
        exactRuntimeDetails[.tree] = "Exact host-first AX tree operation returned a bounded semantic tree on this runtime."
        cachedSnapshotAt = nil
        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "gui",
            action: "tree.helper",
            result: "observed",
            metadata: [
                "axBackend": axBackend,
                "axStage": "host_semantic_tree_then_bounded_persona99_fallback",
                "axScope": axScope,
                "axLatencyMS": String(latencyMS)
            ]
        )
        treeRetryAfter = nil
        return tree
    }

    public func screenshot() async throws -> Data {
        let outcome = EmbeddedRootHelper.guiScreenshot()
        guard let data = outcome.data else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
        exactRuntimeStatuses[.screenshot] = .available
        exactRuntimeDetails[.screenshot] = "Exact global screenshot capture returned a valid bounded JPEG on this runtime."
        cachedSnapshotAt = nil
        // A working global screenshot is authoritative visual evidence for the current foreground
        // state. Keep any recent AX timeout cooldown in place; visually rich apps such as video
        // feeds do not become better automation targets by immediately retrying the same AX path.
        return data
    }

    public func tap(x: Double, y: Double) async throws {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw ToolRouterError.noExecutionRoute("tap coordinates must be finite and non-negative")
        }
        let outcome = EmbeddedRootHelper.guiTap(x: x, y: y)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "gui",
            action: "tap.helper",
            result: outcome.success ? "dispatched-unverified" : "failed",
            diagnostic: outcome.detail,
            metadata: ["x": String(x), "y": String(y)]
        )
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func type(_ text: String) async throws {
        guard !text.isEmpty else { throw ToolRouterError.noExecutionRoute("text must not be empty") }
        let outcome = EmbeddedRootHelper.guiType(text)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "gui",
            action: "type.helper",
            result: outcome.success ? "submitted" : "failed",
            diagnostic: outcome.detail,
            metadata: ["characters": String(text.count), "utf8Bytes": String(text.utf8.count)]
        )
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func scroll(deltaX: Double, deltaY: Double) async throws {
        guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 10_000, abs(deltaY) <= 10_000,
              abs(deltaX) >= 0.5 || abs(deltaY) >= 0.5 else {
            throw ToolRouterError.noExecutionRoute("scroll delta is invalid or outside the bounded range")
        }
        let outcome = EmbeddedRootHelper.guiScroll(deltaX: deltaX, deltaY: deltaY)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "gui",
            action: "scroll.helper",
            result: outcome.success ? "dispatched-unverified" : "failed",
            diagnostic: outcome.detail,
            metadata: ["dx": String(deltaX), "dy": String(deltaY)]
        )
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double) async throws {
        let values = [fromX, fromY, toX, toY, duration]
        guard values.allSatisfy({ $0.isFinite }), fromX >= 0, fromY >= 0, toX >= 0, toY >= 0,
              duration >= 0.05, duration <= 5.0 else {
            throw ToolRouterError.noExecutionRoute("swipe coordinates/duration are invalid or outside the bounded range")
        }
        let outcome = EmbeddedRootHelper.guiSwipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, duration: duration)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "gui",
            action: "swipe.helper",
            result: outcome.success ? "dispatched-unverified" : "failed",
            diagnostic: outcome.detail,
            metadata: [
                "fromX": String(fromX), "fromY": String(fromY),
                "toX": String(toX), "toY": String(toY),
                "duration": String(duration)
            ]
        )
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func navigateBack(strategy: String) async throws {
        guard strategy == "edge" || strategy == "dismissDown" else {
            throw ToolRouterError.noExecutionRoute("navigateBack strategy must be edge or dismissDown")
        }
        let outcome = EmbeddedRootHelper.guiNavigateBack(strategy: strategy)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "gui",
            action: "navigateBack.helper",
            result: outcome.success ? "dispatched-semantic-unverified" : "failed",
            diagnostic: outcome.detail,
            metadata: ["strategy": strategy]
        )
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func verify(_ assertion: String) async throws -> VerificationResult {
        let observedTree = try await tree()
        return GUIVisibleTextVerifier.verify(tree: observedTree, assertion: assertion)
    }
}
