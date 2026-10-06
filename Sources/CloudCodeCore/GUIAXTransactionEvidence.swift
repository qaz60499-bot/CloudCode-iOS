import Foundation

/// Validates the existing helper transaction, not just its JSON transport. No AX calls are made
/// here. A passive helper must release its local references and the parent must observe its exit;
/// a timeout's partial/complete stdout can never turn an unconfirmed transaction into success.
public enum GUIAXTransactionEvidence {
    public static func hasVerifiedProcessExit(code: Int, stderr: String) -> Bool {
        guard code == 0, !stderr.contains("capture truncated") else { return false }
        for line in stderr.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let exit = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  exit["stage"] as? String == "helper-exit",
                  exit["helper"] as? String == "CloudCodeRootHelper" else { continue }
            return exit["waitStatusObserved"] as? Bool == true
                && exit["processReaped"] as? Bool == true
                && exit["reapDeferred"] as? Bool == false
                && exit["parentTimeout"] as? Bool == false
                && exit["parentCancelled"] as? Bool == false
                && (exit["result"] as? NSNumber)?.intValue == 0
                && (exit["exitCode"] as? NSNumber)?.intValue == 0
        }
        return false
    }

    public static func hasPassiveCleanupPayload(_ payload: [String: Any]) -> Bool {
        guard payload["automationLeaseActive"] as? Bool == false,
              let lifecycle = payload["axLifecycle"] as? [String: Any] else { return false }
        return lifecycle["mode"] as? String == "one-shot-passive-no-audit-client"
            && lifecycle["auditClientCreated"] as? Bool == false
            && lifecycle["globalStateMutated"] as? Bool == false
            && lifecycle["ownedRootReferenceReleased"] as? Bool == true
    }

    public static func validateTree(stdout: String, stderr: String, code: Int, now: Date = Date()) -> Bool {
        guard hasVerifiedProcessExit(code: code, stderr: stderr),
              let data = stdout.data(using: .utf8), !data.isEmpty, data.count <= 256 * 1024,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              hasPassiveCleanupPayload(payload),
              let backend = payload["backend"] as? String, backend.hasPrefix("AXRuntime"),
              ((payload["semanticNodeCount"] as? NSNumber)?.intValue ?? 0) > 0,
              ((payload["nodeCount"] as? NSNumber)?.intValue ?? 0) > 0,
              payload["foregroundVerified"] as? Bool == true,
              ((payload["pid"] as? NSNumber)?.intValue ?? 0) > 1,
              let bundleID = payload["bundleId"] as? String, bundleID.contains("."),
              let started = (payload["readStartedAtMS"] as? NSNumber)?.doubleValue,
              let finished = (payload["readFinishedAtMS"] as? NSNumber)?.doubleValue,
              started.isFinite, finished.isFinite, finished >= started, finished - started <= 1_500,
              now.timeIntervalSince1970 * 1_000 - finished <= 2_000,
              finished - now.timeIntervalSince1970 * 1_000 <= 250,
              let root = payload["tree"] as? [String: Any] else { return false }
        var visited = 0
        var semantic = 0
        func walk(_ node: [String: Any], depth: Int) {
            guard depth <= 32, visited < 512 else { return }
            visited += 1
            if let frame = node["frame"] as? [String: Any],
               let x = (frame["x"] as? NSNumber)?.doubleValue,
               let y = (frame["y"] as? NSNumber)?.doubleValue,
               let width = (frame["width"] as? NSNumber)?.doubleValue,
               let height = (frame["height"] as? NSNumber)?.doubleValue,
               x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 {
                let role = node["role"] as? String ?? ""
                let text = ["label", "value", "title", "placeholder", "identifier"].contains {
                    !(node[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                // An Application shell/point-sampling wrapper is not foreground semantic evidence.
                if !["AXApplication", "AXHitTestSnapshot", "Application", "AXWindow", "Window"].contains(role),
                   text || (!role.isEmpty && role != "AXUnknown") { semantic += 1 }
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return semantic > 0
    }
}

extension GUIVisibleTextVerifier {
    /// AX is exact-operation evidence. A transport error or missing text falls through to local
    /// OCR; user cancellation still ends the operation instead of starting more perception work.
    public static func verifyWithLocalFallback(
        assertion: String,
        ax: () async throws -> String?,
        ocr: () async throws -> String
    ) async throws -> VerificationResult {
        do {
            if let tree = try await ax() {
                let result = verify(tree: tree, assertion: assertion)
                if result.passed { return result }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
        }
        try Task.checkCancellation()
        return verify(tree: try await ocr(), assertion: assertion)
    }
}
