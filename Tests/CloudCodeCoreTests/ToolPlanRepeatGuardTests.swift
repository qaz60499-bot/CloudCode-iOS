import XCTest
@testable import CloudCodeCore

final class ToolPlanRepeatGuardTests: XCTestCase {
    func testDuplicateMutationRequiresObservationBeforeSecondDispatch() {
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "tap", lastExecutedSignature: "tap",
            previouslyBlocked: [], containsMutation: true, finiteRepeatHasVerifiedProgress: false), .reconcileBeforeMutation)
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "tap", lastExecutedSignature: "screenshot",
            previouslyBlocked: ["tap"], containsMutation: true, finiteRepeatHasVerifiedProgress: false), .stop)
    }

    func testRepeatedReadRemainsAvailableForFreshObservation() {
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "screenshot", lastExecutedSignature: "screenshot",
            previouslyBlocked: [], containsMutation: false, finiteRepeatHasVerifiedProgress: false), .execute)
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "screenshot", lastExecutedSignature: "screenshot",
            previouslyBlocked: ["screenshot"], containsMutation: false, finiteRepeatHasVerifiedProgress: false), .execute)
    }

    func testOnlyVerifiedBoundedFiniteProgressPermitsIntentionalRepetition() {
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "scroll", lastExecutedSignature: "scroll",
            previouslyBlocked: [], containsMutation: true, finiteRepeatHasVerifiedProgress: true), .execute)
        XCTAssertEqual(ToolPlanRepeatGuard.decision(signature: "new-route", lastExecutedSignature: "old-route",
            previouslyBlocked: [], containsMutation: true, finiteRepeatHasVerifiedProgress: false), .execute)
    }
}
