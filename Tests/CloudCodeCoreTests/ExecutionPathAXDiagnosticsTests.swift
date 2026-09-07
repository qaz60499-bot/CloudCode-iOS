import Foundation
import XCTest
@testable import CloudCodeCore

final class ExecutionPathAXDiagnosticsTests: XCTestCase {
    func testAXExecutionMetricUsesBackendLatencyFromPayload() async throws {
        let metrics = ExecutionPathMetrics(maximumCount: 16)
        let registry = ToolRegistry(descriptors: [
            ToolDescriptor(name: "gui.tree", summary: "", risk: .readOnly, preferredRoute: .guiFallback)
        ])
        let router = ToolRouter(
            registry: registry,
            executors: [AXMetricExecutor(mode: .success)],
            executionPathMetrics: metrics
        )
        let context = ToolExecutionContext(permissionMode: .safe, capabilityProfile: CapabilityProfile(records: []))

        let result = try await router.execute(ToolCall(name: "gui.tree", arguments: [:], sessionID: UUID()), context: context)
        XCTAssertTrue(result.success)

        let recorded = await router.recentExecutionPathMetrics(limit: 10)
        let metric = try XCTUnwrap(recorded.last)
        XCTAssertEqual(metric.tool, "gui.tree")
        XCTAssertEqual(metric.selectedRoute, .guiFallback)
        XCTAssertEqual(metric.axAttempted, true)
        XCTAssertEqual(metric.axSucceeded, true)
        XCTAssertEqual(metric.axLatencyMS, 7, "AX telemetry must preserve backend latency instead of replacing it with whole-tool latency")
    }

    func testAXToolLogPreservesStageScopeAndBackendLatencyMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCode-AXMetric-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logStore = DiagnosticLogStore(directory: root)
        let registry = ToolRegistry(descriptors: [
            ToolDescriptor(name: "gui.tree", summary: "", risk: .readOnly, preferredRoute: .guiFallback)
        ])
        let router = ToolRouter(
            registry: registry,
            executors: [AXMetricExecutor(mode: .success)],
            diagnosticLogger: logStore,
            executionPathMetrics: ExecutionPathMetrics(maximumCount: 16)
        )
        let sessionID = UUID()
        let context = ToolExecutionContext(permissionMode: .safe, capabilityProfile: CapabilityProfile(records: []))

        _ = try await router.execute(ToolCall(name: "gui.tree", arguments: [:], sessionID: sessionID), context: context)

        let records = try await logStore.recent(sessionID: sessionID, limit: 20)
        let record = try XCTUnwrap(records.last(where: { $0.action == "gui.tree" && $0.result == "completed" }))
        XCTAssertEqual(record.metadata["axBackend"], "standalone_trollstore_axruntime")
        XCTAssertEqual(record.metadata["axStage"], "direct_root_then_sampled_hit_test")
        XCTAssertEqual(record.metadata["axScope"], "sampled_semantics")
        XCTAssertEqual(record.metadata["axLatencyMS"], "7")
    }

    func testThrowingAXExecutorStillRecordsAttemptAndLatency() async throws {
        let metrics = ExecutionPathMetrics(maximumCount: 16)
        let registry = ToolRegistry(descriptors: [
            ToolDescriptor(name: "gui.tree", summary: "", risk: .readOnly, preferredRoute: .guiFallback)
        ])
        let router = ToolRouter(
            registry: registry,
            executors: [AXMetricExecutor(mode: .failure)],
            executionPathMetrics: metrics
        )
        let context = ToolExecutionContext(permissionMode: .safe, capabilityProfile: CapabilityProfile(records: []))

        do {
            _ = try await router.execute(ToolCall(name: "gui.tree", arguments: [:], sessionID: UUID()), context: context)
            XCTFail("expected bounded AX failure")
        } catch {
            // Expected: metrics must still retain the attempted AX path.
        }

        let recorded = await router.recentExecutionPathMetrics(limit: 10)
        let metric = try XCTUnwrap(recorded.last)
        XCTAssertEqual(metric.tool, "gui.tree")
        XCTAssertEqual(metric.outcome, "failed")
        XCTAssertEqual(metric.axAttempted, true)
        XCTAssertNil(metric.axSucceeded)
        XCTAssertNotNil(metric.axLatencyMS)
        XCTAssertGreaterThanOrEqual(metric.axLatencyMS ?? -1, 0)
    }
}

private struct AXMetricExecutor: ToolExecuting, Sendable {
    enum Mode: Sendable {
        case success
        case failure
    }

    let mode: Mode
    let route: AppExecutionRoute = .guiFallback

    func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        tool.name == "gui.tree"
    }

    func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        switch mode {
        case .success:
            return ToolResult(
                toolCallID: call.id,
                success: true,
                summary: "mock AX tree",
                payload: [
                    "perceptionAXAttempted": "true",
                    "perceptionAXSucceeded": "true",
                    "axBackend": "standalone_trollstore_axruntime",
                    "axStage": "direct_root_then_sampled_hit_test",
                    "axScope": "sampled_semantics",
                    "axLatencyMS": "7"
                ]
            )
        case .failure:
            throw ToolRouterError.noExecutionRoute("bounded AX timeout")
        }
    }
}
