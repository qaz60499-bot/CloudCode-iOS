import Foundation

/// Small semantic facts, rather than rendered checkpoint JSON or old GUI observations.
public enum ProviderCheckpointSummary {
    public static func render(runtime: TaskRuntimeState?, payload: [String: String]) -> String {
        func value(_ key: String) -> String { String((payload[key] ?? "0").prefix(80)) }
        var lines = [
            "Durable task progress. These are execution facts; omitted old observations must not restart completed actions.",
            "Feed units completed=\(runtime.map { String($0.finiteFeedCompleted) } ?? value("tool.completedRepeatedSwipeCount")); post-launch actions=\(runtime.map { String($0.postLaunchGUIActionsCompleted) } ?? value("tool.successfulPostLaunchGUIActionCount")); text input=\(runtime.map { String($0.textInputActionsCompleted) } ?? value("tool.successfulTextInputCount")); taps=\(runtime.map { String($0.tapActionsCompleted) } ?? value("tool.successfulTapActionCount")); likes=\(runtime.map { String($0.likeActionsCompleted) } ?? value("tool.successfulLikeActionCount"))."
        ]
        if let runtime {
            lines.append("Message commit=\(runtime.messageCommitState.rawValue); composer focus verified=\(runtime.composerFocusVerified); postcondition verified=\(runtime.postconditionVerified); verification since action=\(runtime.verificationSinceLastStateChange).")
            lines.append("Current bundle=\(String((runtime.currentBundleID ?? "unknown").prefix(120))); surface=\(runtime.genericSurface.rawValue); selected sample=\(runtime.selectedFeedSample.map(String.init) ?? "none"); return verified=\(runtime.selectedFeedReturnVerified).")
            func bounded(_ obligations: Set<String>) -> String {
                obligations.sorted().prefix(8).map { String($0.prefix(64)) }.joined(separator: ", ")
            }
            lines.append("Completed obligations: \(bounded(runtime.completedObligations)). Pending obligations: \(bounded(runtime.pendingObligations)).")
            if runtime.messageCommitState == .uncertain {
                lines.append("A message commit may already have happened: observe/reconcile only; never resend to resolve uncertainty.")
            }
        }
        if let signature = payload["tool.lastStateChangeSignature"], !signature.isEmpty {
            lines.append("Last state-changing action signature=\(ProviderFingerprint.sha256(signature)); scope=\(String((payload["tool.lastStateChangeScope"] ?? "unknown").prefix(120))). Reconcile the effect before repeating it.")
        }
        return lines.joined(separator: "\n")
    }
}
