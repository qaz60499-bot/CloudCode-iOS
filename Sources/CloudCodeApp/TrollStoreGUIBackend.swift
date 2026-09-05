import Foundation
import CloudCodeCore

/// TrollStore-native GUI adapter. All private runtime work is executed in the embedded,
/// bounded helper process so a missing/blocked private API cannot wedge the SwiftUI host.
public actor TrollStoreGUIBackend: GUIAutomationBackend {
    public nonisolated let identifier = "trollstore-root-helper"
    private var cachedSnapshot: GUIAutomationCapabilitySnapshot?
    private var cachedSnapshotAt: Date?
    private let snapshotTTL: TimeInterval = 2

    public init() {}

    public func isAvailable() async -> Bool {
        // Never initiate a root/persona readiness probe from a generic availability check.
        // Explicit privileged capability validation populates this cache; before that, GUI
        // remains unavailable for ordinary Agent routing.
        cachedSnapshot?.compositeStatus == .available
    }

    public func guiCapabilitySnapshot() async -> GUIAutomationCapabilitySnapshot {
        if let cachedSnapshot, let cachedSnapshotAt,
           Date().timeIntervalSince(cachedSnapshotAt) <= snapshotTTL {
            return cachedSnapshot
        }
        let launch = EmbeddedRootHelper.launchCapability()
        let probe = EmbeddedRootHelper.guiProbe()
        var statuses: [GUIAutomationFeature: CapabilityStatus] = [
            .openApp: launch.available ? .available : .deviceValidationRequired,
            .tree: .deviceValidationRequired,
            .screenshot: .deviceValidationRequired,
            .touch: .deviceValidationRequired,
            .textInput: .deviceValidationRequired,
            .gestures: .deviceValidationRequired,
            .verify: .deviceValidationRequired
        ]
        var details: [GUIAutomationFeature: String] = [
            .openApp: launch.detail,
            .tree: probe.detail,
            .screenshot: probe.detail,
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
            statuses[.touch] = .deviceValidationRequired
            statuses[.textInput] = payload.textInput ? .available : .deviceValidationRequired
            statuses[.gestures] = .deviceValidationRequired
            statuses[.verify] = .deviceValidationRequired
            details[.tree] = "AXRuntime tree probing is deferred to the exact gui.tree/gui.verify request to keep device refresh crash-isolated."
            details[.screenshot] = "Global screenshot probing is deferred to the exact gui.screenshot request to keep device refresh crash-isolated."
            details[.touch] = "IOHID touch dispatch and coordinate-space validation are deferred to the exact gui.tap request."
            details[.textInput] = payload.textInput
                ? "IOHID Unicode input symbols opened successfully in the lightweight helper; the exact input event is still bounded and runtime-validated."
                : "IOHID Unicode text input remains deferred until an exact gui.type request proves the runtime."
            details[.gestures] = "IOHID gesture dispatch and coordinate-space validation are deferred to the exact gui.scroll/gui.swipe request."
            details[.verify] = "Verification is deferred with AX tree observation and runs only for an exact gui.verify request."
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

    public func openApp(bundleID: String) async throws {
        let outcome = EmbeddedRootHelper.launch(bundleID: bundleID)
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func tree() async throws -> String {
        let outcome = EmbeddedRootHelper.guiTree()
        guard let tree = outcome.tree else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
        guard tree.utf8.count <= 256 * 1024 else {
            throw ToolRouterError.noExecutionRoute("GUI tree exceeded the 256 KiB app-layer output limit")
        }
        return tree
    }

    public func screenshot() async throws -> Data {
        let outcome = EmbeddedRootHelper.guiScreenshot()
        guard let data = outcome.data else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
        return data
    }

    public func tap(x: Double, y: Double) async throws {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw ToolRouterError.noExecutionRoute("tap coordinates must be finite and non-negative")
        }
        let outcome = EmbeddedRootHelper.guiTap(x: x, y: y)
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func type(_ text: String) async throws {
        guard !text.isEmpty else { throw ToolRouterError.noExecutionRoute("text must not be empty") }
        let outcome = EmbeddedRootHelper.guiType(text)
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func scroll(deltaX: Double, deltaY: Double) async throws {
        guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 10_000, abs(deltaY) <= 10_000,
              abs(deltaX) >= 0.5 || abs(deltaY) >= 0.5 else {
            throw ToolRouterError.noExecutionRoute("scroll delta is invalid or outside the bounded range")
        }
        let outcome = EmbeddedRootHelper.guiScroll(deltaX: deltaX, deltaY: deltaY)
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double) async throws {
        let values = [fromX, fromY, toX, toY, duration]
        guard values.allSatisfy({ $0.isFinite }), fromX >= 0, fromY >= 0, toX >= 0, toY >= 0,
              duration >= 0.05, duration <= 5.0 else {
            throw ToolRouterError.noExecutionRoute("swipe coordinates/duration are invalid or outside the bounded range")
        }
        let outcome = EmbeddedRootHelper.guiSwipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, duration: duration)
        guard outcome.success else { throw ToolRouterError.noExecutionRoute(outcome.detail) }
    }

    public func verify(_ assertion: String) async throws -> VerificationResult {
        let observedTree = try await tree()
        return GUIVisibleTextVerifier.verify(tree: observedTree, assertion: assertion)
    }
}
