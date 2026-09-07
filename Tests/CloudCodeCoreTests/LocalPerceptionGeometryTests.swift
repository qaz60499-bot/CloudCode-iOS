import Foundation
import XCTest
@testable import CloudCodeCore

final class LocalPerceptionGeometryTests: XCTestCase {
    func testHelperElementJSONParsesIntoBoundedTextElement() throws {
        let data = Data("""
        [{"text":"文件传输助手","confidence":0.91,"x":24.5,"y":180.0,"width":132.0,"height":34.0}]
        """.utf8)

        let elements = try JSONDecoder().decode([LocalPerceptionTextElement].self, from: data)

        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "文件传输助手")
        XCTAssertEqual(elements[0].confidence, 0.91, accuracy: 0.0001)
        XCTAssertEqual(elements[0].centerX, 90.5, accuracy: 0.0001)
        XCTAssertEqual(elements[0].centerY, 197.0, accuracy: 0.0001)
    }

    func testVisionLowerLeftNormalizedBoxConvertsToTopLeftScreenPoints() throws {
        let rect = try XCTUnwrap(LocalPerceptionGeometry.topLeftScreenRect(
            normalizedLowerLeftX: 0.25,
            y: 0.10,
            width: 0.50,
            height: 0.20,
            screenWidth: 400,
            screenHeight: 800
        ))

        XCTAssertEqual(rect.x, 100, accuracy: 0.0001)
        XCTAssertEqual(rect.y, 560, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 200, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 160, accuracy: 0.0001)
    }

    func testVisibleTextMatcherFindsUniqueWeChatTransferAssistantIncludingLineFragment() throws {
        let elements = [
            LocalPerceptionTextElement(text: "微信 文件传输助手", confidence: 0.94, x: 24, y: 180, width: 180, height: 30),
            LocalPerceptionTextElement(text: "订阅号", confidence: 0.91, x: 24, y: 240, width: 90, height: 28)
        ]

        let result = LocalPerceptionTextMatcher.resolve(query: "文件传输助手", mode: .exact, elements: elements)

        guard case .unique(let match) = result else {
            XCTFail("expected exactly one current-frame OCR match")
            return
        }
        XCTAssertEqual(match.text, "微信 文件传输助手")
        XCTAssertEqual(match.centerX, 114, accuracy: 0.0001)
    }

    func testVisibleTextMatcherDistinguishesMissingAndAmbiguousTargets() {
        let duplicated = [
            LocalPerceptionTextElement(text: "文件传输助手", confidence: 0.96, x: 20, y: 100, width: 140, height: 28),
            LocalPerceptionTextElement(text: "文件传输助手", confidence: 0.93, x: 20, y: 160, width: 140, height: 28)
        ]

        XCTAssertEqual(LocalPerceptionTextMatcher.resolve(query: "不存在", mode: .exact, elements: duplicated), .notFound)
        XCTAssertEqual(LocalPerceptionTextMatcher.resolve(query: "文件传输助手", mode: .exact, elements: duplicated), .ambiguous(2))
    }

    func testVisionBoxIsClampedToScreenBoundsAndInvalidBoxesFailClosed() throws {
        let rect = try XCTUnwrap(LocalPerceptionGeometry.topLeftScreenRect(
            normalizedLowerLeftX: -0.05,
            y: 0.90,
            width: 0.25,
            height: 0.20,
            screenWidth: 300,
            screenHeight: 600
        ))

        XCTAssertEqual(rect.x, 0, accuracy: 0.0001)
        XCTAssertEqual(rect.y, 0, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 60, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 60, accuracy: 0.0001)

        XCTAssertNil(LocalPerceptionGeometry.topLeftScreenRect(
            normalizedLowerLeftX: 1.2,
            y: 0.2,
            width: 0.1,
            height: 0.1,
            screenWidth: 300,
            screenHeight: 600
        ))
        XCTAssertNil(LocalPerceptionGeometry.topLeftScreenRect(
            normalizedLowerLeftX: 0.2,
            y: 0.2,
            width: 0,
            height: 0.1,
            screenWidth: 300,
            screenHeight: 600
        ))
    }
}
