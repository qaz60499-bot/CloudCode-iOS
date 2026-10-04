import XCTest
@testable import CloudCodeCore

@MainActor
final class StreamingUIFlushCoordinatorTests: XCTestCase {
    func testRapidTokenUpdatesCoalesceAndPublishExactFinalBuffer() async {
        let sessionID = UUID()
        var liveSessions: [UUID: String] = [sessionID: ""]
        var publishedSessions: [UUID: String] = [:]
        var publishCounts: [UUID: Int] = [:]
        let didPublish = expectation(description: "stream publishes")
        didPublish.expectedFulfillmentCount = 1

        let coordinator = StreamingUIFlushCoordinator(intervalNanoseconds: 20_000_000) { sessionID in
            publishedSessions[sessionID] = liveSessions[sessionID]
            publishCounts[sessionID, default: 0] += 1
            didPublish.fulfill()
        }
        let tokens = (0..<1_200).map { "token-\($0) " }

        for token in tokens {
            liveSessions[sessionID, default: ""] += token
            coordinator.schedule(sessionID: sessionID)
        }

        await fulfillment(of: [didPublish], timeout: 1)

        XCTAssertEqual(publishedSessions[sessionID], tokens.joined())
        XCTAssertEqual(publishCounts[sessionID], 1)
    }

    func testFlushPublishesSynchronouslyAtToolFinishAndCancelBoundaries() async throws {
        var liveSessions: [UUID: String] = [:]
        var publishedSessions: [UUID: String] = [:]
        var publishCount = 0
        let coordinator = StreamingUIFlushCoordinator(intervalNanoseconds: 30_000_000) { sessionID in
            publishedSessions[sessionID] = liveSessions[sessionID]
            publishCount += 1
        }

        for (boundary, finalText) in [("tool", "tool output"), ("finished", "final answer"), ("cancel", "partial answer")] {
            let sessionID = UUID()
            liveSessions[sessionID] = finalText
            coordinator.schedule(sessionID: sessionID)

            let previousCount = publishCount
            coordinator.flush(sessionID: sessionID)

            XCTAssertEqual(publishCount, previousCount + 1, "flush should publish synchronously at \(boundary)")
            XCTAssertEqual(publishedSessions[sessionID], finalText)
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(publishCount, 3, "flushed timers must not publish a second time")
    }

    func testSessionsKeepSeparateQueuesAndSelectedSessionGuard() async {
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        var selectedSessionID = firstSessionID
        var liveSessions = [firstSessionID: "first", secondSessionID: "second"]
        var publishedSessions: [UUID: String] = [:]
        var visibleText = ""
        var publishCounts: [UUID: Int] = [:]
        let didPublishBoth = expectation(description: "both sessions publish")
        didPublishBoth.expectedFulfillmentCount = 2

        let coordinator = StreamingUIFlushCoordinator(intervalNanoseconds: 20_000_000) { sessionID in
            publishedSessions[sessionID] = liveSessions[sessionID]
            publishCounts[sessionID, default: 0] += 1
            if sessionID == selectedSessionID {
                visibleText = publishedSessions[sessionID] ?? ""
            }
            didPublishBoth.fulfill()
        }

        coordinator.schedule(sessionID: firstSessionID)
        coordinator.schedule(sessionID: secondSessionID)
        selectedSessionID = secondSessionID

        await fulfillment(of: [didPublishBoth], timeout: 1)

        XCTAssertEqual(publishedSessions[firstSessionID], "first")
        XCTAssertEqual(publishedSessions[secondSessionID], "second")
        XCTAssertEqual(publishCounts[firstSessionID], 1)
        XCTAssertEqual(publishCounts[secondSessionID], 1)
        XCTAssertEqual(visibleText, "second")
    }

    func testCancelSuppressesPendingPublish() async throws {
        let sessionID = UUID()
        var publishCount = 0
        let coordinator = StreamingUIFlushCoordinator(intervalNanoseconds: 20_000_000) { _ in
            publishCount += 1
        }

        coordinator.schedule(sessionID: sessionID)
        coordinator.cancel(sessionID: sessionID)
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(publishCount, 0)
    }

    func testFlushingBoundaryKeepsReplacementTimerPending() async throws {
        let sessionID = UUID()
        var publishCount = 0
        let replacementPublished = expectation(description: "replacement timer publishes")
        let coordinator = StreamingUIFlushCoordinator(intervalNanoseconds: 300_000_000) { _ in
            publishCount += 1
            if publishCount == 2 {
                replacementPublished.fulfill()
            }
        }

        coordinator.schedule(sessionID: sessionID)
        try await Task.sleep(nanoseconds: 180_000_000)
        coordinator.flush(sessionID: sessionID)
        coordinator.schedule(sessionID: sessionID)

        // Pass the old timer's original deadline while leaving time for the replacement timer.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(publishCount, 1)

        await fulfillment(of: [replacementPublished], timeout: 1)
        XCTAssertEqual(publishCount, 2)
    }
}
