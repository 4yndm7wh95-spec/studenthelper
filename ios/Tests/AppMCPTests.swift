import XCTest
import UIKit
import PencilKit
@testable import StudentHelper

@MainActor
final class AppMCPTests: XCTestCase {
    private var folder: URL!
    private var notebooks: NotebookStore!
    private var learning: LearningStore!
    private var automation: AppAutomation!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tests-" + UUID().uuidString)
        notebooks = NotebookStore(folder: folder.appendingPathComponent("notebooks"))
        learning = LearningStore(fileURL: folder.appendingPathComponent("learning.json"))
        automation = AppAutomation()
    }
    override func tearDown() async throws {
        automation.stop(); try? FileManager.default.removeItem(at: folder)
        notebooks = nil; learning = nil; automation = nil
    }

    func testFragmentedHTTPFramingAndAmbiguousOrOversizedRequests() throws {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        let header = "POST /mcp HTTP/1.1\r\nHost: localhost:9000\r\nContent-Length: \(body.count)\r\n\r\n"
        var parser = AppMCPHTTPParser()
        XCTAssertNil(try parser.append(Data(header.utf8)))
        XCTAssertNil(try parser.append(Data(body.prefix(8))))
        let parsed = try XCTUnwrap(parser.append(Data(body.dropFirst(8))))
        XCTAssertEqual(parsed.target, "/mcp"); XCTAssertEqual(parsed.body, body)
        for invalid in [
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\nextra"
        ] {
            var rejected = AppMCPHTTPParser()
            XCTAssertThrowsError(try rejected.append(Data(invalid.utf8)))
        }
        var tooLarge = AppMCPHTTPParser()
        XCTAssertThrowsError(try tooLarge.append(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(AppMCPHTTPParser.maxBodyBytes + 1)\r\n\r\n".utf8))) {
            XCTAssertEqual(($0 as? AppMCPHTTPError)?.status, 413)
        }
        var hugeHeader = AppMCPHTTPParser()
        XCTAssertThrowsError(try hugeHeader.append(Data(repeating: 65, count: AppMCPHTTPParser.maxHeaderBytes + 1))) {
            XCTAssertEqual(($0 as? AppMCPHTTPError)?.status, 431)
        }
    }

    func testBearerOriginHostAndProtocolPolicyRejectsUnauthorizedAccess() {
        let host = "127.0.0.1:9000", origin = "http://" + host
        let headers = ["host": host, "authorization": "Bearer test-token", "content-type": "application/json", "accept": "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18"]
        func rejection(_ changes: [String: String] = [:], method: String = "POST") -> Int? {
            let request = AppMCPHTTPRequest(method: method, target: "/mcp", headers: headers.merging(changes) { _, value in value }, body: Data())
            return AppMCPHTTPPolicy.rejection(for: request, token: "test-token", allowedOrigins: [origin], allowedHosts: [host])
        }
        XCTAssertNil(rejection()); XCTAssertNil(rejection(["origin": origin]))
        XCTAssertEqual(rejection(["authorization": "Bearer wrong-token"]), 401)
        XCTAssertEqual(rejection(["origin": "http://evil.example"]), 403)
        XCTAssertEqual(rejection(["origin": origin + ".evil.example"]), 403)
        XCTAssertEqual(rejection(["host": "evil.example:9000"]), 403)
        XCTAssertEqual(rejection(["mcp-protocol-version": "1900-01-01"]), 400)
        XCTAssertEqual(rejection(["content-type": "text/plain"]), 415)
        XCTAssertEqual(rejection(["accept": "text/event-stream"]), 406)
        XCTAssertEqual(rejection(method: "GET"), 405)
        XCTAssertTrue(AppMCPHTTPPolicy.constantEqual("same", "same"))
        XCTAssertFalse(AppMCPHTTPPolicy.constantEqual("same", "sAme"))
    }

    func testSharedRouterNegotiatesListsRealToolsAndRejectsInvalidRPC() async throws {
        let initialized = try await requiredRoute("initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        XCTAssertEqual((initialized["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let listed = try await requiredRoute("tools/list")
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "read_page" && $0["inputSchema"] is [String: Any] })
        XCTAssertTrue(tools.contains { $0["name"] as? String == "perform_app_action" })
        let ping = try await requiredRoute("ping", id: "echo")
        XCTAssertEqual(ping["id"] as? String, "echo")
        let unknown = try await requiredRoute("unknown")
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        for invalid: [String: Any] in [
            ["jsonrpc": "1.0", "id": 1, "method": "ping"],
            ["jsonrpc": "2.0", "id": true, "method": "ping"],
            ["jsonrpc": "2.0", "id": NSNull(), "method": "ping"],
            ["jsonrpc": "2.0", "id": 1.5, "method": "ping"],
            ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": []]
        ] {
            let received = await AppMCPServer.dispatch(invalid, notebooks: notebooks, learning: nil, automation: automation)
            let response = try XCTUnwrap(received)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32600)
        }
        let notified = await AppMCPServer.dispatch(["jsonrpc": "2.0", "method": "notifications/initialized"], notebooks: notebooks, learning: nil, automation: automation)
        XCTAssertNil(notified)
    }

    func testReadPageReturnsActualPagePixelsAndNativeInkMetadata() async throws {
        _ = try XCTUnwrap(notebooks.createNotebook(title: "真实页面"))
        let page = try XCTUnwrap(notebooks.currentPage)
        _ = notebooks.addText("题目与手写解答", to: page.id)
        let samples = [CGPoint(x: 70, y: 300), CGPoint(x: 270, y: 340)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: samples, creationDate: Date()))
        XCTAssertTrue(notebooks.updateDrawing(PKDrawing(strokes: [stroke]), pageID: page.id))
        let response = try await requiredRoute("tools/call", params: ["name": "read_page", "arguments": ["page_id": page.id.uuidString]])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let block = try XCTUnwrap(content.first { $0["type"] as? String == "image" })
        XCTAssertEqual(block["mimeType"] as? String, "image/png")
        let pixels = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(block["data"] as? String)))
        let image = try XCTUnwrap(UIImage(data: pixels))
        XCTAssertEqual(Double(image.size.width), page.width)
        XCTAssertEqual(Double(image.size.height), page.height)
        XCTAssertGreaterThan(pixels.count, 2000)
        let metadata = try textResult(content)
        XCTAssertEqual(metadata["stroke_count"] as? Int, 1)
        XCTAssertEqual(metadata["pageID"] as? String, page.id.uuidString)
    }

    func testToolMutationRequiresLeaseAndCancellationReleasesIt() async throws {
        let params: [String: Any] = ["name": "perform_app_action", "arguments": ["action": "create_notebook", "parameters": ["title": "由MCP创建"]]]
        let blocked = try await requiredRoute("tools/call", params: params)
        XCTAssertEqual((blocked["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(notebooks.notebooks.isEmpty)
        var cancelled = false
        let lease = try XCTUnwrap(automation.begin { cancelled = true })
        XCTAssertNil(automation.begin {})
        let successful = try await requiredRoute("tools/call", params: params)
        XCTAssertEqual((successful["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(notebooks.currentNotebook?.title, "由MCP创建")
        let pageID = try XCTUnwrap(notebooks.currentPage?.id)
        let annotation = try await requiredRoute("tools/call", params: ["name": "perform_app_action", "arguments": ["action": "add_text", "parameters": ["page_id": pageID.uuidString, "text": "这里少了一步", "frame": ["x": 64, "y": 450, "width": 300, "height": 100]]]])
        XCTAssertEqual((annotation["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(notebooks.page(id: pageID)?.objects.last?.text, "这里少了一步")
        let notification = await AppMCPServer.dispatch(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]], notebooks: notebooks, learning: nil, automation: automation)
        XCTAssertNil(notification); XCTAssertTrue(cancelled); XCTAssertFalse(automation.active)
        automation.end(lease)
        let second = try XCTUnwrap(automation.begin {})
        automation.end(second); XCTAssertFalse(automation.active)
    }

    func testLiveHTTPInitializeCancellationAndRotatedCredentials() async throws {
        _ = try XCTUnwrap(notebooks.createNotebook(title: "联网测试"))
        let page = try XCTUnwrap(notebooks.currentPage)
        let server = AppMCPServer()
        server.start(notebooks: notebooks, learning: learning, automation: automation)
        defer { server.stop() }
        try await ready(server)
        let firstToken = try XCTUnwrap(server.token)
        let port = try XCTUnwrap(URLComponents(string: server.endpoint)?.port)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let initialization = try await post(["jsonrpc": "2.0", "id": 10, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]], url: url, token: firstToken, session: session)
        XCTAssertEqual(initialization.0, 200)
        XCTAssertEqual((initialization.1?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        let denied = try await post(["jsonrpc": "2.0", "id": 11, "method": "ping"], url: url, token: "invalid", session: session)
        XCTAssertEqual(denied.0, 401)
        // No canvas acknowledges this isolated test page, so the operation waits.
        let pending = Task { @MainActor in
            try await post(["jsonrpc": "2.0", "id": 42, "method": "tools/call", "params": ["name": "perform_app_action", "arguments": ["action": "zoom_viewport", "parameters": ["page_id": page.id.uuidString, "zoom": 2]]]], url: url, token: firstToken, session: session)
        }
        for _ in 0..<100 where !automation.active { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(automation.active)
        let cancellation = try await post(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 42]], url: url, token: firstToken, session: session)
        XCTAssertEqual(cancellation.0, 202); XCTAssertFalse(automation.active)
        let finished = try await pending.value
        XCTAssertEqual((finished.1?["error"] as? [String: Any])?["code"] as? Int, -32800)
        server.stop()
        XCTAssertFalse(server.enabled); XCTAssertNil(server.token); XCTAssertTrue(server.endpoint.isEmpty)
        server.start(notebooks: notebooks, learning: learning, automation: automation)
        try await ready(server)
        XCTAssertTrue(firstToken != server.token, "Every new listener must rotate its authentication credential")
    }

    private func route(_ method: String, id: Any = 1, params: [String: Any] = [:]) async -> [String: Any]? {
        await AppMCPServer.dispatch(["jsonrpc": "2.0", "id": id, "method": method, "params": params], notebooks: notebooks, learning: learning, automation: automation)
    }
    private func requiredRoute(_ method: String, id: Any = 1, params: [String: Any] = [:]) async throws -> [String: Any] {
        let response = await route(method, id: id, params: params)
        return try XCTUnwrap(response)
    }
    private func textResult(_ content: [[String: Any]]) throws -> [String: Any] {
        let text = try XCTUnwrap(content.first { $0["type"] as? String == "text" }?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func ready(_ server: AppMCPServer) async throws {
        for _ in 0..<200 {
            if server.enabled { return }
            if let error = server.error { XCTFail(error); throw TestError.listener }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("MCP listener did not become ready"); throw TestError.listener
    }
    private func post(_ body: [String: Any], url: URL, token: String, session: URLSession) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data.isEmpty ? nil : (try JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }
    private enum TestError: Error { case listener }
}
