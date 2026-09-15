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
    private let snapshotTTL: TimeInterval = 30
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
        // Generic GUI readiness probing is intentionally excluded from the hot path. On the
        // physical TrollStore runtime the broad gui-probe helper can consume its watchdog even
        // though exact operations (launch/tree/screenshot/tap/type/gesture) remain usable. Every
        // concrete GUI tool below already owns bounded exact-operation self-validation, so a
        // capability snapshot must stay side-effect-free and cheap instead of paying a multi-second
        // helper round-trip before ordinary work can begin.
        let localVisionEvidence = await LocalVisionTextObservation.capabilityEvidence()
        var statuses: [GUIAutomationFeature: CapabilityStatus] = [
            .openApp: .deviceValidationRequired,
            .tree: ProductionPerceptionPolicy.accessibilityRuntimeAllowed ? .deviceValidationRequired : .unavailable,
            .screenshot: .deviceValidationRequired,
            .ocr: localVisionEvidence.status,
            .touch: .deviceValidationRequired,
            .textInput: .deviceValidationRequired,
            .gestures: .deviceValidationRequired,
            .verify: .deviceValidationRequired
        ]
        var details: [GUIAutomationFeature: String] = [
            .openApp: "App launch uses exact bundle-scoped self-validation; broad no-target readiness probing is intentionally disabled on this TrollStore runtime.",
            .tree: ProductionPerceptionPolicy.accessibilityRuntimeAllowed
                ? "AXRuntime tree probing is deferred to the exact gui.tree request."
                : ProductionPerceptionPolicy.accessibilityDisabledReason,
            .screenshot: "Global screenshot probing is deferred to the exact gui.screenshot request so ordinary routing never pays the broad GUI helper watchdog.",
            .ocr: localVisionEvidence.detail,
            .touch: "IOHID touch dispatch and coordinate-space validation are deferred to the exact gui.tap request.",
            .textInput: "Text input remains deferred until an exact gui.type request proves a focused AX or HID Unicode route at runtime.",
            .gestures: "IOHID gesture dispatch and coordinate-space validation are deferred to the exact gui.scroll/gui.swipe request.",
            .verify: "Verification is deferred with fresh semantic observation and runs only for an exact gui.verify request."
        ]

        for (feature, status) in exactRuntimeStatuses {
            if feature == .tree, !ProductionPerceptionPolicy.accessibilityRuntimeAllowed { continue }
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
        let startedAt = Date()
        let outcome = EmbeddedRootHelper.launch(bundleID: bundleID)
        guard outcome.accepted else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
        // Only a verified foreground transition invalidates the previous AX timeout state. An
        // accepted-but-unverified LaunchServices request must not reset the AX cooldown and trigger
        // another expensive tree probe loop.
        if outcome.foregroundVerified {
            treeRetryAfter = nil
            lastTreeFailureClass = nil
        }
        try? await diagnosticLogger?.log(
            level: outcome.foregroundVerified ? .info : .warning,
            subsystem: "gui-timing",
            action: "apps.launch",
            result: outcome.foregroundVerified ? "verified" : "accepted-unverified",
            diagnostic: outcome.detail,
            metadata: ["durationMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))]
        )
        return GUIOpenAppOutcome(
            accepted: outcome.accepted,
            foregroundVerified: outcome.foregroundVerified,
            detail: outcome.detail
        )
    }

    public func tree() async throws -> String {
        guard ProductionPerceptionPolicy.accessibilityRuntimeAllowed else {
            lastTreeFailureClass = .unknownClient
            treeRetryAfter = .distantFuture
            try? await diagnosticLogger?.log(
                level: .info,
                subsystem: "gui",
                action: "tree.production-policy",
                result: "quarantined",
                diagnostic: ProductionPerceptionPolicy.accessibilityDisabledReason,
                metadata: [
                    "axInvoked": "false",
                    "greenFrameRisk": "true",
                    "fallback": "screenshot_local_ocr"
                ]
            )
            throw ToolRouterError.noExecutionRoute(ProductionPerceptionPolicy.accessibilityDisabledReason)
        }
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
        let startedAt = Date()
        let outcome = EmbeddedRootHelper.guiScreenshot()
        guard let data = outcome.data else {
            try? await diagnosticLogger?.log(
                level: .error,
                subsystem: "gui-timing",
                action: "screenshot",
                result: "failed",
                diagnostic: outcome.detail,
                metadata: ["durationMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))]
            )
            throw ToolRouterError.noExecutionRoute(outcome.detail)
        }
        exactRuntimeStatuses[.screenshot] = .available
        exactRuntimeDetails[.screenshot] = "Exact global screenshot capture returned a valid bounded JPEG on this runtime."
        cachedSnapshotAt = nil
        // A working global screenshot is authoritative visual evidence for the current foreground
        // state. Keep any recent AX timeout cooldown in place; visually rich apps such as video
        // feeds do not become better automation targets by immediately retrying the same AX path.
        try? await diagnosticLogger?.log(
            level: .info,
            subsystem: "gui-timing",
            action: "screenshot",
            result: "completed",
            metadata: [
                "durationMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))),
                "byteCount": String(data.count),
                "axInvoked": "false"
            ]
        )
        return data
    }

    public func tap(x: Double, y: Double) async throws {
        let startedAt = Date()
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
            metadata: [
                "x": String(x), "y": String(y),
                "durationMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))
            ]
        )
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func type(_ text: String) async throws {
        let startedAt = Date()
        guard !text.isEmpty else { throw ToolRouterError.noExecutionRoute("text must not be empty") }
        let outcome = EmbeddedRootHelper.guiType(text)
        try? await diagnosticLogger?.log(
            level: outcome.success ? .info : .error,
            subsystem: "gui",
            action: "type.helper",
            result: outcome.success ? "submitted" : "failed",
            diagnostic: outcome.detail,
            metadata: [
                "characters": String(text.count),
                "utf8Bytes": String(text.utf8.count),
                "durationMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))),
                "axInvoked": "false"
            ]
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
        if ProductionPerceptionPolicy.accessibilityRuntimeAllowed {
            let observedTree = try await tree()
            return GUIVisibleTextVerifier.verify(tree: observedTree, assertion: assertion)
        }
        let startedAt = Date()
        let data = try await screenshot()
        let observation = await LocalVisionTextObservation.observe(
            for: data,
            maximumElements: 48,
            requiresText: true
        )
        let text = observation.elements.map(\.text).joined(separator: "\n")
        let result = GUIVisibleTextVerifier.verify(tree: text, assertion: assertion)
        try? await diagnosticLogger?.log(
            level: result.passed ? .info : .warning,
            subsystem: "gui",
            action: "verify.local-ocr",
            result: result.passed ? "passed" : "failed",
            metadata: [
                "axInvoked": "false",
                "ocrStatus": observation.payload["localVisionOCR"] ?? "unknown",
                "ocrBackend": observation.payload["localVisionBackend"] ?? "unknown",
                "verifyLatencyMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))
            ]
        )
        return result
    }
}
