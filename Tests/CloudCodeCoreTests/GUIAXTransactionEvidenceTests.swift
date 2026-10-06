import XCTest
@testable import CloudCodeCore

final class GUIAXTransactionEvidenceTests: XCTestCase {
    private func payload(_ changes: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = [
            "backend": "AXRuntime.position.application", "nodeCount": 2, "semanticNodeCount": 1,
            "automationLeaseActive": false,
            "foregroundVerified": true, "pid": 123, "bundleId": "com.apple.mobiletimer",
            "readStartedAtMS": Date().timeIntervalSince1970 * 1_000 - 100,
            "readFinishedAtMS": Date().timeIntervalSince1970 * 1_000,
            "axLifecycle": ["mode": "one-shot-passive-no-audit-client", "auditClientCreated": false,
                            "globalStateMutated": false, "ownedRootReferenceReleased": true],
            "tree": ["role": "AXApplication", "children": [
                ["role": "AXButton", "label": "安全测试", "identifier": "safe",
                 "frame": ["x": 20, "y": 30, "width": 80, "height": 40]]
            ]]
        ]
        for (key, change) in changes { value[key] = change }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func exit(_ changes: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = [
            "stage": "helper-exit", "helper": "CloudCodeRootHelper", "parentTimeout": false,
            "parentCancelled": false, "waitStatusObserved": true, "reapDeferred": false,
            "processReaped": true,
            "result": 0, "exitCode": 0
        ]
        for (key, change) in changes { value[key] = change }
        return "ordinary diagnostics\n" + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    func testSemanticTreeRequiresObservedCleanPassiveExit() throws {
        XCTAssertTrue(GUIAXTransactionEvidence.validateTree(stdout: try payload(), stderr: try exit(), code: 0))
        XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(), stderr: "", code: 0))
        for change in [["parentTimeout": true], ["parentCancelled": true], ["reapDeferred": true], ["waitStatusObserved": false]] {
            XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(), stderr: try exit(change), code: 0))
        }
    }

    func testCompleteJSONAfterTimeoutOrSignalIsRejected() throws {
        for code in [-7060, -5009, -7089] {
            XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(), stderr: try exit(), code: code))
        }
        XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(), stderr: try exit() + "\ncapture truncated", code: 0))
    }

    func testShellAndUnconfirmedServiceCleanupCannotAdvertiseAX() throws {
        XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(["tree": ["role": "AXApplication"]]), stderr: try exit(), code: 0))
        XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(["semanticNodeCount": 0]), stderr: try exit(), code: 0))
        XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(["axLifecycle": [:]]), stderr: try exit(), code: 0))
        XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(["automationLeaseActive": true]), stderr: try exit(), code: 0))
        XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(["backend": "AccessibilityUI.AXAudit.AXElement"]), stderr: try exit(), code: 0))
    }

    func testStaleOrUnverifiedForegroundCannotSupplyAnAXTarget() throws {
        let invalid: [[String: Any]] = [["foregroundVerified": false], ["pid": 0], ["bundleId": ""],
                                       ["readFinishedAtMS": Date().timeIntervalSince1970 * 1_000 - 5_000]]
        for changes in invalid {
            XCTAssertFalse(GUIAXTransactionEvidence.validateTree(stdout: try payload(changes), stderr: try exit(), code: 0))
        }
    }

    func testAXErrorImmediatelyFallsBackToLocalOCR() async throws {
        struct AXTimeout: Error {}
        var reads = 0
        let result = try await GUIVisibleTextVerifier.verifyWithLocalFallback(assertion: "安全测试", ax: {
            throw AXTimeout()
        }, ocr: {
            reads += 1
            return "安全测试"
        })
        XCTAssertTrue(result.passed)
        XCTAssertEqual(reads, 1)
    }

    func testSufficientAXSkipsOCRAndInsufficientAXUsesOCR() async throws {
        var reads = 0
        let matched = try await GUIVisibleTextVerifier.verifyWithLocalFallback(assertion: "安全测试", ax: { "安全测试" }, ocr: {
            reads += 1
            return ""
        })
        XCTAssertTrue(matched.passed)
        XCTAssertEqual(reads, 0)
        let fallback = try await GUIVisibleTextVerifier.verifyWithLocalFallback(assertion: "安全测试", ax: { "另一元素" }, ocr: {
            reads += 1
            return "安全测试"
        })
        XCTAssertTrue(fallback.passed)
        XCTAssertEqual(reads, 1)
    }

    func testCancellationDoesNotStartAnotherOCRTransaction() async throws {
        var reads = 0
        do {
            _ = try await GUIVisibleTextVerifier.verifyWithLocalFallback(assertion: "安全测试", ax: {
                throw CancellationError()
            }, ocr: { reads += 1; return "安全测试" })
            XCTFail("cancelled AX operation must propagate cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(reads, 0)
    }
}
