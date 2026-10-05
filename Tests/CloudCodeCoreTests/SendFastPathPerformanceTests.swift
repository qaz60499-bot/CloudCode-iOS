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
