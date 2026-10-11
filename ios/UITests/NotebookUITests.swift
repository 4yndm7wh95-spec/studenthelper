import XCTest
import UIKit

@MainActor final class NotebookUITests: XCTestCase {
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
    // SwiftUI Menu exposes a wrapper button that XCTest cannot scroll to.
    // Tap its observed onscreen bounds, then verify the menu actually opens.
    private func openMenu(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertFalse(button.frame.isEmpty)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    func testNotebookPagePaperAndAssistantThroughUI() {
        let app = application(); create(app, title: "Calculus")
        let title = app.textFields["page-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.value as? String, "第 1 页")
        openMenu(app.buttons["paper-menu"]); app.buttons["方格"].tap()
        XCTAssertTrue(app.buttons["paper-menu"].label.contains("方格"))
        let add = app.buttons["page-create"]
        if !add.exists { app.buttons["展开页面列表"].tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 4)); add.tap()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 2 页"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 5), .completed)
        capture(app, "iPadNotebookGrid")
        app.buttons["套索"].tap(); app.buttons["钢笔"].tap()
        openMenu(app.buttons["橡皮擦，选择擦除方式"]); app.buttons["擦除经过的部分"].tap()
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
        openMenu(app.buttons["paper-menu"]); app.buttons["点阵"].tap()
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
        openMenu(app.buttons["笔记本选项"]); app.buttons["用手指书写"].tap()
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

    func testMCPImportsProblemDrawsCorrectionAndUserCanStop() async throws {
        let app = XCUIApplication(), token = UUID().uuidString
        app.launchArguments = ["--notebook-test-id", UUID().uuidString, "--mcp-test-token", token]
        app.launch(); create(app, title: "AI Review")
        openMenu(app.buttons["笔记本选项"]); app.buttons["设置"].firstMatch.tap()
        app.buttons["AI 连接"].tap()
        let toggle = app.switches["mcp-enable"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // The identified SwiftUI row contains the actual trailing UISwitch.
        let control = toggle.switches.firstMatch
        XCTAssertTrue(control.exists); control.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        let address = app.descendants(matching: .any).matching(identifier: "mcp-endpoint").firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        let raw = address.label.replacingOccurrences(of: "连接地址：", with: "")
        var url = try XCTUnwrap(URLComponents(string: raw))
        XCTAssertEqual(url.scheme, "http"); XCTAssertNotNil(url.port)
        url.host = "127.0.0.1"
        let endpoint = try XCTUnwrap(url.url)
        app.buttons["完成"].firstMatch.tap()
        _ = try await rpc(endpoint, token: token, id: 1, method: "initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "iPad UI review", "version": "1"]])
        let state = try await rpc(endpoint, token: token, id: 2, method: "tools/call", params: ["name": "read_app_state", "arguments": ["scope": "overview"]])
        let overview = try metadata(state)
        let pageID = try XCTUnwrap(overview["selected_page_id"] as? String)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 160)).image { output in
            UIColor.white.setFill(); output.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
            ("Solve: 2x + 3 = 7" as NSString).draw(at: CGPoint(x: 28, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.black])
        }
        let data = try XCTUnwrap(image.pngData())
        _ = try await rpc(endpoint, token: token, id: 3, method: "tools/call", params: ["name": "perform_app_action", "arguments": ["action": "add_image", "parameters": ["page_id": pageID, "name": "Problem", "data_base64": data.base64EncodedString()]]])
        let points = (0...24).map { index -> [String: Double] in
            let angle = Double(index) / 24 * .pi * 2
            return ["x": 230 + cos(angle) * 80, "y": 500 + sin(angle) * 24]
        }
        _ = try await rpc(endpoint, token: token, id: 4, method: "tools/call", params: ["name": "perform_app_action", "arguments": ["action": "draw_stroke", "parameters": ["page_id": pageID, "points": points, "width": 2, "color": "#B45C45"]]])
        let canvas = app.descendants(matching: .any).matching(identifier: "notebook-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 6)); waitForInk(canvas, contains: "图片1张"); waitForInk(canvas, contains: "手写1笔")
        _ = try await rpc(endpoint, token: token, id: 5, method: "tools/call", params: ["name": "perform_app_action", "arguments": ["action": "zoom_viewport", "parameters": ["page_id": pageID, "zoom": 1.25]]])
        _ = try await rpc(endpoint, token: token, id: 6, method: "tools/call", params: ["name": "perform_app_action", "arguments": ["action": "scroll_viewport", "parameters": ["page_id": pageID, "dy": 60]]])
        _ = try await rpc(endpoint, token: token, id: 7, method: "tools/call", params: ["name": "perform_app_action", "arguments": ["action": "zoom_viewport", "parameters": ["page_id": pageID, "zoom": 1, "x": 0, "y": 0]]])
        let request = Task { try? await self.rpc(endpoint, token: token, id: 8, method: "tools/call", params: ["name": "read_page", "arguments": ["page_id": pageID]]) }
        try await Task.sleep(for: .milliseconds(100))
        let stop = app.buttons["ai-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        capture(app, "iPadAIReviewAndControl")
        stop.tap()
        let released = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 6), .completed)
        _ = await request.value
        XCTAssertTrue(app.buttons["钢笔"].isHittable)
        app.buttons["撤销"].tap(); waitForInk(canvas, contains: "手写0笔"); waitForInk(canvas, contains: "图片1张")
        app.buttons["重做"].tap(); waitForInk(canvas, contains: "手写1笔")
        capture(app, "iPadProblemAndCorrection")
    }
    private func rpc(_ endpoint: URL, token: String, id: Int, method: String, params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["error"])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertFalse((result["isError"] as? Bool) ?? false)
        return result
    }
    private func metadata(_ result: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
