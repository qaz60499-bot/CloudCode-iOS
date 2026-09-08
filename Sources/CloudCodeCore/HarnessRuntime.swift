import Foundation

/// Shared Harness policy used by the existing AgentCore loop. This is deliberately
/// not a second agent loop: AgentCore remains the sole owner of planning/tool history,
/// while this helper only bounds provider context and preserves tool-call integrity.
public struct HarnessContextPolicy: Sendable, Equatable {
    public var maxCharacters: Int
    public var maxMessages: Int

    public init(maxCharacters: Int = 80_000, maxMessages: Int = 72) {
        self.maxCharacters = max(8_000, maxCharacters)
        self.maxMessages = max(12, maxMessages)
    }

    public static let gatewayRecovery = HarnessContextPolicy(maxCharacters: 48_000, maxMessages: 48)
}

public enum HarnessContextManager {
    public static func providerMessages(
        from messages: [ChatMessage],
        policy: HarnessContextPolicy = HarnessContextPolicy(),
        currentRequest: String? = nil
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        let normalizedMessages = pruningHistoricalObservationAttachments(in: messages)
        let systemMessages = normalizedMessages.filter { $0.role == .system }
        let conversational = normalizedMessages.enumerated().filter { $0.element.role != .system }
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
        if let latestUser = normalizedMessages.indices.reversed().first(where: {
            normalizedMessages[$0].role == .user && normalizedMessages[$0].providerMetadata["internal_observation"] == nil
        }) {
            selectedIndexes.insert(latestUser)
        }

        // Tool calls/results are one logical provider-history unit. The reverse budget pass
        // already forces an assistant call in when its selected tool result needs it, but the
        // opposite can still happen: a small assistant tool-call record may fit while the large
        // tool result immediately after it does not. Remove either side unless both survived.
        let selectedToolResultIDs = Set(selectedIndexes.compactMap { index -> String? in
            let message = normalizedMessages[index]
            guard message.role == .tool else { return nil }
            let id = message.providerMetadata["tool_call_id"]
            return (id?.isEmpty == false) ? id : nil
        })
        let selectedAssistantToolIDs = Set(selectedIndexes.compactMap { index -> String? in
            let message = normalizedMessages[index]
            guard message.role == .assistant else { return nil }
            let id = message.providerMetadata["tool_call_id"]
            return (id?.isEmpty == false) ? id : nil
        })
        let completeToolCallIDs = selectedToolResultIDs.intersection(selectedAssistantToolIDs)
        selectedIndexes = Set(selectedIndexes.filter { index in
            let message = normalizedMessages[index]
            guard let id = message.providerMetadata["tool_call_id"], !id.isEmpty else { return true }
            if message.role == .assistant || message.role == .tool {
                return completeToolCallIDs.contains(id)
            }
            return true
        })

        var result = systemMessages
        result.append(contentsOf: executionHints(from: normalizedMessages, currentRequest: currentRequest))
        let omitted = conversational.count - selectedIndexes.count
        if omitted > 0 {
            result.append(ChatMessage(
                role: .system,
                content: "Harness context compression omitted \(omitted) older conversation messages from this provider request. Full history remains persisted locally; do not infer that omitted tool actions should be repeated.",
                providerMetadata: ["context_layer": "harness_compression"]
            ))
        }
        for index in normalizedMessages.indices where selectedIndexes.contains(index) && normalizedMessages[index].role != .system {
            result.append(normalizedMessages[index])
        }
        return result
    }

