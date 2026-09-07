import XCTest

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
