import XCTest

final class WorkspaceUITests: XCTestCase {
    func testTapChatWhitespaceDismissesKeyboardAndPreservesDraft() {
        for preview in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = preview ? ["--design-preview"] : ["--ui-tests-reset"]
            app.launch()
            let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let attach = app.buttons["添加图片"]
            XCTAssertLessThan(abs(input.frame.midY - attach.frame.midY), 4, "Single-line input and attachment button must share a vertical center")
            input.typeText("draft")
            let draftReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "draft"), object: input)
            XCTAssertEqual(XCTWaiter.wait(for: [draftReady], timeout: 5), .completed)
            let keyboardShot = XCTAttachment(screenshot: app.screenshot())
            keyboardShot.name = preview ? "ChatKeyboard" : "EmptyChatKeyboard"
            keyboardShot.lifetime = .keepAlways; add(keyboardShot)
            // Scroll-view accessibility frames can extend behind the keyboard.
            // Tap a screen coordinate safely above the composer instead.
            let whitespace = CGPoint(x: app.frame.midX, y: input.frame.minY - 32)
            XCTAssertLessThan(whitespace.y, app.keyboards.firstMatch.frame.minY)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: whitespace.x, dy: whitespace.y)).tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
            XCTAssertEqual(input.value as? String, "draft")
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            input.typeText("\nsecond line")
            XCTAssertTrue(app.keyboards.firstMatch.exists, "Editing inside the composer must retain keyboard focus")
            // Tapping an existing draft positions the caret at the tap location.
            // Check that editing preserves both parts, without assuming an end caret.
            let edited = (input.value as? String) ?? ""
            XCTAssertTrue(edited.contains("draft"))
            XCTAssertTrue(edited.contains("\nsecond line"))
            XCTAssertEqual(edited.count, "draft\nsecond line".count)
            app.terminate()
        }
    }
    private func app() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-tests-reset"]; app.launch(); return app
    }
    func testCourseCreationRenameAndDeletionThroughInterface() {
        let app = app()
        app.buttons["会话"].tap()
        XCTAssertFalse(app.staticTexts["概率论与数理统计"].exists)
        app.buttons["新建课程"].firstMatch.tap()
        let courseName = app.textFields["课程名称"]
        XCTAssertTrue(courseName.waitForExistence(timeout: 5)); courseName.tap(); courseName.typeText("Math")
        app.buttons["创建"].tap()
        app.buttons["新聊天"].firstMatch.tap()
        app.buttons["会话"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "新对话")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 1)
        app.buttons["重命名"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap()
        let oldName = (name.value as? String) ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count) + "Homework")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["Homework"].waitForExistence(timeout: 3))
        app.buttons["管理课程：Math"].tap()
        app.buttons["删除课程"].tap()
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["Math"].exists)
        app.buttons["管理课程：Math"].tap(); app.buttons["删除课程"].tap(); app.alerts.buttons["删除"].tap()
        let courseGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Math"])
        let chatGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Homework"])
        XCTAssertEqual(XCTWaiter.wait(for: [courseGone, chatGone], timeout: 8), .completed)
    }
    func testSystemPhotoPickerPreparesAndSendsActualImage() {
        let app = app()
        let attach = app.buttons["添加图片"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        let center = attach.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: center.midX, dy: center.midY)).tap()
        app.buttons["从相册选择"].tap()
        let media = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Photo,' OR label BEGINSWITH[c] 'Photo ' OR label BEGINSWITH '照片' OR label BEGINSWITH[c] 'Screenshot' OR label BEGINSWITH '屏幕快照'")).firstMatch
        guard media.waitForExistence(timeout: 60) else {
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "PhotoPicker"; screenshot.lifetime = .keepAlways; add(screenshot)
            XCTFail("System photo picker did not expose seeded image: " + app.debugDescription); return
        }
        media.tap()
        let addButton = app.buttons.matching(NSPredicate(format: "label == 'Add' OR label BEGINSWITH 'Add (' OR label == '添加' OR label BEGINSWITH '添加（' OR label == 'Done' OR label == '完成'")).firstMatch
        if addButton.waitForExistence(timeout: 3) { addButton.tap() }
        let remove = app.buttons["移除图片：照片.jpg"]
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "The selected photo must appear as a draft thumbnail")
        let send = app.buttons["发送"]
        XCTAssertTrue(send.isEnabled, "A photo without text must be sendable")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "PhotoComposer"; screenshot.lifetime = .keepAlways; add(screenshot)
        send.tap()
        XCTAssertTrue(app.buttons["查看图片：照片.jpg"].waitForExistence(timeout: 5))
        XCTAssertFalse(remove.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '附件：'")).firstMatch.exists)
    }
}
