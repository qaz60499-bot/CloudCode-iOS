import Foundation

/// Shared Harness policy used by the existing AgentCore loop. This is deliberately
/// not a second agent loop: AgentCore remains the sole owner of planning/tool history,
/// while this helper only bounds provider context and preserves tool-call integrity.
public struct HarnessContextPolicy: Sendable, Equatable {
    public var maxCharacters: Int
    public var maxMessages: Int

    public init(maxCharacters: Int = 120_000, maxMessages: Int = 96) {
        self.maxCharacters = max(8_000, maxCharacters)
        self.maxMessages = max(12, maxMessages)
    }
}

public enum HarnessContextManager {
    public static func providerMessages(
        from messages: [ChatMessage],
        policy: HarnessContextPolicy = HarnessContextPolicy()
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        let systemMessages = messages.filter { $0.role == .system }
        let conversational = messages.enumerated().filter { $0.element.role != .system }
        let systemCost = systemMessages.reduce(0) { $0 + estimatedCharacters($1) }
        var remainingBudget = max(1_000, policy.maxCharacters - systemCost)
        var selectedIndexes = Set<Int>()
        var requiredToolCallIDs = Set<String>()
        var selectedCount = 0

        for pair in conversational.reversed() {
            let index = pair.offset
            let message = pair.element
            let cost = estimatedCharacters(message)
            let toolCallID = message.providerMetadata["tool_call_id"]
            let isRequiredAssistant = message.role == .assistant && toolCallID.map(requiredToolCallIDs.contains) == true
            let mustKeepLatestUser = selectedIndexes.isEmpty && message.role == .user
            let fits = selectedCount < policy.maxMessages && cost <= remainingBudget

            if fits || isRequiredAssistant || mustKeepLatestUser {
                selectedIndexes.insert(index)
                selectedCount += 1
                remainingBudget = max(0, remainingBudget - cost)
                if message.role == .tool, let toolCallID, !toolCallID.isEmpty {
                    requiredToolCallIDs.insert(toolCallID)
                }
                if message.role == .assistant, let toolCallID, !toolCallID.isEmpty {
                    requiredToolCallIDs.remove(toolCallID)
                }
            }
        }

        // Ensure at least the most recent user message survives even when the newest
        // messages are assistant/tool records and the context budget is exhausted.
        if let latestUser = messages.indices.reversed().first(where: { messages[$0].role == .user }) {
            selectedIndexes.insert(latestUser)
        }

        // Tool calls/results are one logical provider-history unit. The reverse budget pass
        // already forces an assistant call in when its selected tool result needs it, but the
        // opposite can still happen: a small assistant tool-call record may fit while the large
        // tool result immediately after it does not. Remove either side unless both survived.
        let selectedToolResultIDs = Set(selectedIndexes.compactMap { index -> String? in
            let message = messages[index]
            guard message.role == .tool else { return nil }
            let id = message.providerMetadata["tool_call_id"]
            return (id?.isEmpty == false) ? id : nil
        })
        let selectedAssistantToolIDs = Set(selectedIndexes.compactMap { index -> String? in
            let message = messages[index]
            guard message.role == .assistant else { return nil }
            let id = message.providerMetadata["tool_call_id"]
            return (id?.isEmpty == false) ? id : nil
        })
        let completeToolCallIDs = selectedToolResultIDs.intersection(selectedAssistantToolIDs)
        selectedIndexes = Set(selectedIndexes.filter { index in
            let message = messages[index]
            guard let id = message.providerMetadata["tool_call_id"], !id.isEmpty else { return true }
            if message.role == .assistant || message.role == .tool {
                return completeToolCallIDs.contains(id)
            }
            return true
        })

        var result = systemMessages
        result.append(contentsOf: executionHints(from: messages))
        let omitted = conversational.count - selectedIndexes.count
        if omitted > 0 {
            result.append(ChatMessage(
                role: .system,
                content: "Harness context compression omitted \(omitted) older conversation messages from this provider request. Full history remains persisted locally; do not infer that omitted tool actions should be repeated.",
                providerMetadata: ["context_layer": "harness_compression"]
            ))
        }
        for index in messages.indices where selectedIndexes.contains(index) && messages[index].role != .system {
            result.append(messages[index])
        }
        return result
    }

