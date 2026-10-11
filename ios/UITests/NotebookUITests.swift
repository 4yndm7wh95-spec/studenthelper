import XCTest

final class NotebookUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false, XCUIApplication().state != .notRunning { capture(XCUIApplication(), "iPadFailure") }
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
    func testFingerInkUndoRedoAndRestartPreserveNativeDrawing() {
        let app = application(); create(app, title: "Ink")
        app.buttons["笔记本选项"].tap(); app.buttons["用手指书写"].tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "notebook-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.42))
        from.press(forDuration: 0.05, thenDragTo: to)
        waitForInk(canvas, contains: "手写1笔")
        app.buttons["撤销"].tap(); waitForInk(canvas, contains: "手写0笔")
        app.buttons["重做"].tap(); waitForInk(canvas, contains: "手写1笔")
        capture(app, "iPadNativeInk")
        app.terminate(); app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "打开笔记本：Ink")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8)); book.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5)); waitForInk(canvas, contains: "手写1笔")
    }
    private func waitForInk(_ canvas: XCUIElement, contains value: String) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", value), object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 8), .completed)
    }
}
