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
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), ["list_pages", "read_page", "read_region", "search_notes", "propose_annotation", "propose_create_page", "propose_paper", "propose_move_object", "propose_delete_object"])
        XCTAssertTrue(names.filter { $0.contains("delete") || $0.contains("move") }.allSatisfy { $0.hasPrefix("propose_") })
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "查看这页")
    }
}
