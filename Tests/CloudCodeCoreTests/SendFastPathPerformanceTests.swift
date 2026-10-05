import Foundation
import XCTest
@testable import CloudCodeCore

final class SendFastPathPerformanceTests: XCTestCase {
    func testImmediateProviderFirstTokenFrameworkOverhead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendFastPathPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ToolRegistry(descriptors: [])
        let sessions = SessionStore(root: root.appendingPathComponent("sessions", isDirectory: true))
        let checkpoints = TaskCheckpointStore(fileURL: root.appendingPathComponent("checkpoints.json"))
        let provider = ImmediateTokenProvider()
        let agent = AgentCore(
            provider: provider,
            keyVault: MemoryKeyVault(keys: ["perf-key": "secret"]),
            toolRouter: ToolRouter(registry: registry, executors: []),
            registry: registry,
            capabilityProbe: FastPathFixedCapabilityProbe(profile: CapabilityProfile(records: [])),
            sessionStore: sessions,
            checkpointStore: checkpoints,
            maxToolRounds: 2
        )
        let configuration = ProviderConfiguration(
            name: "fast-path-perf",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "immediate",
            apiKeyReference: "perf-key"
        )

        let clock = ContinuousClock()
        var samplesMS: [Double] = []
        for index in 0..<14 {
            let session = AgentSession(permissionMode: .safe)
            let start = clock.now
            let stream = await agent.send(
                text: "ping-\(index)",
                session: session,
                providerConfiguration: configuration
            )
            var firstTokenMS: Double?
            for try await event in stream {
                if firstTokenMS == nil, case .token = event {
                    let elapsed = start.duration(to: clock.now)
                    firstTokenMS = Double(elapsed.components.seconds) * 1_000
                        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                }
            }
            let observed = try XCTUnwrap(firstTokenMS)
            if index >= 2 { samplesMS.append(observed) }
        }

