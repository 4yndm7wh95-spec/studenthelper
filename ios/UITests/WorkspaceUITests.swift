import XCTest

final class WorkspaceUITests: XCTestCase {
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
        XCTAssertFalse(app.staticTexts["Math"].exists)
        XCTAssertFalse(app.staticTexts["Homework"].exists)
    }
    func testSystemPhotoPickerPreparesAndSendsActualImage() {
        let app = app()
        app.buttons["添加图片"].tap(); app.buttons["从相册选择"].tap()
        let media = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Photo,' OR label BEGINSWITH[c] 'Photo ' OR label BEGINSWITH '照片' OR label BEGINSWITH[c] 'Screenshot' OR label BEGINSWITH '屏幕快照'")).firstMatch
        guard media.waitForExistence(timeout: 12) else {
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
