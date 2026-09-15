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

    func testVisibleTextMatcherToleratesOCRInsertedSpacingAndPunctuation() throws {
        let elements = [
            LocalPerceptionTextElement(text: "文件 传输·助手", confidence: 0.90, x: 42, y: 188, width: 148, height: 30),
            LocalPerceptionTextElement(text: "订阅号", confidence: 0.92, x: 42, y: 244, width: 82, height: 28)
        ]

        let result = LocalPerceptionTextMatcher.resolve(query: "文件传输助手", mode: .exact, elements: elements)
        guard case .unique(let match) = result else {
            XCTFail("expected compact OCR normalization to recover the visible chat label")
            return
        }
        XCTAssertEqual(match.text, "文件 传输·助手")
    }

    func testVisibleTextMatcherMergesAdjacentSameLineOCRFragmentsWithoutCrossRowGuessing() throws {
        let elements = [
            LocalPerceptionTextElement(text: "文件传输", confidence: 0.91, x: 42, y: 188, width: 88, height: 30),
            LocalPerceptionTextElement(text: "助手", confidence: 0.89, x: 134, y: 189, width: 44, height: 29),
            LocalPerceptionTextElement(text: "文件传输", confidence: 0.95, x: 42, y: 300, width: 88, height: 30),
            LocalPerceptionTextElement(text: "记录", confidence: 0.94, x: 134, y: 301, width: 44, height: 29)
        ]

        let result = LocalPerceptionTextMatcher.resolve(query: "文件传输助手", mode: .exact, elements: elements)
        guard case .unique(let match) = result else {
            XCTFail("expected one bounded same-line merged OCR match")
            return
        }
        XCTAssertEqual(match.text, "文件传输助手")
        XCTAssertEqual(match.x, 42, accuracy: 0.0001)
        XCTAssertEqual(match.width, 136, accuracy: 0.0001)
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

    func testAXTreeTextExtractorMapsSemanticTextAndFrameAndSkipsUnframedNodes() {
        let tree = """
        {"children":[
          {"label":"作者甲","value":"作品说明","frame":{"x":18,"y":560,"width":180,"height":44}},
          {"title":"无坐标节点"},
          {"placeholder":"搜索","frame":{"x":"22","y":"40","width":"120","height":"36"}}
        ]}
        """

        let elements = LocalAXTreeTextExtractor.extract(from: tree, maximumElements: 8)
        XCTAssertEqual(elements.map(\.text), ["作者甲", "作品说明", "搜索"])
        XCTAssertEqual(elements[0].x, 18, accuracy: 0.0001)
        XCTAssertEqual(elements[0].centerY, 582, accuracy: 0.0001)
        XCTAssertFalse(elements.contains(where: { $0.text == "无坐标节点" }))
    }

    func testPerceptionFusionKeepsAXAndDeduplicatesNearbyOCRWhilePreservingOCROnlyText() {
        let ax = [
            LocalPerceptionTextElement(text: "作者甲", confidence: 1, x: 20, y: 560, width: 80, height: 24)
        ]
        let ocr = [
            LocalPerceptionTextElement(text: "作者甲", confidence: 0.83, x: 23, y: 562, width: 78, height: 24),
            LocalPerceptionTextElement(text: "#露营", confidence: 0.75, x: 20, y: 620, width: 72, height: 24)
        ]

        let fused = LocalPerceptionFusion.merge(ax: ax, ocr: ocr)
        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused[0], ax[0], "AX semantic element must win duplicate resolution")
        XCTAssertTrue(fused.contains(where: { $0.text == "#露营" }))
    }

    func testFeedIdentityIsStableAcrossBackendOrderingButChangesWithFeedSemantics() throws {
        let screen = LocalPerceptionScreenSize(width: 390, height: 844)
        let first = [
            LocalPerceptionTextElement(text: "@作者甲", confidence: 0.95, x: 20, y: 570, width: 110, height: 24),
            LocalPerceptionTextElement(text: "今天去露营 #周末", confidence: 0.90, x: 20, y: 610, width: 230, height: 34),
            LocalPerceptionTextElement(text: "1.2万", confidence: 0.93, x: 330, y: 410, width: 46, height: 20),
            LocalPerceptionTextElement(text: "328", confidence: 0.91, x: 332, y: 500, width: 38, height: 20),
            LocalPerceptionTextElement(text: "首页", confidence: 0.99, x: 20, y: 810, width: 40, height: 24)
        ]
        let reorderedSameItem = Array(first.reversed())
        let second = [
            LocalPerceptionTextElement(text: "@作者乙", confidence: 0.95, x: 20, y: 570, width: 110, height: 24),
            LocalPerceptionTextElement(text: "另一条视频", confidence: 0.90, x: 20, y: 610, width: 180, height: 34),
            LocalPerceptionTextElement(text: "2.1万", confidence: 0.93, x: 330, y: 410, width: 46, height: 20),
            LocalPerceptionTextElement(text: "501", confidence: 0.91, x: 332, y: 500, width: 38, height: 20)
        ]

        let identityA = try XCTUnwrap(LocalFeedIdentity.signature(elements: first, screenSize: screen))
        let identityAReordered = try XCTUnwrap(LocalFeedIdentity.signature(elements: reorderedSameItem, screenSize: screen))
        let identityB = try XCTUnwrap(LocalFeedIdentity.signature(elements: second, screenSize: screen))
        XCTAssertEqual(identityA, identityAReordered, "video-frame/backend ordering changes must not manufacture a new feed item")
        XCTAssertNotEqual(identityA, identityB)
        XCTAssertFalse(identityA.contains("首页"))
    }

    func testFeedIdentityRequiresRealSemanticEvidence() {
        let screen = LocalPerceptionScreenSize(width: 390, height: 844)
        let genericOnly = [
            LocalPerceptionTextElement(text: "首页", confidence: 0.99, x: 20, y: 810, width: 40, height: 24),
            LocalPerceptionTextElement(text: "推荐", confidence: 0.99, x: 180, y: 72, width: 40, height: 24),
            LocalPerceptionTextElement(text: "点赞", confidence: 0.99, x: 330, y: 380, width: 40, height: 24),
            LocalPerceptionTextElement(text: "12", confidence: 0.92, x: 332, y: 420, width: 30, height: 20)
        ]
        XCTAssertNil(LocalFeedIdentity.signature(elements: genericOnly, screenSize: screen))
    }
}
