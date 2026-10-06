import Foundation

/// Pre-dispatch protection complements the post-result four-round stop.
/// Signatures omit provider-generated call IDs, so new IDs cannot hide a repeated action.
public enum ToolPlanRepeatGuard {
    public enum Decision: String, Sendable {
        case execute
        case reconcileBeforeMutation
        case stop
    }

    public static func decision(signature: String, lastExecutedSignature: String?,
                                previouslyBlocked: Set<String>, containsMutation: Bool,
                                finiteRepeatHasVerifiedProgress: Bool) -> Decision {
        // Read-only observations are idempotent and their result can change asynchronously,
        // so a historical blocked signature must never suppress a fresh read. The existing
        // post-result guard already stops four identical plan+result rounds.
        if !containsMutation { return .execute }
        if previouslyBlocked.contains(signature) { return .stop }
        guard signature == lastExecutedSignature else { return .execute }
        if finiteRepeatHasVerifiedProgress { return .execute }
        return .reconcileBeforeMutation
    }
}
