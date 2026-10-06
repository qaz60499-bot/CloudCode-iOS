import Foundation
import XCTest
@testable import CloudCodeCore

@MainActor
final class StreamingUIFlushCadenceBenchmarkTests: XCTestCase {
    func testDefaultCadenceUnderSustainedFiveMillisecondUpdates() async throws {
        let sessionID = UUID()
        var publishTimes: [TimeInterval] = []

        let coordinator = StreamingUIFlushCoordinator { _ in
            publishTimes.append(ProcessInfo.processInfo.systemUptime)
        }

        let updateCount = 200
        let updateIntervalNanoseconds: UInt64 = 5_000_000
        let startedAt = ProcessInfo.processInfo.systemUptime

        for _ in 0..<updateCount {
            coordinator.schedule(sessionID: sessionID)
            try await Task.sleep(nanoseconds: updateIntervalNanoseconds)
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        coordinator.cancel(sessionID: sessionID)

        let elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedAt
        let intervalsMS = zip(publishTimes, publishTimes.dropFirst()).map { pair in
            (pair.1 - pair.0) * 1_000
        }
        let sortedIntervals = intervalsMS.sorted()
        let medianIntervalMS: Double
        if sortedIntervals.isEmpty {
            medianIntervalMS = 0
        } else if sortedIntervals.count.isMultiple(of: 2) {
            let middle = sortedIntervals.count / 2
            medianIntervalMS = (sortedIntervals[middle - 1] + sortedIntervals[middle]) / 2
        } else {
            medianIntervalMS = sortedIntervals[sortedIntervals.count / 2]
        }

        let publishRate = elapsedSeconds > 0 ? Double(publishTimes.count) / elapsedSeconds : 0

        print(String(
            format: "UI_FLUSH_CADENCE_METRICS updates=%d elapsed_ms=%.3f publishes=%d publish_rate_hz=%.3f median_publish_gap_ms=%.3f max_publish_gap_ms=%.3f",
            updateCount,
            elapsedSeconds * 1_000,
            publishTimes.count,
            publishRate,
            medianIntervalMS,
            intervalsMS.max() ?? 0
        ))

        XCTAssertGreaterThan(publishTimes.count, 0)
        XCTAssertLessThan(publishTimes.count, updateCount, "high-rate token updates must remain coalesced")
    }
}
