import Foundation
import CryptoKit

/// A deliberately small semantic contract for the two currently supported deterministic task shapes.
/// It is not a general natural-language planner and contains no screen coordinates or execution authority.
public struct TaskContract: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Intent: String, Codable, Sendable {
        case finiteFeed
        case messaging
    }

    public enum FeedMetric: String, Codable, Sendable {
        case likeCount
        case commentCount
        case shareCount
    }

    public enum SelectionRule: String, Codable, Sendable {
        case maximum
        case minimum
    }

    public enum ObligationKind: String, Codable, Sendable {
        case foregroundTargetApp
        case observeFiniteFeed
        case selectFeedItem
        case likeSelectedFeedItem
        case navigateToDestination
        case focusComposer
        case enterMessageBody
        case sendMessage
        case verifyPostcondition
    }

    public struct Obligation: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: ObligationKind
        public var requiredCount: Int

        public init(id: String, kind: ObligationKind, requiredCount: Int = 1) {
            self.id = id
            self.kind = kind
            self.requiredCount = max(1, requiredCount)
        }
    }

    public struct FeedSpec: Codable, Equatable, Sendable {
        public var exactItemCount: Int
        public var metric: FeedMetric?
        public var selectionRule: SelectionRule?
        public var requiresLikeAction: Bool

        public init(exactItemCount: Int, metric: FeedMetric? = nil, selectionRule: SelectionRule? = nil, requiresLikeAction: Bool = false) {
            self.exactItemCount = max(1, exactItemCount)
            self.metric = metric
            self.selectionRule = selectionRule
            self.requiresLikeAction = requiresLikeAction
        }
    }

    public struct MessageSpec: Codable, Equatable, Sendable {
        public var destinationEntity: String
        public var messageBody: String
        public var exactSendCount: Int

        public init(destinationEntity: String, messageBody: String, exactSendCount: Int = 1) {
            self.destinationEntity = destinationEntity
            self.messageBody = messageBody
            self.exactSendCount = max(1, exactSendCount)
        }
    }

    public struct Limits: Codable, Equatable, Sendable {
        public var exactFeedItemCount: Int?
        public var exactSendCount: Int?
        public var exactLikeCount: Int?
        public var forbidFeedOverrun: Bool
        public var reconcileUncertainSendBeforeRetry: Bool

        public init(
            exactFeedItemCount: Int? = nil,
            exactSendCount: Int? = nil,
            exactLikeCount: Int? = nil,
            forbidFeedOverrun: Bool = true,
            reconcileUncertainSendBeforeRetry: Bool = true
        ) {
            self.exactFeedItemCount = exactFeedItemCount
            self.exactSendCount = exactSendCount
            self.exactLikeCount = exactLikeCount
            self.forbidFeedOverrun = forbidFeedOverrun
            self.reconcileUncertainSendBeforeRetry = reconcileUncertainSendBeforeRetry
        }
    }

    public struct RetryBudgets: Codable, Equatable, Sendable {
        public var localRecovery: Int
        public var perceptionRecovery: Int
        public var providerReplan: Int

        public init(localRecovery: Int = 2, perceptionRecovery: Int = 2, providerReplan: Int = 1) {
            self.localRecovery = max(0, localRecovery)
            self.perceptionRecovery = max(0, perceptionRecovery)
            self.providerReplan = max(0, providerReplan)
        }
    }

    public var version: Int
    public var requestFingerprint: String
    public var intent: Intent
    public var targetAppName: String
    public var targetBundleID: String?
    public var obligations: [Obligation]
    public var completionConditions: [ObligationKind]
    public var limits: Limits
    public var retryBudgets: RetryBudgets
    public var feed: FeedSpec?
    public var message: MessageSpec?

    public init(
        requestFingerprint: String,
        intent: Intent,
        targetAppName: String,
        targetBundleID: String?,
        obligations: [Obligation],
        completionConditions: [ObligationKind],
        limits: Limits,
        retryBudgets: RetryBudgets = RetryBudgets(),
        feed: FeedSpec? = nil,
        message: MessageSpec? = nil
    ) {
        self.version = Self.schemaVersion
        self.requestFingerprint = requestFingerprint
        self.intent = intent
        self.targetAppName = targetAppName
        self.targetBundleID = targetBundleID
        self.obligations = obligations
        self.completionConditions = completionConditions
        self.limits = limits
        self.retryBudgets = retryBudgets
        self.feed = feed
        self.message = message
    }

    public static func fingerprint(for request: String) -> String {
        let normalized = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum TaskContractCompiler {
    /// Compile only the known deterministic golden-task shapes. Unknown tasks stay on the existing
    /// Agent/Harness path instead of being forced into an incorrect universal semantic contract.
    public static func compileKnownRequest(_ request: String) -> TaskContract? {
        let normalized = request.lowercased()
        let fingerprint = TaskContract.fingerprint(for: request)

        if HarnessContextManager.requiresMessageSend(in: request),
           normalized.contains("微信") || normalized.contains("wechat") {
            guard let destination = messagingDestination(in: request),
                  let body = messagingBody(in: request, destination: destination) else {
                return nil
            }
            let obligations: [TaskContract.Obligation] = [
                .init(id: "foreground", kind: .foregroundTargetApp),
                .init(id: "destination", kind: .navigateToDestination),
                .init(id: "composer", kind: .focusComposer),
                .init(id: "message_body", kind: .enterMessageBody),
                .init(id: "send", kind: .sendMessage),
                .init(id: "verify", kind: .verifyPostcondition)
            ]
            return TaskContract(
                requestFingerprint: fingerprint,
                intent: .messaging,
                targetAppName: "WeChat",
                targetBundleID: "com.tencent.xin",
                obligations: obligations,
                completionConditions: [.navigateToDestination, .focusComposer, .enterMessageBody, .sendMessage, .verifyPostcondition],
                limits: .init(exactSendCount: 1, reconcileUncertainSendBeforeRetry: true),
                message: .init(destinationEntity: destination, messageBody: body, exactSendCount: 1)
            )
        }

        if let count = HarnessContextManager.boundedRepeatedSwipeCount(in: request),
           HarnessContextManager.requestsConsecutiveFeedItems(in: request),
           normalized.contains("抖音") || normalized.contains("douyin") || normalized.contains("tiktok") {
            let metric: TaskContract.FeedMetric? = normalized.contains("点赞量") || normalized.contains("点赞数") || normalized.contains("like count") || normalized.contains("likes") ? .likeCount : nil
            let selection: TaskContract.SelectionRule? = normalized.contains("最高") || normalized.contains("最多") || normalized.contains("max") || normalized.contains("highest") ? .maximum : (normalized.contains("最低") || normalized.contains("最少") || normalized.contains("min") || normalized.contains("lowest") ? .minimum : nil)
            let requiresLike = HarnessContextManager.requiresLikeAction(in: request)
            var obligations: [TaskContract.Obligation] = [
                .init(id: "foreground", kind: .foregroundTargetApp),
                .init(id: "feed", kind: .observeFiniteFeed, requiredCount: count)
            ]
            if metric != nil || selection != nil {
                obligations.append(.init(id: "selection", kind: .selectFeedItem))
            }
            if requiresLike {
                obligations.append(.init(id: "like", kind: .likeSelectedFeedItem))
            }
            obligations.append(.init(id: "verify", kind: .verifyPostcondition))

            let isLite = normalized.contains("极速版") || normalized.contains("lite")
            return TaskContract(
                requestFingerprint: fingerprint,
                intent: .finiteFeed,
                targetAppName: isLite ? "Douyin Lite" : "Douyin",
                targetBundleID: isLite ? "com.ss.iphone.ugc.aweme.lite" : "com.ss.iphone.ugc.aweme",
                obligations: obligations,
                completionConditions: obligations.map(\.kind),
                limits: .init(
                    exactFeedItemCount: count,
                    exactLikeCount: requiresLike ? 1 : nil,
                    forbidFeedOverrun: true
                ),
                feed: .init(exactItemCount: count, metric: metric, selectionRule: selection, requiresLikeAction: requiresLike)
            )
        }

        return nil
    }

    private static func messagingDestination(in request: String) -> String? {
        let normalized = request.lowercased()
        if normalized.contains("文件传输助手") { return "文件传输助手" }
        return nil
    }

    private static func messagingBody(in request: String, destination: String) -> String? {
        let patterns = [
            #"(?:发送|发)(?:一个|一条|消息)?\s*[「『\"']?([^，。,.!?！？\s]+)[」』\"']?\s*$"#,
            #"(?:send|message)\s+[\"']?([^\"'\s]+)[\"']?\s*$"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: request) {
                let body = String(request[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty, body != destination { return body }
            }
        }
        return nil
    }
}

public struct TaskRuntimeState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum MessageCommitState: String, Codable, Sendable {
        case notAttempted
        case uncertain
        case verified
    }

    public enum PerceptionStatus: String, Codable, Sendable {
        case unknown
        case healthy
        case degraded
        case circuitOpen
    }

    public struct RetryState: Codable, Equatable, Sendable {
        public var localRecoveryRemaining: Int
        public var perceptionRecoveryRemaining: Int
        public var providerReplanRemaining: Int
    }

    public struct PerceptionState: Codable, Equatable, Sendable {
        public var ax: PerceptionStatus
        public var ocr: PerceptionStatus
        public var axFailureClass: String?
        public var ocrFailureClass: String?
    }

    public struct TransitionRecord: Codable, Equatable, Sendable {
        public var toolName: String
        public var scope: String?
        public var signature: String?
        public var at: Date
    }

    public struct VerifiedState: Codable, Equatable, Sendable {
        public var screenshotSHA256: String?
        public var genericSurface: IOSInteractionSurface
        public var semanticSurface: String?
        public var at: Date
    }

    public var version: Int
    public var requestFingerprint: String
    public var currentBundleID: String?
    public var currentAppVersion: String?
    public var genericSurface: IOSInteractionSurface
    public var semanticSurface: String?
    public var completedObligations: Set<String>
    public var pendingObligations: Set<String>
    public var finiteFeedCompleted: Int
    public var postLaunchGUIActionsCompleted: Int
    public var textInputActionsCompleted: Int
    public var tapActionsCompleted: Int
    public var likeActionsCompleted: Int
    public var selectedFeedSample: Int?
    public var selectedFeedReturnVerified: Bool
    public var messageCommitState: MessageCommitState
    public var composerFocusVerified: Bool
    public var verificationSinceLastStateChange: Bool
    public var postconditionVerified: Bool
    /// Optional for backward-compatible decoding of typed checkpoints written before this field existed.
    /// Nil is equivalent to zero.
    public var reconcileObservationCount: Int?
    public var lastStateTransition: TransitionRecord?
    public var lastVerifiedState: VerifiedState?
    public var retry: RetryState
    public var perception: PerceptionState

    public init(contract: TaskContract) {
        self.version = Self.schemaVersion
        self.requestFingerprint = contract.requestFingerprint
        self.currentBundleID = nil
        self.currentAppVersion = nil
        self.genericSurface = .unknown
        self.semanticSurface = nil
        self.completedObligations = []
        self.pendingObligations = Set(contract.obligations.map(\.id))
        self.finiteFeedCompleted = 0
        self.postLaunchGUIActionsCompleted = 0
        self.textInputActionsCompleted = 0
        self.tapActionsCompleted = 0
        self.likeActionsCompleted = 0
        self.selectedFeedSample = nil
        self.selectedFeedReturnVerified = false
        self.messageCommitState = .notAttempted
        self.composerFocusVerified = false
        self.verificationSinceLastStateChange = false
        self.postconditionVerified = false
        self.reconcileObservationCount = 0
        self.lastStateTransition = nil
        self.lastVerifiedState = nil
        self.retry = RetryState(
            localRecoveryRemaining: contract.retryBudgets.localRecovery,
            perceptionRecoveryRemaining: contract.retryBudgets.perceptionRecovery,
            providerReplanRemaining: contract.retryBudgets.providerReplan
        )
        self.perception = PerceptionState(ax: .unknown, ocr: .unknown, axFailureClass: nil, ocrFailureClass: nil)
    }

    public var successfulCommitAfterTextInput: Bool { messageCommitState == .verified }
    public var unverifiedMessageCommitAttempted: Bool { messageCommitState == .uncertain }
    public var boundedReconcileObservationCount: Int { max(0, reconcileObservationCount ?? 0) }

    public func canDispatchFiniteFeed(units: Int, contract: TaskContract) -> Bool {
        guard units > 0, let exact = contract.limits.exactFeedItemCount else { return true }
        return finiteFeedCompleted < exact && finiteFeedCompleted + units <= exact
    }

    public func canDispatchMessageCommit(contract: TaskContract) -> Bool {
        guard contract.intent == .messaging else { return true }
        if messageCommitState == .verified { return false }
        if contract.limits.reconcileUncertainSendBeforeRetry && messageCommitState == .uncertain { return false }
        return true
    }

    public mutating func markObligationCompleted(_ id: String) {
        completedObligations.insert(id)
        pendingObligations.remove(id)
    }

    public mutating func reconcileObligationProgress(contract: TaskContract) {
        if currentBundleID == contract.targetBundleID { markObligationCompleted("foreground") }
        if let exact = contract.limits.exactFeedItemCount, finiteFeedCompleted >= exact {
            markObligationCompleted("feed")
        }
        if selectedFeedSample != nil, selectedFeedReturnVerified {
            markObligationCompleted("selection")
        }
        if let exactLike = contract.limits.exactLikeCount,
           likeActionsCompleted >= exactLike,
           postconditionVerified {
            markObligationCompleted("like")
        }
        if textInputActionsCompleted > 0 { markObligationCompleted("message_body") }
        if composerFocusVerified { markObligationCompleted("composer") }
        // An attempted Send is not a completed Send. Keep the obligation pending while the
        // commit state is uncertain so resume/completion cannot silently promote a tap into a send.
        if messageCommitState == .verified { markObligationCompleted("send") }
        if postconditionVerified { markObligationCompleted("verify") }
    }

    /// Consume already-returned ToolRouter evidence. This method never executes a tool and never
    /// promotes screenshot/hash change alone into semantic completion.
    public mutating func applyToolEvidence(
        toolName: String,
        arguments: [String: String],
        result: ToolResult,
        observation: ObservationFrame?,
        contract: TaskContract
    ) {
        guard result.success else { return }

        if ["apps.launch", "gui.openApp", "gui.openAppObserve", "apps.openURL"].contains(toolName),
           result.payload["foregroundVerified"] == "true",
           let bundleID = arguments["bundleId"] {
            currentBundleID = bundleID
            currentAppVersion = result.payload["version"].flatMap { $0.isEmpty ? nil : $0 }
        }

        switch contract.intent {
        case .finiteFeed:
            if contract.feed?.requiresLikeAction == true,
               Self.isLikeOperation(toolName: toolName, arguments: arguments) {
                reconcileObservationCount = 0
            }
            if toolName == "gui.feedSample" {
                if result.payload["localMetricExtraction"] == "complete",
                   let selected = result.payload["localMetricSelectedSample"].flatMap(Int.init) {
                    selectedFeedSample = selected
                    selectedFeedReturnVerified = result.payload["localMetricSelectedReturnVerified"] == "true"
                    if selectedFeedReturnVerified {
                        genericSurface = .fullscreenMedia
                        semanticSurface = "douyin.feedVideo"
                    }
                }
            }

            if contract.feed?.requiresLikeAction == true, likeActionsCompleted > 0,
               let observation,
               Self.observationProvesLikedState(observation) {
                postconditionVerified = true
            } else if contract.feed?.requiresLikeAction == true,
                      likeActionsCompleted > 0,
                      toolName == "gui.screenshot" {
                reconcileObservationCount = boundedReconcileObservationCount + 1
            } else if contract.feed?.requiresLikeAction != true,
                      finiteFeedCompleted >= (contract.limits.exactFeedItemCount ?? Int.max),
                      (contract.feed?.selectionRule == nil || selectedFeedReturnVerified) {
                postconditionVerified = true
            }

        case .messaging:
            if toolName == "gui.tapTextObserve",
               let destination = contract.message?.destinationEntity,
               let query = arguments["query"],
               query == destination,
               result.payload["baselineSHA256"] != result.payload["sha256"],
               let observation,
               Self.observationContainsExactSemanticText(observation, text: destination) {
                // The pre-action search row also contains the destination text. Do not mark
                // navigation complete merely because that row was tapped. Require a changed
                // post-action frame that still exposes the destination semantically (normally the
                // conversation title); screenshot change by itself is never sufficient.
                markObligationCompleted("destination")
                genericSurface = .chat
                semanticSurface = "wechat.conversation"
            }
            if toolName == "gui.focusComposerObserve",
               result.payload["composerFocusVerified"] == "true" || result.payload["keyboardLikely"] == "true" {
                composerFocusVerified = true
                genericSurface = .composer
                semanticSurface = "wechat.composer"
            }
            if Self.isSendOperation(toolName: toolName, arguments: arguments), textInputActionsCompleted > 0 {
                messageCommitState = .uncertain
                reconcileObservationCount = 0
            }
            if messageCommitState == .uncertain,
               let body = contract.message?.messageBody,
               let observation,
               Self.observationContainsExactSemanticText(observation, text: body) {
                messageCommitState = .verified
                postconditionVerified = true
                genericSurface = .chat
                semanticSurface = "wechat.conversation"
            } else if messageCommitState == .uncertain, toolName == "gui.screenshot" {
                reconcileObservationCount = boundedReconcileObservationCount + 1
            }
        }
        reconcileObligationProgress(contract: contract)
    }

    private static func isLikeOperation(toolName: String, arguments: [String: String]) -> Bool {
        if arguments["semanticTarget"]?.lowercased() == "like" { return true }
        guard ["gui.tapTextObserve", "gui.tapElementObserve", "gui.runStructuredPlan"].contains(toolName) else { return false }
        let semantic = [arguments["query"], arguments["plan"]].compactMap { $0 }.joined(separator: " ").lowercased()
        return semantic.contains("点赞") || semantic.contains("\"like\"") || semantic == "like"
    }

    private static func isSendOperation(toolName: String, arguments: [String: String]) -> Bool {
        guard ["gui.tapTextObserve", "gui.tapElementObserve", "gui.runStructuredPlan"].contains(toolName) else { return false }
        let semantic = [arguments["query"], arguments["plan"]].compactMap { $0 }.joined(separator: " ").lowercased()
        return semantic.contains("发送") || semantic.contains("send") || semantic.contains("reply")
    }

    private static func observationContainsExactSemanticText(_ observation: ObservationFrame, text: String) -> Bool {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return observation.semanticElements.contains {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == target && $0.confidence >= 0.35
        }
    }

    private static func observationProvesLikedState(_ observation: ObservationFrame) -> Bool {
        observation.semanticElements.contains { element in
            let text = element.text.lowercased()
            return element.confidence >= 0.35 && (text.contains("已点赞") || text == "liked" || text.contains("取消点赞"))
        }
    }
}

public struct TaskDeterministicOperation: Equatable, Sendable {
    public var toolName: String
    public var arguments: [String: String]
    public var reason: String

    public init(toolName: String, arguments: [String: String] = [:], reason: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.reason = reason
    }
}

public enum TaskTransitionPolicy {
    /// Return an existing ToolRouter operation only when typed task state uniquely determines it.
    /// Unknown/ambiguous UI states return nil so control falls back to the normal Provider path.
    public static func nextOperation(
        contract: TaskContract,
        runtime: TaskRuntimeState,
        observation: ObservationFrame?
    ) -> TaskDeterministicOperation? {
        if let targetBundleID = contract.targetBundleID,
           runtime.currentBundleID != targetBundleID {
            return TaskDeterministicOperation(
                toolName: "apps.launch",
                arguments: ["bundleId": targetBundleID],
                reason: "typed_target_app_not_foreground"
            )
        }

        switch contract.intent {
        case .finiteFeed:
            guard let feed = contract.feed else { return nil }
            if runtime.finiteFeedCompleted < feed.exactItemCount {
                let remaining = feed.exactItemCount - runtime.finiteFeedCompleted
                if remaining == 1 {
                    // gui.feedSample intentionally requires at least two samples. Never round the
                    // final remainder up to a new batch: one remaining feed unit must stay one
                    // physical advance, then any metric/selection reconciliation can fall back to
                    // the existing Provider path without violating the exact-count invariant.
                    return TaskDeterministicOperation(
                        toolName: "gui.scrollObserve",
                        arguments: ["dx": "0", "dy": "600"],
                        reason: "typed_finite_feed_exact_final_unit"
                    )
                }
                var arguments: [String: String] = [
                    "direction": "forward",
                    "count": String(remaining)
                ]
                if let metric = feed.metric { arguments["metric"] = metric.rawValue }
                if let selection = feed.selectionRule {
                    arguments["selection"] = selection == .maximum ? "max" : "min"
                    arguments["returnToSelected"] = "true"
                }
                return TaskDeterministicOperation(
                    toolName: "gui.feedSample",
                    arguments: arguments,
                    reason: "typed_finite_feed_remaining_\(remaining)"
                )
            }
            if feed.selectionRule != nil, !runtime.selectedFeedReturnVerified {
                return nil
            }
            if feed.requiresLikeAction, runtime.likeActionsCompleted > 0, !runtime.postconditionVerified {
                // The Like write has already been dispatched once. Never tap Like again merely
                // because its semantic postcondition is still uncertain. Allow one independent
                // reconcile observation, tracked separately from screenshot/hash-change evidence.
                guard runtime.boundedReconcileObservationCount == 0 else { return nil }
                return TaskDeterministicOperation(
                    toolName: "gui.screenshot",
                    reason: "typed_like_postcondition_reconcile_once"
                )
            }
            if feed.requiresLikeAction, runtime.likeActionsCompleted == 0 {
                // A numeric right-rail metric identifies the selected item, not the icon itself.
                // Only use a locally observed semantic Like label; icon-only layouts fall back for
                // semantic disambiguation rather than deriving a permanent coordinate from geometry.
                if let likeLabel = observation?.semanticElements.first(where: { element in
                    let text = element.text.lowercased()
                    return text.contains("点赞") || text == "like" || text.contains("喜欢")
                }), !likeLabel.text.isEmpty {
                    return TaskDeterministicOperation(
                        toolName: "gui.tapTextObserve",
                        arguments: ["query": likeLabel.text, "match": "exact"],
                        reason: "typed_selected_feed_like_semantic_label"
                    )
                }
                return nil
            }
            if !runtime.postconditionVerified {
                guard runtime.boundedReconcileObservationCount == 0 else { return nil }
                return TaskDeterministicOperation(
                    toolName: "gui.screenshot",
                    reason: "typed_final_postcondition_observation_once"
                )
            }
            return nil

        case .messaging:
            guard let message = contract.message else { return nil }
            if runtime.messageCommitState == .uncertain, !runtime.postconditionVerified {
                // Exactly-once means uncertainty is reconciled, never retried. The paired Send
                // action may already have returned a post-action frame; if that was not enough,
                // take at most one independent local OCR observation before handing recovery back.
                guard runtime.boundedReconcileObservationCount == 0 else { return nil }
                return TaskDeterministicOperation(
                    toolName: "gui.screenshot",
                    reason: "typed_message_commit_reconcile_once"
                )
            }
            if runtime.pendingObligations.contains("destination") {
                return TaskDeterministicOperation(
                    toolName: "gui.tapTextObserve",
                    arguments: ["query": message.destinationEntity, "match": "exact"],
                    reason: "typed_message_destination"
                )
            }
            if runtime.pendingObligations.contains("composer") {
                return TaskDeterministicOperation(
                    toolName: "gui.focusComposerObserve",
                    reason: "typed_message_composer_focus"
                )
            }
            if runtime.pendingObligations.contains("message_body") {
                guard runtime.composerFocusVerified else { return nil }
                return TaskDeterministicOperation(
                    toolName: "gui.typeObserve",
                    arguments: ["text": message.messageBody, "purpose": "message_body"],
                    reason: "typed_message_body"
                )
            }
            if runtime.pendingObligations.contains("send") {
                guard runtime.canDispatchMessageCommit(contract: contract) else { return nil }
                return TaskDeterministicOperation(
                    toolName: "gui.tapTextObserve",
                    arguments: ["query": "发送", "match": "exact"],
                    reason: "typed_exactly_once_message_commit"
                )
            }
            if runtime.pendingObligations.contains("verify") || !runtime.postconditionVerified {
                guard runtime.boundedReconcileObservationCount == 0 else { return nil }
                return TaskDeterministicOperation(
                    toolName: "gui.screenshot",
                    reason: "typed_message_post_send_observation_once"
                )
            }
            return nil
        }
    }
}

public enum TaskSemanticCheckpointCodec {
    public static let contractKey = "semantic.taskContract.v1"
    public static let runtimeKey = "semantic.runtimeState.v1"

    public static func restoreContract(request: String, payload: [String: String]) -> TaskContract? {
        let requestFingerprint = TaskContract.fingerprint(for: request)
        if let encoded = payload[contractKey],
           let data = encoded.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TaskContract.self, from: data),
           decoded.requestFingerprint == requestFingerprint {
            return decoded
        }
        return TaskContractCompiler.compileKnownRequest(request)
    }

    public static func restoreRuntime(contract: TaskContract, payload: [String: String]) -> TaskRuntimeState {
        if let encoded = payload[runtimeKey],
           let data = encoded.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TaskRuntimeState.self, from: data),
           decoded.requestFingerprint == contract.requestFingerprint {
            return decoded
        }

        // Compatibility migration from the pre-typed checkpoint payload. Old checkpoints remain valid;
        // once restored, typed state becomes the runtime fact source and is dual-written back below.
        var state = TaskRuntimeState(contract: contract)
        state.postLaunchGUIActionsCompleted = max(0, Int(payload["tool.successfulPostLaunchGUIActionCount"] ?? "0") ?? 0)
        state.finiteFeedCompleted = max(0, Int(payload["tool.completedRepeatedSwipeCount"] ?? "0") ?? 0)
        state.textInputActionsCompleted = max(0, Int(payload["tool.successfulTextInputCount"] ?? "0") ?? 0)
        state.tapActionsCompleted = max(0, Int(payload["tool.successfulTapActionCount"] ?? "0") ?? 0)
        state.likeActionsCompleted = max(0, Int(payload["tool.successfulLikeActionCount"] ?? "0") ?? 0)
        if payload["tool.successfulCommitAfterTextInput"] == "true" {
            state.messageCommitState = .verified
        } else if payload["tool.unverifiedMessageCommitAttempted"] == "true" {
            state.messageCommitState = .uncertain
        }
        state.currentBundleID = payload["tool.currentGUIBundleID"]
        state.currentAppVersion = payload["tool.currentGUIAppVersion"]
        state.verificationSinceLastStateChange = payload["tool.verificationSinceLastStateChange"] == "true"
        state.reconcileObservationCount = max(0, Int(payload["tool.semanticReconcileObservationCount"] ?? "0") ?? 0)
        if let hash = payload["tool.lastGUIScreenshotSHA256"], !hash.isEmpty {
            state.lastVerifiedState = .init(screenshotSHA256: hash, genericSurface: .unknown, semanticSurface: nil, at: Date())
        }
        if let signature = payload["tool.lastStateChangeSignature"] {
            state.lastStateTransition = .init(
                toolName: "legacy",
                scope: payload["tool.lastStateChangeScope"],
                signature: signature,
                at: Date()
            )
        }
        if payload["tool.lastPerceptionAXAttempted"] == "true" {
            state.perception.ax = payload["tool.lastPerceptionAXSucceeded"] == "true" ? .healthy : .degraded
        }
        if payload["tool.lastPerceptionOCRInvoked"] == "true" {
            state.perception.ocr = payload["tool.lastPerceptionOCRSucceeded"] == "true" ? .healthy : .degraded
        }
        state.reconcileObligationProgress(contract: contract)
        return state
    }

    public static func persist(contract: TaskContract, runtime: TaskRuntimeState, payload: inout [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(contract), let string = String(data: data, encoding: .utf8) {
            payload[contractKey] = string
        }
        if let data = try? encoder.encode(runtime), let string = String(data: data, encoding: .utf8) {
            payload[runtimeKey] = string
        }

        // Compatibility dual-write. Existing resume/UI/diagnostic code can keep reading these keys while
        // consumers migrate incrementally to TaskRuntimeState.
        payload["tool.successfulPostLaunchGUIActionCount"] = String(runtime.postLaunchGUIActionsCompleted)
        payload["tool.completedRepeatedSwipeCount"] = String(runtime.finiteFeedCompleted)
        payload["tool.successfulTextInputCount"] = String(runtime.textInputActionsCompleted)
        payload["tool.successfulTapActionCount"] = String(runtime.tapActionsCompleted)
        payload["tool.successfulLikeActionCount"] = String(runtime.likeActionsCompleted)
        payload["tool.successfulCommitAfterTextInput"] = runtime.successfulCommitAfterTextInput ? "true" : "false"
        payload["tool.unverifiedMessageCommitAttempted"] = runtime.unverifiedMessageCommitAttempted ? "true" : "false"
        payload["tool.verificationSinceLastStateChange"] = runtime.verificationSinceLastStateChange ? "true" : "false"
        payload["tool.semanticReconcileObservationCount"] = String(runtime.boundedReconcileObservationCount)
        if let bundleID = runtime.currentBundleID { payload["tool.currentGUIBundleID"] = bundleID }
        else { payload.removeValue(forKey: "tool.currentGUIBundleID") }
        if let appVersion = runtime.currentAppVersion { payload["tool.currentGUIAppVersion"] = appVersion }
        else { payload.removeValue(forKey: "tool.currentGUIAppVersion") }
        if let signature = runtime.lastStateTransition?.signature { payload["tool.lastStateChangeSignature"] = signature }
        if let scope = runtime.lastStateTransition?.scope { payload["tool.lastStateChangeScope"] = scope }
        if let hash = runtime.lastVerifiedState?.screenshotSHA256 { payload["tool.lastGUIScreenshotSHA256"] = hash }
    }
}
