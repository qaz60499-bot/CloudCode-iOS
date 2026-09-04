import XCTest

final class CloudCodeLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsAndProviderControlsRemainReachableAfterColdLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20), "设置 Tab 未在启动后出现")
        settingsTab.tap()

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10), "设置页未能稳定打开")
        XCTAssertTrue(app.secureTextFields["替换当前选择的 Key"].waitForExistence(timeout: 10), "Key 输入框不可用")
        XCTAssertTrue(app.buttons["添加自定义厂商"].waitForExistence(timeout: 10), "自定义厂商入口不可用")

        app.buttons["添加自定义厂商"].tap()
        XCTAssertTrue(app.navigationBars["添加厂商"].waitForExistence(timeout: 10), "自定义厂商配置页未能打开")
        XCTAssertTrue(app.textFields["名称"].exists)
        XCTAssertTrue(app.textFields["Base URL"].exists)
        XCTAssertTrue(app.secureTextFields["API Key"].exists)
        app.buttons["取消"].tap()

        let logs = app.buttons["日志"].firstMatch
        XCTAssertTrue(logs.waitForExistence(timeout: 10), "诊断日志入口不可用")
        logs.tap()
        XCTAssertTrue(app.navigationBars["诊断日志"].waitForExistence(timeout: 10), "诊断日志页未能打开")
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
