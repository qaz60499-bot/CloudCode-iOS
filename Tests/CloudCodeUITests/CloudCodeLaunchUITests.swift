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

    func testComposerCanDismissRefocusAndContinueSending() throws {
        let app = XCUIApplication()
        app.launch()

        let chatTab = app.tabBars.buttons["对话"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 20), "对话 Tab 未在启动后出现")
        chatTab.tap()

        let composer = app.textViews["CloudCodeComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "聊天输入框不可用")
        let keyboard = app.keyboards.firstMatch
        composer.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "首次聚焦后键盘未出现")
        composer.typeText("a")
        XCTAssertEqual(composer.value as? String, "a", "首次短输入未进入 composer")
        composer.typeText("b")
        XCTAssertEqual(composer.value as? String, "ab", "重复短输入后 composer 内容不正确")

        let dismissKeyboard = app.buttons["CloudCodeDismissKeyboard"].firstMatch
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5), "收起键盘按钮不可用")
        dismissKeyboard.tap()
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed, "点击收起后键盘仍然存在")

        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "再次聚焦后键盘未出现")
        composer.typeText("cd")
        XCTAssertEqual(composer.value as? String, "abcd", "再次聚焦后无法继续输入")

        let send = app.buttons["发送"].firstMatch
        XCTAssertTrue(send.exists && send.isEnabled, "继续输入后发送按钮没有启用")
        send.tap()
        let composerCleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", ""),
            object: composer
        )
        XCTAssertEqual(XCTWaiter.wait(for: [composerCleared], timeout: 5), .completed, "发送后 composer 没有及时清空")
        XCTAssertTrue(app.staticTexts["abcd"].firstMatch.waitForExistence(timeout: 5), "发送后用户消息气泡没有出现")

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "设置 Tab 不可用")
        let dismissAfterSend = app.buttons["CloudCodeDismissKeyboard"].firstMatch
        if dismissAfterSend.waitForExistence(timeout: 2) {
            dismissAfterSend.tap()
            let keyboardHiddenAfterSend = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: app.keyboards.firstMatch
            )
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardHiddenAfterSend], timeout: 5), .completed, "发送后无法收起键盘以切换 Tab")
        }
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "设置页无法打开")
        chatTab.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "返回对话后 composer 不可用")
        composer.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "返回对话后键盘未出现")
        composer.typeText("e")
        XCTAssertEqual(composer.value as? String, "e", "切换设置再返回后 composer 无法继续输入")
    }

    func testComposerOperationSmoothnessBenchmark() throws {
        let app = XCUIApplication()
        let uptime = { ProcessInfo.processInfo.systemUptime }
        let ms = { (start: TimeInterval) in (uptime() - start) * 1_000.0 }
        let median: ([Double]) -> Double = { values in
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2
                : sorted[middle]
        }

        let launchStart = uptime()
        app.launch()
        let chatTab = app.tabBars.buttons["对话"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 20), "对话 Tab 未在启动后出现")
        let launchReadyMS = ms(launchStart)
        chatTab.tap()

        let composer = app.textViews["CloudCodeComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "聊天输入框不可用")
        let keyboard = app.keyboards.firstMatch
        let dismissKeyboard = app.buttons["CloudCodeDismissKeyboard"].firstMatch
        let send = app.buttons["发送"].firstMatch
        let settingsTab = app.tabBars.buttons["设置"]

        var focusSamples: [Double] = []
        var typeSamples: [Double] = []
        var dismissSamples: [Double] = []
        var refocusSamples: [Double] = []
        var sendClearSamples: [Double] = []
        var bubbleSamples: [Double] = []
        var navigationSamples: [Double] = []

        for round in 1...6 {
            let payload = "ui-bench-\(round)-abcdefgh"

            let focusStart = uptime()
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)).tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "第 \(round) 轮首次聚焦后键盘未出现")
            focusSamples.append(ms(focusStart))

            let typeStart = uptime()
            composer.typeText(payload)
            XCTAssertEqual(composer.value as? String, payload, "第 \(round) 轮输入后内容不一致")
            typeSamples.append(ms(typeStart))

            let dismissStart = uptime()
            XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5), "第 \(round) 轮收起键盘按钮不可用")
            dismissKeyboard.tap()
            let keyboardHidden = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: keyboard
            )
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed, "第 \(round) 轮键盘未收起")
            dismissSamples.append(ms(dismissStart))

            let refocusStart = uptime()
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)).tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "第 \(round) 轮再次聚焦后键盘未出现")
            refocusSamples.append(ms(refocusStart))
            composer.typeText("z")
            let finalPayload = payload + "z"
            XCTAssertEqual(composer.value as? String, finalPayload, "第 \(round) 轮再次输入后内容不一致")
            XCTAssertTrue(send.exists && send.isEnabled, "第 \(round) 轮发送按钮不可用")

            let sendStart = uptime()
            send.tap()
            let cleared = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", ""),
                object: composer
            )
            XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed, "第 \(round) 轮发送后输入框未清空")
            sendClearSamples.append(ms(sendStart))
            XCTAssertTrue(app.staticTexts[finalPayload].firstMatch.waitForExistence(timeout: 5), "第 \(round) 轮用户消息未出现")
            bubbleSamples.append(ms(sendStart))

            if round == 1 || round == 6 {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "ui-ops-round-\(round)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            if round.isMultiple(of: 2) {
                if dismissKeyboard.waitForExistence(timeout: 1) {
                    dismissKeyboard.tap()
                }
                let navigationStart = uptime()
                XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "第 \(round) 轮设置 Tab 不可用")
                settingsTab.tap()
                XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "第 \(round) 轮设置页未打开")
                chatTab.tap()
                XCTAssertTrue(composer.waitForExistence(timeout: 5), "第 \(round) 轮返回对话后输入框不可用")
                navigationSamples.append(ms(navigationStart))
            }

            print(String(format:
                "UI_OP_BENCHMARK round=%d focus_ms=%.3f type_ms=%.3f dismiss_ms=%.3f refocus_ms=%.3f send_clear_ms=%.3f bubble_ms=%.3f",
                round,
                focusSamples.last ?? 0,
                typeSamples.last ?? 0,
                dismissSamples.last ?? 0,
                refocusSamples.last ?? 0,
                sendClearSamples.last ?? 0,
                bubbleSamples.last ?? 0
            ))
        }

        func summary(_ name: String, _ values: [Double]) {
            print(String(format:
                "UI_OP_SUMMARY %@ median_ms=%.3f max_ms=%.3f samples=%d",
                name,
                median(values),
                values.max() ?? 0,
                values.count
            ))
        }

        print(String(format: "UI_OP_SUMMARY launch_ready_ms=%.3f", launchReadyMS))
        summary("focus", focusSamples)
        summary("typing", typeSamples)
        summary("dismiss", dismissSamples)
        summary("refocus", refocusSamples)
        summary("send_clear", sendClearSamples)
        summary("bubble", bubbleSamples)
        summary("settings_roundtrip", navigationSamples)
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
