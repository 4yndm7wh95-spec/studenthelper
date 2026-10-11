import XCTest
@testable import StudentHelper

@MainActor
final class NotebookAgentTests: XCTestCase {
    func testGeometryRejectsBooleansNonFiniteAndNegativeSizes() throws {
        let valid: [String: Any] = ["x": 12, "y": 30, "width": 240, "height": 90]
        XCTAssertEqual(try NotebookAssistantModel.frame(valid), NoteRect(x: 12, y: 30, width: 240, height: 90))
        for value in [true, Double.infinity, Double.nan, "20"] as [Any] {
            var invalid = valid; invalid["x"] = value
            XCTAssertThrowsError(try NotebookAssistantModel.frame(invalid))
        }
        var negative = valid; negative["width"] = -1
        XCTAssertThrowsError(try NotebookAssistantModel.frame(negative))
        XCTAssertThrowsError(try NotebookAssistantModel.uuid("page_id", ["page_id": "../file"]))
    }
    func testAgentRequestIncludesScopedToolsAndDoesNotExposeKeyInBody() throws {
        let messages: [[String: Any]] = [["role": "user", "content": "查看这页"]]
        let request = try NotebookAssistantModel.request(configuration: ModelConfiguration(), key: "test-key", messages: messages)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let data = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(body["response_format"], "Notebook tool calls must retain their own wire format after teaching prompt updates")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), ["list_pages", "read_page", "read_region", "search_notes", "propose_annotation", "propose_create_page", "propose_paper", "propose_move_object", "propose_delete_object", "read_app_state", "list_notebooks", "read_ink", "perform_app_action", "list_notebook_pages", "read_notebook_page", "search_notebook"])
        XCTAssertTrue(names.filter { $0.contains("delete") || $0.contains("move") }.allSatisfy { $0.hasPrefix("propose_") })
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "查看这页")
    }

    func testToolRoundTripScopesReadsAndReviewsWritesBeforeCommit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); NotebookAgentProtocol.replies = [] }
        let store = NotebookStore(folder: folder)
        let book = try XCTUnwrap(store.createNotebook(title: "当前笔记"))
        let page = try XCTUnwrap(store.currentPage?.id)
        _ = store.createNotebook(title: "其他笔记")
        let foreign = try XCTUnwrap(store.currentPage?.id)
        store.selectPage(page)
        NotebookAgentProtocol.replies = [
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                Self.call("foreign", "read_page", ["page_id": foreign.uuidString]),
                Self.call("app-read", "read_notebook_page", ["page_id": foreign.uuidString]),
                Self.call("add", "propose_annotation", ["page_id": page.uuidString, "text": "先看这一行", "x": 40, "y": 60, "width": 300, "height": 80])
            ]],
            ["role": "assistant", "content": "建议在本页写一条提示，尚未修改。"]
        ]
        NotebookAgentProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotebookAgentProtocol.self]
        let model = NotebookAssistantModel(notebookID: book, pageID: page,
            configuration: ModelConfiguration(address: "https://notebook.test/v1"), key: "unit-test-only", session: URLSession(configuration: configuration))
        let result = try await model.run("帮我加一条提示", store: store)
        XCTAssertTrue(result.contains("尚未修改"))
        XCTAssertEqual(model.proposals.count, 1)
        XCTAssertTrue(store.page(id: page)?.objects.isEmpty == true)
        XCTAssertTrue(store.page(id: foreign)?.objects.isEmpty == true)
        let second = try XCTUnwrap(NotebookAgentProtocol.requests.last)
        let first = try XCTUnwrap(NotebookAgentProtocol.requests.first)
        let initialMessages = try XCTUnwrap(first["messages"] as? [[String: Any]])
        XCTAssertTrue((initialMessages.first?["content"] as? String)?.contains(TeachingInstructions.base) == true)
        let visualParts = initialMessages.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
        let imagePart = try XCTUnwrap(visualParts.first { $0["type"] as? String == "image_url" })
        let source = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
        XCTAssertTrue((source["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true, "The student should not need to separately enable a page image")
        XCTAssertEqual(source["detail"] as? String, "high")
        let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
        let resultMessage = try XCTUnwrap(messages.first { ($0["tool_call_id"] as? String) == "foreign" })
        XCTAssertTrue((resultMessage["content"] as? String)?.contains("工具未执行") == true)
        let appRead = try XCTUnwrap(messages.first { ($0["tool_call_id"] as? String) == "app-read" })
        XCTAssertTrue((appRead["content"] as? String)?.contains(foreign.uuidString) == true)
        XCTAssertFalse((appRead["content"] as? String)?.contains("工具未执行") == true)
        model.apply(store: store)
        XCTAssertTrue(model.applied)
        XCTAssertEqual(store.page(id: page)?.objects.first?.text, "先看这一行")
        XCTAssertTrue(store.page(id: foreign)?.objects.isEmpty == true)
        store.undo()
        XCTAssertTrue(store.page(id: page)?.objects.isEmpty == true)
    }

    func testChangedPageRejectsPendingModelEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); NotebookAgentProtocol.replies = [] }
        let store = NotebookStore(folder: folder)
        let book = try XCTUnwrap(store.createNotebook(title: "数学")), page = try XCTUnwrap(store.currentPage?.id)
        NotebookAgentProtocol.replies = [
            ["role": "assistant", "tool_calls": [Self.call("paper", "propose_paper", ["page_id": page.uuidString, "paper": "grid"])]],
            ["role": "assistant", "content": "建议改为方格纸。"]
        ]
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NotebookAgentProtocol.self]
        let model = NotebookAssistantModel(notebookID: book, pageID: page,
            configuration: ModelConfiguration(address: "https://notebook.test/v1"), key: "unit-test-only", session: URLSession(configuration: configuration))
        _ = try await model.run("切换纸张", store: store)
        store.renamePage(page, title: "我的新标题")
        model.apply(store: store)
        XCTAssertFalse(model.applied)
        XCTAssertEqual(store.page(id: page)?.paper, .ruled)
        XCTAssertTrue(model.error?.contains("已变化") == true)
        XCTAssertTrue(model.proposals.isEmpty)
    }

    private static func call(_ id: String, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let encoded = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data()
        return ["id": id, "type": "function", "function": ["name": name, "arguments": String(decoding: encoded, as: UTF8.self)]]
    }
}

private final class NotebookAgentProtocol: URLProtocol {
    static var replies: [[String: Any]] = []
    static var requests: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "notebook.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    if count <= 0 { break }; body.append(buffer, count: count)
                }
            }
            if let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] { Self.requests.append(value) }
            guard !Self.replies.isEmpty else { throw ModelConnectionError.response }
            let message = Self.replies.removeFirst()
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": message]]])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
