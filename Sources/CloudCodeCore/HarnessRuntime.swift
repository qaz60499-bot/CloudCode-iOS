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

    private static func estimatedCharacters(_ message: ChatMessage) -> Int {
        var cost = message.content.count + 32
        cost += message.providerMetadata.reduce(0) { $0 + $1.key.count + $1.value.count }
        cost += message.attachments.reduce(0) { $0 + $1.filename.count + $1.path.count + $1.mimeType.count + 64 }
        return cost
    }
}
