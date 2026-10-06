import Foundation
import XCTest
@testable import CloudCodeCore

final class ProviderContinuationBoundaryTests: XCTestCase {
    func testRecordUpsertsSameAssistantMessageAcrossBoundaries() throws {
        let messageID = UUID()
        var session = AgentSession(messages: [ChatMessage(
            id: messageID,
            role: .assistant,
            content: "old output",
            providerMetadata: ["other": "preserved"]
        )])
        var payload: [String: String] = [:]

        ProviderContinuationBoundary.record(
            text: "durable output",
            messageID: messageID,
            session: &session,
            payload: &payload,
            interrupted: true
        )
        ProviderContinuationBoundary.record(
            text: "durable output",
            messageID: messageID,
            session: &session,
            payload: &payload,
            interrupted: true
        )

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].id, messageID)
        XCTAssertEqual(session.messages[0].role, .assistant)
        XCTAssertEqual(session.messages[0].content, "durable output")
        XCTAssertEqual(session.messages[0].providerMetadata["other"], "preserved")
        XCTAssertEqual(session.messages[0].providerMetadata["provider_partial_output"], "true")
        XCTAssertEqual(payload["provider.continuation.pending"], "true")

        ProviderContinuationBoundary.record(
            text: "durable output complete",
            messageID: messageID,
            session: &session,
            payload: &payload,
            interrupted: false
        )

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].content, "durable output complete")
        XCTAssertNil(session.messages[0].providerMetadata["provider_partial_output"])
        XCTAssertEqual(payload["provider.continuation.pending"], "false")
    }

    func testEveryOneOfOneThousandCumulativeDeltasRemainsInMessage() throws {
        let messageID = UUID()
        var session = AgentSession()
        var payload: [String: String] = [:]
        var completeText = ""

        for _ in 0..<1_000 {
            completeText += "x"
            ProviderContinuationBoundary.record(
                text: completeText,
                messageID: messageID,
                session: &session,
                payload: &payload,
                interrupted: true
            )
        }

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].content, completeText)
        XCTAssertEqual(payload["provider.partial.characters"], "1000")
        XCTAssertEqual(payload["provider.partial.utf8Bytes"], "1000")
    }

    func testPersistedTailIsBoundedByUTF8Bytes() throws {
        let messageID = UUID()
        let text = String(repeating: "🙂", count: 600)
        var session = AgentSession()
        var payload: [String: String] = [:]

        ProviderContinuationBoundary.record(
            text: text,
            messageID: messageID,
            session: &session,
            payload: &payload,
            interrupted: true
        )

        let tail = try XCTUnwrap(payload["provider.partial.tail"])
        XCTAssertLessThanOrEqual(tail.utf8.count, 2_048)
        XCTAssertEqual(tail, String(repeating: "🙂", count: 512))
    }

    func testForgedOrMissingFingerprintDoesNotProduceContinuationHint() throws {
        let messageID = UUID()
        var session = AgentSession()
        var payload: [String: String] = [:]
        ProviderContinuationBoundary.record(
            text: "partial answer",
            messageID: messageID,
            session: &session,
            payload: &payload,
            interrupted: true
        )

        var forgedPayload = payload
        forgedPayload["provider.partial.fingerprint"] = String(repeating: "0", count: 64)
        XCTAssertNil(ProviderContinuationBoundary.continuationHint(session: session, payload: forgedPayload))

        var missingHashPayload = payload
        missingHashPayload.removeValue(forKey: "provider.partial.fingerprint")
        XCTAssertNil(ProviderContinuationBoundary.continuationHint(session: session, payload: missingHashPayload))
    }

    func testCompletedBoundaryDoesNotProduceContinuationHint() throws {
        let messageID = UUID()
        var session = AgentSession()
        var payload: [String: String] = [:]
        ProviderContinuationBoundary.record(
            text: "complete answer",
            messageID: messageID,
            session: &session,
            payload: &payload,
            interrupted: false
        )

        XCTAssertNil(ProviderContinuationBoundary.continuationHint(session: session, payload: payload))
    }

    func testEmptyTextLeavesSessionAndPayloadUnchanged() {
        var session = AgentSession()
        var payload = ["existing": "value"]

        ProviderContinuationBoundary.record(
            text: "",
            messageID: UUID(),
            session: &session,
            payload: &payload,
            interrupted: true
        )

        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(payload, ["existing": "value"])
    }

    func testSnapshotEncodeDecodeRestoresValidatedContinuationHint() throws {
        struct Snapshot: Codable {
            var session: AgentSession
            var payload: [String: String]
        }

        let messageID = UUID()
        var session = AgentSession()
        var payload: [String: String] = [:]
        ProviderContinuationBoundary.record(
            text: "durable answer prefix",
            messageID: messageID,
            session: &session,
            payload: &payload,
            interrupted: true
        )
        let originalHint = try XCTUnwrap(ProviderContinuationBoundary.continuationHint(session: session, payload: payload))

        let snapshotData = try JSONEncoder().encode(Snapshot(session: session, payload: payload))
        let restoredSnapshot = try JSONDecoder().decode(Snapshot.self, from: snapshotData)
        let restoredHint = try XCTUnwrap(ProviderContinuationBoundary.continuationHint(
            session: restoredSnapshot.session,
            payload: restoredSnapshot.payload
        ))

        XCTAssertEqual(restoredHint, originalHint)
        XCTAssertTrue(restoredHint.contains("Continue with only a new suffix"))
        XCTAssertTrue(restoredHint.contains("observe and reconcile state"))
    }
}