    static func executionHints(from messages: [ChatMessage], currentRequest: String? = nil) -> [ChatMessage] {
        let explicitRequest = currentRequest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let request = !explicitRequest.isEmpty ? explicitRequest : messages.reversed().first(where: {
            $0.role == .user && $0.providerMetadata["internal_observation"] == nil
        })?.content else { return [] }
        var hints: [ChatMessage] = []
        if let count = boundedRepeatedSwipeCount(in: request) {
            let needsFeedReview = feedSamplingNeedsIntermediateReview(in: request)
            let namesFeedItems = requestsConsecutiveFeedItems(in: request)
            let useFeedSample = needsFeedReview || namesFeedItems
            hints.append(ChatMessage(
                role: .system,
                content: useFeedSample
                    ? "Harness execution hint: the latest user request names \(count) consecutive feed/video items. After the target feed is foreground, prefer one gui.feedSample with direction=forward and count=\(count). This coordinate-free local macro owns the physical gesture direction, captures the requested consecutive items, and avoids raw swipe-coordinate/unit mistakes. Review the returned current screenshots when semantic comparison is required; do not translate forward into user-facing up/down finger-motion wording."
                    : "Harness execution hint: the latest user request contains an explicit finite repeated swipe count of \(count). After a fresh foreground observation, prefer one gui.swipeSequence with count=\(count) when the repeated motion is mechanically identical and no intermediate semantic decision is required. Swipe coordinates are screen-point coordinates and duration is seconds (0.05–5.0, typically about 0.3); do not emit millisecond duration values. This hint is advisory only: if the screen changes into a state that requires interpretation, use a bounded local semantic macro or individual observe/action steps instead. Never turn this hint into an unbounded loop.",
                providerMetadata: [
                    "context_layer": "harness_execution",
                    "execution_mode": useFeedSample ? "bounded_feed_sample" : "bounded_repeated_swipe",
                    "repeat_count": String(count)
                ]
            ))
        }
        if requiresMessageSend(in: request) {
            hints.append(ChatMessage(
                role: .system,
                content: "Harness execution hint: this is a messaging/contact task. Once the target App is foreground and a fresh screenshot is available, stay on the current in-App GUI/search path and act from that observation; do not detour through apps.list, container, filesystem, or SQLite discovery merely to locate a visible contact. Read-only native/container discovery is a fallback for an explicit local-data request or when no fresh GUI observation can resolve the destination and the exact container route is already verified. It must never be used to forge a sent-message state by editing an App database. A final send/commit is an external App action and still requires a real send control/private/GUI route plus fresh postcondition verification.",
                providerMetadata: [
                    "context_layer": "harness_execution",
                    "execution_mode": "foreground_messaging_fast_path"
                ]
            ))
        }
        if transientNavigationNeedsReturn(in: request) {
            hints.append(ChatMessage(
                role: .system,
                content: "Harness execution hint: this request appears to open a transient content/detail surface in order to inspect it and then continue a later communication/evaluation step. Treat the origin screen as a return obligation. After observing the transient content, explicitly navigate back to the originating context and verify that return before locating a text field or typing. Prefer a visible unambiguous back/close control; otherwise use gui.navigateBack with strategy=dismissDown for fullscreen/modal video or strategy=edge for an iOS navigation stack. gui.navigateBack returns the final screenshot for semantic confirmation, so do not add a provider round-trip solely to decide whether to observe after it. Never treat ordinary video-frame changes as proof that navigation succeeded. Do not type while still on the temporary video/detail surface unless the user explicitly asked to comment there.",
                providerMetadata: [
                    "context_layer": "harness_execution",
                    "execution_mode": "transient_navigation_return"
                ]
            ))
        }
        return hints
    }

    static func executionHint(from messages: [ChatMessage], currentRequest: String? = nil) -> ChatMessage? {
        executionHints(from: messages, currentRequest: currentRequest).first
    }

