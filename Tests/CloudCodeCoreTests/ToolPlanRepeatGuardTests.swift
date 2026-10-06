import XCTest
@testable import CloudCodeCore

final class ToolPlanRepeatGuardTests: XCTestCase {
    func testDuplicateMutationRequiresObservationBeforeSecondDispatch() {
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "tap", lastExecutedSignature: "tap",
            previouslyBlocked: [], containsMutation: true, finiteRepeatHasVerifiedProgress: false), .reconcileBeforeMutation)
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "tap", lastExecutedSignature: "screenshot",
            previouslyBlocked: ["tap"], containsMutation: true, finiteRepeatHasVerifiedProgress: false), .stop)
    }

    func testRepeatedReadChangesRouteWithoutRepeatingOCR() {
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "ocr", lastExecutedSignature: "ocr",
            previouslyBlocked: [], containsMutation: false, finiteRepeatHasVerifiedProgress: false), .changeReadRoute)
    }

    func testOnlyVerifiedBoundedFiniteProgressPermitsIntentionalRepetition() {
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "scroll", lastExecutedSignature: "scroll",
            previouslyBlocked: [], containsMutation: true, finiteRepeatHasVerifiedProgress: true), .execute)
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "new-route", lastExecutedSignature: "old-route",
            previouslyBlocked: [], containsMutation: true, finiteRepeatHasVerifiedProgress: false), .execute)
    }
}
