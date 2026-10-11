import XCTest

final class NotebookUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    private func application() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--notebook-test-id", UUID().uuidString]
        app.launch()
        return app
    }
    private func create(_ app: XCUIApplication, title: String) {
        let create = app.buttons["notebook-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 8)); create.tap()
        let field = app.textFields["notebook-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(title)
        app.buttons["notebook-create-confirm"].tap()
        XCTAssertTrue(app.buttons["ask-notebook"].waitForExistence(timeout: 5))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testNotebookPagePaperAndAssistantThroughUI() {
        let app = application(); create(app, title: "Calculus")
        let title = app.textFields["page-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.value as? String, "第 1 页")
        app.buttons["paper-menu"].tap(); app.buttons["方格"].tap()
        XCTAssertTrue(app.buttons["paper-menu"].label.contains("方格"))
        let add = app.buttons["page-create"]
        if !add.exists { app.buttons["展开页面列表"].tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 4)); add.tap()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 2 页"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 5), .completed)
        capture(app, "iPadNotebookGrid")
        app.buttons["套索"].tap(); app.buttons["钢笔"].tap()
        app.buttons["橡皮擦，选择擦除方式"].tap(); app.buttons["擦除经过的部分"].tap()
        app.buttons["钢笔"].tap()
        app.buttons["ask-notebook"].tap()
        XCTAssertTrue(app.navigationBars["笔记助手"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["notebook-question"].exists)
        XCTAssertFalse(app.buttons["问一步"].isEnabled, "An empty question must not send a model request")
        capture(app, "iPadNotebookAssistant")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["ask-notebook"].waitForExistence(timeout: 5))
    }
    func testNotebookSurvivesRestartAndAdaptsToLandscape() {
        let app = application(); create(app, title: "Probability")
        app.buttons["paper-menu"].tap(); app.buttons["点阵"].tap()
        app.terminate(); app.launch()
        let notebook = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "打开笔记本：Probability")).firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 8)); notebook.tap()
        XCTAssertTrue(app.buttons["paper-menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["paper-menu"].label.contains("点阵"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["ask-notebook"].waitForExistence(timeout: 5))
        capture(app, "iPadNotebookLandscape")
        XCUIDevice.shared.orientation = .portrait
    }
}
