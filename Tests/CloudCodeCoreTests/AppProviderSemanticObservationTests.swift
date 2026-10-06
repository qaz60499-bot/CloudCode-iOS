import XCTest
@testable import CloudCodeCore

final class AppProviderSemanticObservationTests: XCTestCase {
    func testStructuredElementsPreserveRoleAndIdentifier() {
        let tree = #"{"tree":{"children":[{"role":"TextField","identifier":"provider.composer","label":"Ask anything","frame":{"x":10,"y":20,"width":200,"height":40}}]}}"#

        let elements = GUIElementResolver.elements(in: tree)

        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].role, "TextField")
        XCTAssertEqual(elements[0].identifier, "provider.composer")
        XCTAssertEqual(elements[0].label, "Ask anything")
        XCTAssertEqual(elements[0].frame, GUIElementFrame(x: 10, y: 20, width: 200, height: 40))
    }

    func testElementsRemainBoundedAndExistingFindKeepsAmbiguity() {
        let tree = #"{"children":[{"role":"Button","identifier":"send.one","label":"Send","frame":{"x":1,"y":2,"width":30,"height":20}},{"role":"Button","identifier":"send.two","label":"Send","frame":{"x":40,"y":2,"width":30,"height":20}}]}"#

        let elements = GUIElementResolver.elements(in: tree, maximumElements: 1)

        XCTAssertEqual(elements.count, 1)
        XCTAssertNil(GUIElementResolver.uniqueMatch(in: tree, query: "Send", role: "Button"))
        XCTAssertTrue(GUIElementResolver.find(in: tree, query: "Send", role: "TextField").isEmpty)
    }

    func testIdentifierSelectorRequiresTheActualIdentifierField() {
        let elements = GUIElementResolver.elements(in: #"{"children":[{"role":"TextField","identifier":"provider.composer","label":"Ask anything","frame":{"x":10,"y":20,"width":200,"height":40}}]}"#)

        XCTAssertNotNil(GUIElementResolver.semanticMatch(
            selector: AppProviderSelector(strategy: .accessibilityIdentifier, value: "provider.composer"),
            elements: elements
        ))
        XCTAssertNil(GUIElementResolver.semanticMatch(
            selector: AppProviderSelector(strategy: .accessibilityIdentifier, value: "Ask anything"),
            elements: elements
        ))
    }

    func testRoleOnlySelectorUsesActualRoleAndRejectsWrongRole() {
        let elements = GUIElementResolver.elements(in: #"{"children":[{"role":"TextField","label":"Ask anything","frame":{"x":10,"y":20,"width":200,"height":40}}]}"#)

        XCTAssertNotNil(GUIElementResolver.semanticMatch(
            selector: AppProviderSelector(strategy: .axRole, role: "TextField"),
            elements: elements
        ))
        XCTAssertNil(GUIElementResolver.semanticMatch(
            selector: AppProviderSelector(strategy: .axRole, role: "Button"),
            elements: elements
        ))
    }

    func testSemanticLabelRequiresUniqueMatchAndHonorsRoleConstraint() {
        let oneElement = GUIElementResolver.elements(in: #"{"children":[{"role":"Button","label":"Send","frame":{"x":1,"y":2,"width":30,"height":20}}]}"#)
        let duplicateElements = GUIElementResolver.elements(in: #"{"children":[{"role":"Button","label":"Send","frame":{"x":1,"y":2,"width":30,"height":20}},{"role":"Button","label":"Send","frame":{"x":40,"y":2,"width":30,"height":20}}]}"#)

        XCTAssertNotNil(GUIElementResolver.semanticMatch(
            selector: AppProviderSelector(strategy: .semanticLabel, value: "Send", role: "Button"),
            elements: oneElement
        ))
        XCTAssertNil(GUIElementResolver.semanticMatch(
            selector: AppProviderSelector(strategy: .semanticLabel, value: "Send", role: "TextField"),
            elements: oneElement
        ))
        XCTAssertEqual(GUIElementResolver.semanticMatches(
            selector: AppProviderSelector(strategy: .semanticLabel, value: "Send"),
            elements: duplicateElements
        )?.count, 2)
        XCTAssertNil(GUIElementResolver.semanticMatch(
            selector: AppProviderSelector(strategy: .semanticLabel, value: "Send"),
            elements: duplicateElements
        ))
    }
}
