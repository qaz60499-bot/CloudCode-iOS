import Foundation
import XCTest
@testable import CloudCodeCore

final class SessionCompactionResourceTests: XCTestCase {
    func testUnicodeRecoveryPreservesConversationAndCompactsLargestObservationFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Unicode traversal matters here: the old comparator repeatedly counted every grapheme
        // in large decoded tool observations. The apps.list-only test never reached that sort.
        let sizes = [100_000, 110_000, 90_000, 130_000, 120_000, 140_000, 80_000]
        let messages = [ChatMessage(role: .user, content: "保留原始用户指令")]
            + sizes.enumerated().map { index, size in
                ChatMessage(role: .tool, content: String(repeating: "字👩🏽‍💻e\u{301}", count: size),
                            providerMetadata: ["tool_name": "gui.screenshot", "tool_call_id": "call-\(index)"])
            } + [ChatMessage(role: .assistant, content: "保留助手回复")]
        let session = AgentSession(title: "Unicode recovery", messages: messages, permissionMode: .safe)
        XCTAssertGreaterThan(try JSONEncoder.pretty.encode(session).count, 8 * 1024 * 1024)
        let store = SessionStore(root: root)
        let started = Date()
        try await store.save(session)
        print("RESOURCE_PROBE unicode_session_save_seconds=\(Date().timeIntervalSince(started))")
        let recovered = try await store.load(session.id)
        XCTAssertEqual(recovered.messages.map(\.id), messages.map(\.id))
        XCTAssertEqual(recovered.messages.first?.content, messages.first?.content)
        XCTAssertEqual(recovered.messages.last?.content, messages.last?.content)
        XCTAssertEqual(recovered.messages[6].providerMetadata["storage_compacted"], "true")
        XCTAssertLessThanOrEqual(try JSONEncoder.pretty.encode(recovered).count, 8 * 1024 * 1024)
        for (index, message) in recovered.messages.enumerated() where message.role == .tool {
            XCTAssertEqual(message.providerMetadata["tool_call_id"], messages[index].providerMetadata["tool_call_id"])
            if message.providerMetadata["storage_compacted"] != "true" {
                XCTAssertEqual(message.content, messages[index].content)
            }
        }
    }
}