    static func providerPolicy(for request: String) -> HarnessContextPolicy {
        let normalized = request.lowercased()
        let guiMarkers = [
            "打开", "刷视频", "刷几个", "滑", "滚动", "点赞", "点开", "点击", "界面", "屏幕", "截图", "聊天", "发送", "输入",
            "swipe", "scroll", "tap", "screenshot", "gui", "send", "chat"
        ]
        if guiMarkers.contains(where: normalized.contains) {
            // GUI execution is dominated by current foreground evidence. Retaining dozens of old
            // screenshot/tool turns makes gateway payloads slower and can trigger compatibility
            // failures without improving the next local action. Full history stays persisted locally.
            return HarnessContextPolicy(maxCharacters: 48_000, maxMessages: 40)
        }
        return HarnessContextPolicy()
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

    static func feedSamplingNeedsIntermediateReview(in request: String) -> Bool {
        let normalized = request.lowercased()
        let markers = [
            "比较", "哪个", "哪一个", "最高", "最多", "最低", "点赞量", "点赞数", "评论量", "评论数", "好看", "分析", "看看", "看一下",
            "compare", "highest", "most", "likes", "comments", "analyze", "inspect"
        ]
        return markers.contains(where: normalized.contains)
    }

    static func requestsConsecutiveFeedItems(in request: String) -> Bool {
        let normalized = request.lowercased()
        let feedMarkers = ["个视频", "条视频", "條視頻", "个帖子", "条帖子", "條帖子", "videos", "posts", "feed"]
        if feedMarkers.contains(where: normalized.contains) { return true }

        // Chinese users often abbreviate a feed request as “刷 3 条 / 刷五条” without repeating
        // “视频”. Treat that bounded “刷 + item-count” shape as feed semantics so the provider can
        // use coordinate-free gui.feedSample instead of inventing raw swipe coordinates.
        let abbreviatedFeedPattern = #"刷\s*(?:[2-9]|1[0-2]|二|两|兩|三|四|五|六|七|八|九|十|十一|十二)\s*(?:条|條|个|個)"#
        return (try? NSRegularExpression(pattern: abbreviatedFeedPattern)).map {
            $0.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)) != nil
        } ?? false
    }

    static func boundedRepeatedSwipeCount(in request: String) -> Int? {
        let normalized = request.lowercased()
        let actionMarkers = ["swipe", "滑", "刷"]
        guard actionMarkers.contains(where: normalized.contains) else { return nil }
        let finiteMarkers = ["次", "下", "个视频", "條視頻", "条视频", "条", "條", "个", "個", "videos", "times"]
        guard finiteMarkers.contains(where: normalized.contains) else { return nil }

        let digitPattern = #"(?<!\d)([2-9]|1[0-2])\s*(?:次|下|个视频|條視頻|条视频|条|條|个|個|videos?|times?)"#
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
            for suffix in ["次", "下", "个视频", "條視頻", "条视频", "条", "條", "个", "個"] where normalized.contains(token + suffix) {
                return count
            }
        }
        return nil
    }

    static func requiresPostLaunchGUIAction(in request: String) -> Bool {
        if requiresMessageSend(in: request) { return true }
        let normalized = request.lowercased()
        let actionMarkers = [
            "刷", "滑", "滚动", "点赞", "点", "点击", "输入", "发送", "回复", "聊天", "搜索", "选择", "切换",
            "swipe", "scroll", "tap", "type", "send", "reply", "like", "search", "select"
        ]
        return actionMarkers.contains(where: normalized.contains)
    }

    static func requiresMessageSend(in request: String) -> Bool {
        let normalized = request.lowercased()
        let sendMarkers = [
            "发消息", "发送消息", "发微信", "微信发", "给他发", "给她发", "给它发", "发一个", "发一条", "回复",
            "send message", "send a message", "reply"
        ]
        if sendMarkers.contains(where: normalized.contains) { return true }
        let messagingContext = ["微信", "文件传输助手", "联系人", "朋友", "群聊", "聊天", "message", "wechat", "chat"]
        return normalized.contains("发") && messagingContext.contains(where: normalized.contains)
    }

    static func requiresExplicitTapAction(in request: String) -> Bool {
        let normalized = request.lowercased()
        let markers = ["点赞", "点开", "点击", "按一下", "like", "tap", "click"]
        return markers.contains(where: normalized.contains)
    }

    static func requiresNavigationSearch(in request: String) -> Bool {
        let normalized = request.lowercased()
        let markers = ["找", "找到", "查找", "搜索", "搜", "find", "search", "locate"]
        return markers.contains(where: normalized.contains)
    }

    static func requestsLocalDataAccess(in request: String) -> Bool {
        let normalized = request.lowercased()
        let markers = [
            "读取文件", "删除文件", "复制文件", "移动文件", "搜索文件", "文件路径", "文件夹", "目录",
            "json", "plist", "sqlite", "数据库", "container", "local data", "filesystem", "file path", "folder", "directory"
        ]
        return markers.contains(where: normalized.contains)
    }

    static func scopedProviderToolNames(for request: String, availableNames: Set<String>) -> Set<String> {
        let normalized = request.lowercased()
        var prefixes = Set<String>()

        let guiMarkers = [
            "刷视频", "刷几个", "滑", "滚动", "点赞", "点开", "点击", "界面", "屏幕", "截图", "聊天", "发送消息", "发送", "没发送", "未发送", "回复", "输入",
            "swipe", "scroll", "tap", "screenshot", "gui"
        ]
        let likelyNamedAppOpen = normalized.contains("打开") && [
            "微信", "抖音", "小红书", "浏览器", "设置", "相册", "照片", "视频", "app", "应用", "软件"
        ].contains(where: normalized.contains)
        let isGUIRequest = likelyNamedAppOpen || guiMarkers.contains(where: normalized.contains)
        if isGUIRequest {
            prefixes.formUnion(["apps.", "gui.", "interaction.", "capability."])
        }

        // Messaging/contact requests often have useful deterministic data available in the target
        // App container before any GUI action is needed. Keep this exposure deliberately read-only:
        // native discovery may resolve a container, locate/index files, and inspect structured data,
        // but it never grants permission to forge an App's outgoing message by editing its private
        // database. The final state-changing send still belongs to a verified App/GUI/private bridge.
        let messagingMarkers = ["微信", "wechat", "文件传输助手", "联系人", "群聊", "聊天", "发消息", "发送消息", "reply", "message", "chat"]
        let messagingActions = ["找", "搜索", "发", "发送", "回复", "联系", "find", "search", "send", "reply"]
        let shouldExposeNativeMessagingDiscovery = isGUIRequest
            && messagingMarkers.contains(where: normalized.contains)
            && messagingActions.contains(where: normalized.contains)

        if requestsLocalDataAccess(in: request) {
            prefixes.formUnion(["files.", "container.", "data.", "json.", "plist.", "sqlite.", "storage.", "trash.", "capability."])
        }
        if normalized.contains("ipa") || normalized.contains("安装包") {
            prefixes.formUnion(["ipa.", "files.", "capability."])
        }
        if normalized.contains("shell") || normalized.contains("命令行") || normalized.contains("cli") {
            prefixes.formUnion(["advanced.", "capability."])
        }

        guard !prefixes.isEmpty else { return availableNames }
        var scoped = Set(availableNames.filter { name in prefixes.contains(where: name.hasPrefix) })
        // Failure explanation is a local read-only introspection tool and remains useful even when
        // the provider schema is domain-scoped. It never broadens execution authority.
        if availableNames.contains("diagnostics.explainFailure") { scoped.insert("diagnostics.explainFailure") }
        if shouldExposeNativeMessagingDiscovery {
            let nativeReadOnlyDiscovery: Set<String> = [
                "apps.inspect", "container.resolve", "container.list", "container.search",
                "files.list", "files.search", "files.read", "files.stat", "files.metadata", "files.hash",
                "plist.read", "plist.query", "plist.metadata",
                "json.read", "json.query", "json.filter", "json.aggregate",
                "sqlite.discover", "sqlite.tables", "sqlite.schema", "sqlite.query", "sqlite.filter", "sqlite.aggregate", "sqlite.sample",
                "data.localQuery", "storage.analyze"
            ]
            scoped.formUnion(availableNames.intersection(nativeReadOnlyDiscovery))
        }
        return scoped.isEmpty ? availableNames : scoped
    }

    private static func pruningHistoricalObservationAttachments(in messages: [ChatMessage]) -> [ChatMessage] {
        let latestObservationIndex = messages.indices.reversed().first(where: {
            messages[$0].role == .user
                && messages[$0].providerMetadata["internal_observation"] != nil
                && !messages[$0].attachments.isEmpty
        })
        guard let latestObservationIndex else { return messages }

        return messages.enumerated().map { index, message in
            guard index != latestObservationIndex,
                  message.role == .user,
                  message.providerMetadata["internal_observation"] != nil,
                  !message.attachments.isEmpty else { return message }
            var compacted = message
            compacted.attachments = []
            compacted.content = "Historical device screenshot omitted from this provider request; use the newest attached observation for current GUI state."
            compacted.providerMetadata["historical_observation_image"] = "omitted"
            return compacted
        }
    }

    private static func estimatedCharacters(_ message: ChatMessage) -> Int {
        var cost = message.content.count + 32
        cost += message.providerMetadata.reduce(0) { $0 + $1.key.count + $1.value.count }
        cost += message.attachments.reduce(0) { partial, attachment in
            let metadataCost = attachment.filename.count + attachment.path.count + attachment.mimeType.count + 64
            // Provider payloads inline image attachments as Base64. Counting only the local path made
            // a long GUI session look tiny while repeatedly resending multiple historical screenshots.
            // 4/3 approximates Base64 expansion; the small fixed JSON overhead is intentionally rounded up.
            let boundedBytes = max(0, attachment.byteSize)
            let base64Cost = Int(min(Int64(Int.max / 2), ((boundedBytes + 2) / 3) * 4))
            return partial + metadataCost + base64Cost + 256
        }
        return cost
    }
}