        let sorted = samplesMS.sorted()
        let median = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        let maximum = sorted.last ?? 0
        print(String(format: "SEND_FAST_PATH_METRICS samples=%d median_ms=%.3f p95_ms=%.3f max_ms=%.3f", sorted.count, median, p95, maximum))
        let calls = await provider.callCount()
        XCTAssertEqual(calls, 14)
    }


    func testRapidStreamHasNoFrameworkStallSpikes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendStreamPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ToolRegistry(descriptors: [])
        let sessions = SessionStore(root: root.appendingPathComponent("sessions", isDirectory: true))
        let checkpoints = TaskCheckpointStore(fileURL: root.appendingPathComponent("checkpoints.json"))
        let provider = BurstTokenProvider(tokenCount: 12_000, token: "abcd")
        let agent = AgentCore(
            provider: provider,
            keyVault: MemoryKeyVault(keys: ["perf-key": "secret"]),
            toolRouter: ToolRouter(registry: registry, executors: []),
            registry: registry,
            capabilityProbe: FastPathFixedCapabilityProbe(profile: CapabilityProfile(records: [])),
            sessionStore: sessions,
            checkpointStore: checkpoints,
            maxToolRounds: 2
        )
        let configuration = ProviderConfiguration(
            name: "stream-perf",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "burst",
            apiKeyReference: "perf-key"
        )

        let clock = ContinuousClock()
        let start = clock.now
        var previousTokenAt: ContinuousClock.Instant?
        var gapsMS: [Double] = []
        var tokenCount = 0
        let stream = await agent.send(
            text: "stream benchmark",
            session: AgentSession(permissionMode: .safe),
            providerConfiguration: configuration
        )
        for try await event in stream {
            if case .token = event {
                let now = clock.now
                if let previousTokenAt {
                    gapsMS.append(milliseconds(previousTokenAt.duration(to: now)))
                }
                previousTokenAt = now
                tokenCount += 1
            }
        }
        let totalMS = milliseconds(start.duration(to: clock.now))
        let sortedGaps = gapsMS.sorted()
        let p95Gap = percentile(sortedGaps, 0.95)
        let p99Gap = percentile(sortedGaps, 0.99)
        let maxGap = sortedGaps.last ?? 0
        print(String(format: "STREAM_SMOOTHNESS_METRICS tokens=%d total_ms=%.3f p95_gap_ms=%.3f p99_gap_ms=%.3f max_gap_ms=%.3f", tokenCount, totalMS, p95Gap, p99Gap, maxGap))
        XCTAssertEqual(tokenCount, 12_000)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }


    func testLongContextImmediateProviderFirstTokenOverhead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LongContextPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ToolRegistry(descriptors: [])
        let sessions = SessionStore(root: root.appendingPathComponent("sessions", isDirectory: true))
        let checkpoints = TaskCheckpointStore(fileURL: root.appendingPathComponent("checkpoints.json"))
        let provider = ImmediateTokenProvider()
        let agent = AgentCore(
            provider: provider,
            keyVault: MemoryKeyVault(keys: ["perf-key": "secret"]),
            toolRouter: ToolRouter(registry: registry, executors: []),
            registry: registry,
            capabilityProbe: FastPathFixedCapabilityProbe(profile: CapabilityProfile(records: [])),
            sessionStore: sessions,
            checkpointStore: checkpoints,
            maxToolRounds: 2
        )
        let configuration = ProviderConfiguration(
            name: "long-context-perf",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "immediate",
            apiKeyReference: "perf-key"
        )

        let payload = String(repeating: "0123456789abcdef", count: 128)
        let clock = ContinuousClock()
        var samplesMS: [Double] = []
        for sample in 0..<7 {
            var session = AgentSession(permissionMode: .safe)
            for index in 0..<80 {
                session.messages.append(ChatMessage(role: .user, content: "u\(sample)-\(index)-\(payload)"))
                session.messages.append(ChatMessage(role: .assistant, content: "a\(sample)-\(index)-\(payload)"))
            }

            let start = clock.now
            let stream = await agent.send(
                text: "long-context-ping-\(sample)",
                session: session,
                providerConfiguration: configuration
            )
            var firstTokenMS: Double?
            for try await event in stream {
                if firstTokenMS == nil, case .token = event {
                    firstTokenMS = milliseconds(start.duration(to: clock.now))
                }
            }
            samplesMS.append(try XCTUnwrap(firstTokenMS))
        }

        let sorted = samplesMS.sorted()
        print(String(format: "LONG_CONTEXT_FAST_PATH_METRICS samples=%d median_ms=%.3f p95_ms=%.3f max_ms=%.3f",
                     sorted.count, percentile(sorted, 0.50), percentile(sorted, 0.95), sorted.last ?? 0))
    }

    func testPacedStreamShowsPersistenceStallSpikes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PacedStreamPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ToolRegistry(descriptors: [])
        let sessions = SessionStore(root: root.appendingPathComponent("sessions", isDirectory: true))
        let checkpoints = TaskCheckpointStore(fileURL: root.appendingPathComponent("checkpoints.json"))
        let provider = PacedTokenProvider(tokenCount: 180, token: "abcd", delayNanoseconds: 20_000_000)
        let agent = AgentCore(
            provider: provider,
            keyVault: MemoryKeyVault(keys: ["perf-key": "secret"]),
            toolRouter: ToolRouter(registry: registry, executors: []),
            registry: registry,
            capabilityProbe: FastPathFixedCapabilityProbe(profile: CapabilityProfile(records: [])),
            sessionStore: sessions,
            checkpointStore: checkpoints,
            maxToolRounds: 2
        )
        let configuration = ProviderConfiguration(
            name: "paced-stream-perf",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "paced",
            apiKeyReference: "perf-key"
        )

        let clock = ContinuousClock()
        let start = clock.now
        var previousTokenAt: ContinuousClock.Instant?
        var gapsMS: [Double] = []
        var tokenCount = 0
        let stream = await agent.send(
            text: "paced stream benchmark",
            session: AgentSession(permissionMode: .safe),
            providerConfiguration: configuration
        )
        for try await event in stream {
            if case .token = event {
                let now = clock.now
                if let previousTokenAt {
                    gapsMS.append(milliseconds(previousTokenAt.duration(to: now)))
                }
                previousTokenAt = now
                tokenCount += 1
            }
        }

        let sorted = gapsMS.sorted()
        print(String(format: "PACED_STREAM_METRICS tokens=%d total_ms=%.3f median_gap_ms=%.3f p95_gap_ms=%.3f p99_gap_ms=%.3f max_gap_ms=%.3f",
                     tokenCount,
                     milliseconds(start.duration(to: clock.now)),
                     percentile(sorted, 0.50),
                     percentile(sorted, 0.95),
                     percentile(sorted, 0.99),
                     sorted.last ?? 0))
        XCTAssertEqual(tokenCount, 180)
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return sorted[index]
    }
}

private struct FastPathFixedCapabilityProbe: CapabilityProbing, Sendable {
    let profile: CapabilityProfile
    func probe() async -> CapabilityProfile { profile }
}



private actor PacedTokenProvider: ProviderStreaming {
    let tokenCount: Int
    let token: String
    let delayNanoseconds: UInt64

    init(tokenCount: Int, token: String, delayNanoseconds: UInt64) {
        self.tokenCount = tokenCount
        self.token = token
        self.delayNanoseconds = delayNanoseconds
    }

    nonisolated func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let (count, value, delay) = await payload()
                for _ in 0..<count {
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.yield(.token(value))
                }
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    private func payload() -> (Int, String, UInt64) {
        (tokenCount, token, delayNanoseconds)
    }
}

private actor BurstTokenProvider: ProviderStreaming {
    let tokenCount: Int
    let token: String

    init(tokenCount: Int, token: String) {
        self.tokenCount = tokenCount
        self.token = token
    }

    nonisolated func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let (count, value) = await payload()
                for _ in 0..<count {
                    continuation.yield(.token(value))
                }
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    private func payload() -> (Int, String) {
        (tokenCount, token)
    }
}

private actor ImmediateTokenProvider: ProviderStreaming {
    private var calls = 0

    nonisolated func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recordCall()
                continuation.yield(.token("OK"))
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    func callCount() -> Int { calls }
    private func recordCall() { calls += 1 }
}
