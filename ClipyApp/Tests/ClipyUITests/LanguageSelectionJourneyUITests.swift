import AppKit
import XCTest

/// Select the product's language preference through its real control. Apple
/// language arguments establish the System baseline; they never set the Clipy
/// preference, so reopening the same app proves that the selection persisted.
final class LanguageSelectionJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testLanguageChangesAcrossSettingsHistoryAutomationAndPanelAndSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        // No capture or pasteboard writes are required to inspect these real
        // controls. An empty, isolated history also keeps their layout stable.
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "denied"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(panel(in: app).waitForExistence(timeout: 20), app.debugDescription)

        openSettings(in: app)
        chooseLanguage("English", in: app)
        assertSettingsContent(.english, in: app)
        closeSettingsAndAssertPanel(.english, in: app)

        openSettings(in: app)
        chooseLanguage("简体中文", in: app)
        assertSettingsContent(.simplifiedChinese, in: app)
        closeSettingsAndAssertPanel(.simplifiedChinese, in: app)

        // Retain the same application's defaults domain and physical store,
        // while discarding all process-local SwiftUI state.
        app.terminate()
        app.launch()
        XCTAssertTrue(panel(in: app).waitForExistence(timeout: 20), app.debugDescription)
        assertStoppedPanel(.simplifiedChinese, in: app)
        openSettings(in: app)
        selectCategory("general", in: app)
        assertLanguageSelection("简体中文", in: app)
        assertSettingsContent(.simplifiedChinese, in: app)

        chooseLanguage("跟随系统", in: app)
        assertLanguageSelection("Follow System", in: app)
        assertSettingsContent(.english, in: app)
        closeSettingsAndAssertPanel(.english, in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(panel(in: app).waitForExistence(timeout: 20), app.debugDescription)
        assertStoppedPanel(.english, in: app)
        openSettings(in: app)
        selectCategory("general", in: app)
        assertLanguageSelection("Follow System", in: app)
        assertLabel("clipy.settings.category.general", equals: "General", within: app, in: app)
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["clipy.settings.category.general"].waitForExistence(timeout: 10),
                      app.debugDescription)
    }

    @MainActor
    private func selectCategory(_ category: String, in app: XCUIApplication) {
        let control = app.buttons["clipy.settings.category." + category]
        XCTAssertTrue(control.waitForExistence(timeout: 10), app.debugDescription)
        control.click()
    }

    @MainActor
    private func chooseLanguage(_ title: String, in app: XCUIApplication) {
        selectCategory("general", in: app)
        let picker = app.popUpButtons["clipy.settings.language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        SettingsJourneyControls.scroll(picker, into: app.scrollViews.containing(
            .any, identifier: picker.identifier
        ).firstMatch, app: app)
        picker.click()
        let option = picker.menuItems[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.click()
        let selectedTitle = title == "跟随系统" ? "Follow System" : title
        assertLanguageSelection(selectedTitle, in: app)
    }

    @MainActor
    private func assertLanguageSelection(_ title: String, in app: XCUIApplication) {
        let picker = app.popUpButtons["clipy.settings.language"]
        XCTAssertTrue(waitUntil {
            picker.exists && picker.value as? String == title
        }, app.debugDescription)
    }

    @MainActor
    private func assertSettingsContent(_ language: ExpectedLanguage, in app: XCUIApplication) {
        for (category, english, chinese) in [
            ("general", "General", "通用"),
            ("history", "History", "历史记录"),
            ("appearance", "Appearance", "外观"),
            ("automation", "Automation", "自动化")
        ] {
            assertLabel("clipy.settings.category." + category,
                        equals: language.text(english, chinese), within: app, in: app)
        }

        selectCategory("history", in: app)
        let workspace = app.descendants(matching: .any)["clipy.history.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(workspace.staticTexts[language.text("Clipboard history", "剪贴板历史")]
            .waitForExistence(timeout: 5), app.debugDescription)
        assertSearchControls(language, within: workspace, in: app)
        let mode = workspace.descendants(matching: .any)["clipy.search.mode"]
        mode.click()
        XCTAssertTrue(app.menuItems[language.text("Exact", "精确")].waitForExistence(timeout: 5),
                      app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        workspace.descendants(matching: .any)["clipy.search.filter"].click()
        XCTAssertTrue(app.menuItems[language.text("Pinned Only", "仅置顶")].waitForExistence(timeout: 5),
                      app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        assertLabel("clipy.history.workspace.actions", equals: language.text("History actions", "历史操作"),
                    within: workspace, in: app)
        workspace.descendants(matching: .any)["clipy.history.workspace.actions"].click()
        XCTAssertTrue(app.menuItems[language.text("Compact rows", "紧凑行布局")].waitForExistence(timeout: 5),
                      app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])

        selectCategory("automation", in: app)
        let manage = app.buttons["clipy.settings.workflows.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(manage.label, language.text("Manage workflows…", "管理工作流…"), app.debugDescription)
        SettingsJourneyControls.scroll(manage, into: app.scrollViews.containing(
            .any, identifier: manage.identifier
        ).firstMatch, app: app)
        manage.click()
        let name = app.textFields["clipy.workflow.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), app.debugDescription)
        assertLabel("clipy.workflow.title", equals: language.text("Workflows", "工作流"), within: app, in: app)
        assertLabel("clipy.workflow.name", equals: language.text("Workflow name", "工作流名称"), within: app, in: app)
        let configuration = app.descendants(matching: .any)["clipy.workflow.configuration"]
        XCTAssertTrue(configuration.waitForExistence(timeout: 5), app.debugDescription)
        for (english, chinese) in [("Steps", "步骤"), ("Trigger and scope", "触发方式与范围")] {
            let choice = configuration.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", language.text(english, chinese))
            ).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        }
        let display = app.descendants(matching: .any)["clipy.workflow.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 5), app.debugDescription)
        for (english, chinese) in [("Compare", "对照"), ("Input", "输入"), ("Result", "结果")] {
            let choice = display.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", language.text(english, chinese))
            ).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        }
        // Merely inspect the workflow editor; Preview, Run, Save, Copy and
        // permission controls are never invoked by this language journey.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !name.exists }, app.debugDescription)
    }

    @MainActor
    private func closeSettingsAndAssertPanel(_ language: ExpectedLanguage, in app: XCUIApplication) {
        let settings = app.windows.containing(
            .button, identifier: "clipy.settings.category.general"
        ).firstMatch
        XCTAssertTrue(settings.exists, app.debugDescription)
        settings.buttons["_XCUI:CloseWindow"].click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        let panel = panel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        assertStoppedPanel(language, in: app)
    }

    @MainActor
    private func assertStoppedPanel(_ language: ExpectedLanguage, in app: XCUIApplication) {
        // Denied capture plus an empty store renders the product's stopped
        // state, rather than the browsing header/footer. Its separate native
        // hosting root must still adopt the selected language immediately.
        let panel = panel(in: app)
        assertLabel("clipy.capture.access.empty",
                    equals: language.text("Clipboard Monitoring Unavailable", "剪贴板监控不可用"),
                    within: panel, in: app)
        assertLabel("clipy.capture.access.message",
                    equals: language.text("Clipboard access is denied, so monitoring is stopped.", "剪贴板访问被拒绝，监控已停止。"),
                    within: panel, in: app)
        assertLabel("clipy.capture.access.recovery",
                    equals: language.text("Retry clipboard access", "重试剪贴板访问"), within: panel, in: app)
    }

    @MainActor
    private func assertSearchControls(
        _ language: ExpectedLanguage, within container: XCUIElement, in app: XCUIApplication
    ) {
        assertLabel("clipy.search.field", equals: language.text("Search clipboard history", "搜索剪贴板历史记录"),
                    within: container, in: app)
        assertLabel("clipy.search.mode", equals: language.text("Search Mode", "搜索模式"), within: container, in: app)
        assertLabel("clipy.search.filter", equals: language.text("Filter results", "筛选结果"), within: container, in: app)
    }

    @MainActor
    private func assertLabel(
        _ identifier: String, equals expected: String, within container: XCUIElement, in app: XCUIApplication
    ) {
        let element = container.descendants(matching: .any)[identifier]
        XCTAssertTrue(waitUntil { element.exists && element.label == expected }, app.debugDescription)
    }

    @MainActor
    private func panel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["clipy.panel.root"]
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private enum ExpectedLanguage {
        case english, simplifiedChinese

        func text(_ english: String, _ chinese: String) -> String {
            self == .english ? english : chinese
        }
    }
}
