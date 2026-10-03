import XCTest
import UIKit

final class CloudCodeLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 1) { return true }
        for _ in 0..<attempts {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return element.exists
    }

    func testChatComposerAcceptsTypingWithoutImplicitSubmit() throws {
        let app = XCUIApplication()
        app.launch()

        let chatTab = app.tabBars.buttons["对话"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 20), "对话 Tab 未在启动后出现")
        chatTab.tap()

        let composer = app.textViews["CloudCodeComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "聊天输入框不可用")
        composer.tap()
        composer.typeText("composer-input-test")

        XCTAssertEqual(composer.value as? String, "composer-input-test", "输入文字后 composer 没有保留文本")
        let send = app.buttons["发送"].firstMatch
        XCTAssertTrue(send.exists && send.isEnabled, "输入文字后发送按钮没有启用")
    }

    func testComposerPasteRemainsEditableAcrossTextFormatsAndSizes() throws {
        let savedClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = savedClipboard }
        let fixtures: [(String, String)] = [
            ("100 characters", String(repeating: "a", count: 100)),
            ("1 KB", String(repeating: "b", count: 1_024)),
            ("10 KB", String(repeating: "c", count: 10_240)),
            ("50 KB", String(repeating: "d", count: 51_200)),
            ("Chinese", String(repeating: "中文粘贴后继续编辑。\n", count: 100)),
            ("English", "A plain English paragraph.\nAnother line."),
            ("Markdown", String(repeating: "# Heading\n\n- item\n\n```swift\nlet n = 1\n```\n", count: 100)),
            ("JSON", "{\"text\":\"中文🙂\",\"items\":[1,2,3]}"),
            ("CRLF", "first\r\nsecond\r\nthird"),
            ("emoji", String(repeating: "🙂👨‍👩‍👧‍👦🇨🇳e\u{301}\n", count: 100))
        ]
        let app = XCUIApplication()

        for (name, payload) in fixtures {
            app.launch()
            let chat = app.tabBars.buttons["对话"]
            XCTAssertTrue(chat.waitForExistence(timeout: 20), name)
            chat.tap()
            let composer = app.textViews["CloudCodeComposer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10), name)
            composer.tap()
            UIPasteboard.general.string = payload
            composer.press(forDuration: 1.1)
            let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "粘贴"])).firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5), "Paste menu: \(name)")
            paste.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allowPaste = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow Paste", "允许粘贴"])).firstMatch
            if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
            let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", payload), object: composer)
            XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 10), .completed, "Paste contents: \(name)")
            composer.typeText("z")
            XCTAssertEqual(composer.value as? String, payload + "z", "Edit after paste: \(name)")
            composer.typeText(XCUIKeyboardKey.delete.rawValue)
            XCTAssertEqual(composer.value as? String, payload, "Delete after paste: \(name)")
            let send = app.buttons["发送"].firstMatch
            XCTAssertTrue(send.exists && send.isEnabled, "Send remains available: \(name)")
            let dismissKeyboard = app.buttons["CloudCodeDismissKeyboard"]
            XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5), "Keyboard dismissal available: \(name)")
            dismissKeyboard.tap()
            app.tabBars.buttons["设置"].tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "Navigation responsive: \(name)")
            app.terminate()
        }
    }

    func testSettingsAndProviderControlsRemainReachableAfterColdLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20), "设置 Tab 未在启动后出现")
        settingsTab.tap()

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10), "设置页未能稳定打开")
        XCTAssertTrue(app.secureTextFields["替换当前选择的 Key"].waitForExistence(timeout: 10), "Key 输入框不可用")
        let addProvider = app.buttons["添加自定义厂商"]
        XCTAssertTrue(reveal(addProvider, in: app), "自定义厂商入口不可用")

        addProvider.tap()
        XCTAssertTrue(app.navigationBars["添加厂商"].waitForExistence(timeout: 10), "自定义厂商配置页未能打开")
        XCTAssertTrue(app.textFields["名称"].exists)
        XCTAssertTrue(app.textFields["Base URL"].exists)
        XCTAssertTrue(app.secureTextFields["API Key"].exists)
        app.buttons["取消"].tap()

        let logs = app.buttons["日志"].firstMatch
        XCTAssertTrue(reveal(logs, in: app), "诊断日志入口不可用")
        logs.tap()
        XCTAssertTrue(app.navigationBars["诊断日志"].waitForExistence(timeout: 10), "诊断日志页未能打开")
    }

    func testResourceExplorerStartsFromVirtualCategoriesWithoutOpeningAPath() throws {
        let app = XCUIApplication()
        app.launch()

        let moreTab = app.tabBars.buttons["更多"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 20), "更多 Tab 未在启动后出现")
        moreTab.tap()

        let files = app.buttons["文件"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "Resource Explorer 入口不可用")
        files.tap()

        XCTAssertTrue(app.navigationBars["资源"].waitForExistence(timeout: 10), "Resource Explorer 未能打开")
        XCTAssertTrue(app.staticTexts["应用"].waitForExistence(timeout: 5), "首屏没有应用虚拟分类")
        XCTAssertTrue(app.staticTexts["用户文件"].exists)
        XCTAssertTrue(app.staticTexts["系统"].exists)
        XCTAssertFalse(app.textFields["路径"].exists, "Explorer 首屏不应恢复为路径输入并自动打开目录的旧模式")
    }

    func testRepeatedRelaunchKeepsRootNavigationUsable() throws {
        let app = XCUIApplication()

        for iteration in 1...4 {
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["对话"].waitForExistence(timeout: 20), "第 \(iteration) 次启动后对话 Tab 不可用")
            XCTAssertTrue(app.tabBars.buttons["设置"].exists, "第 \(iteration) 次启动后设置 Tab 不可用")
            app.terminate()
        }
    }
}