    static func executionHints(from messages: [ChatMessage]) -> [ChatMessage] {
        guard let request = messages.reversed().first(where: {
            $0.role == .user && $0.providerMetadata["internal_observation"] == nil
        })?.content else { return [] }
        var hints: [ChatMessage] = []
        if let count = boundedRepeatedSwipeCount(in: request) {
            hints.append(ChatMessage(
                role: .system,
                content: "Harness execution hint: the latest user request contains an explicit finite repeated swipe/feed-browse count of \(count). After a fresh foreground observation, prefer one gui.swipeSequence with count=\(count) when the repeated motion is mechanically identical and no intermediate semantic decision is required. This hint is advisory only: if the screen changes into a state that requires interpretation, use individual observe/action steps instead. Never turn this hint into an unbounded loop.",
                providerMetadata: [
                    "context_layer": "harness_execution",
                    "execution_mode": "bounded_repeated_swipe",
                    "repeat_count": String(count)
                ]
            ))
        }
        if transientNavigationNeedsReturn(in: request) {
            hints.append(ChatMessage(
                role: .system,
                content: "Harness execution hint: this request appears to open a transient content/detail surface in order to inspect it and then continue a later communication/evaluation step. Treat the origin screen as a return obligation. After observing the transient content, explicitly navigate back to the originating context and verify that return with a fresh GUI observation before locating a text field or typing. Do not type while still on the temporary video/detail surface unless the user explicitly asked to comment there.",
                providerMetadata: [
                    "context_layer": "harness_execution",
                    "execution_mode": "transient_navigation_return"
                ]
            ))
        }
        return hints
    }

    static func executionHint(from messages: [ChatMessage]) -> ChatMessage? {
        executionHints(from: messages).first
    }

    static func transientNavigationNeedsReturn(in request: String) -> Bool {
        let normalized = request.lowercased()
        let openMarkers = ["打开", "点开", "进入", "查看", "看", "open", "watch", "view"]
        let transientMarkers = ["视频", "详情", "帖子", "图片", "照片", "链接", "video", "detail", "post", "photo", "image", "link"]
        let continuationMarkers = ["评价", "回复", "告诉", "总结", "输入", "发送", "说说", "comment", "reply", "evaluate", "summarize", "type", "send"]
        return openMarkers.contains(where: normalized.contains)
            && transientMarkers.contains(where: normalized.contains)
            && continuationMarkers.contains(where: normalized.contains)
    }

    static func boundedRepeatedSwipeCount(in request: String) -> Int? {
        let normalized = request.lowercased()
        let actionMarkers = ["swipe", "滑", "刷"]
        guard actionMarkers.contains(where: normalized.contains) else { return nil }
        let finiteMarkers = ["次", "下", "个视频", "條視頻", "条视频", "videos", "times"]
        guard finiteMarkers.contains(where: normalized.contains) else { return nil }

        let digitPattern = #"(?<!\d)([2-9]|1[0-2])\s*(?:次|下|个视频|條視頻|条视频|videos?|times?)"#
        if let regex = try? NSRegularExpression(pattern: digitPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
           let range = Range(match.range(at: 1), in: request),
           let count = Int(request[range]) {
            return count
        }

        let chineseCounts: [(String, Int)] = [
            ("十二", 12), ("十一", 11), ("十", 10),
            ("九", 9), ("八", 8), ("七", 7), ("六", 6),
            ("五", 5), ("四", 4), ("三", 3), ("二", 2), ("两", 2), ("兩", 2)
        ]
        for (token, count) in chineseCounts {
            for suffix in ["次", "下", "个视频", "條視頻", "条视频"] where normalized.contains(token + suffix) {
                return count
            }
        }
        return nil
    }

    private static func estimatedCharacters(_ message: ChatMessage) -> Int {
        var cost = message.content.count + 32
        cost += message.providerMetadata.reduce(0) { $0 + $1.key.count + $1.value.count }
        cost += message.attachments.reduce(0) { $0 + $1.filename.count + $1.path.count + $1.mimeType.count + 64 }
        return cost
    }
}
