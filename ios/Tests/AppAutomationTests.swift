import XCTest
import PencilKit
@testable import StudentHelper

@MainActor
final class AppAutomationTests: XCTestCase {
    private func store() -> NotebookStore {
        NotebookStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func action(_ name: String, _ parameters: [String: Any], automation: AppAutomation, store: NotebookStore) async throws -> [[String: Any]] {
        try await automation.perform("perform_app_action", args: ["action": name, "parameters": parameters], notebooks: store, learning: nil)
    }

    func testSessionRejectsOverlapAndStaleEndCannotUnlockNewSession() {
        let automation = AppAutomation()
        var cancelled = false
        let first = automation.begin { cancelled = true }
        XCTAssertNotNil(first); XCTAssertTrue(automation.active)
        XCTAssertNil(automation.begin {})
        automation.stop(); XCTAssertTrue(cancelled); XCTAssertFalse(automation.active)
        let second = automation.begin {}
        automation.end(first!); XCTAssertTrue(automation.active)
        automation.end(second!); XCTAssertFalse(automation.active)
    }

    func testMutationsRequireSessionAndRejectUnknownOrBooleanCoordinates() async throws {
        let automation = AppAutomation(), notebooks = store()
        do {
            _ = try await action("create_notebook", ["title": "Test"], automation: automation, store: notebooks)
            XCTFail("Unlocked automation must not mutate documents")
        } catch {}
        let session = try XCTUnwrap(automation.begin {})
        defer { automation.end(session) }
        _ = try await action("create_notebook", ["title": "Test"], automation: automation, store: notebooks)
        let page = try XCTUnwrap(notebooks.currentPage)
        for invalid: [String: Any] in [
            ["page_id": page.id.uuidString, "text": "Note", "frame": ["x": true, "y": 64, "width": 240, "height": 100]],
            ["page_id": page.id.uuidString, "text": "Note", "frame": ["x": 740, "y": 64, "width": 240, "height": 100]],
            ["page_id": page.id.uuidString, "text": "Note", "frame": ["x": 64, "y": 64, "width": 240, "height": 100], "unknown": 1]
        ] {
            do { _ = try await action("add_text", invalid, automation: automation, store: notebooks); XCTFail("Invalid action must throw") }
            catch {}
        }
        XCTAssertTrue(try XCTUnwrap(notebooks.currentPage).objects.isEmpty)
    }

    func testNativeInkDrawingMoveEraseUndoAndReadImage() async throws {
        let automation = AppAutomation(), notebooks = store()
        let session = try XCTUnwrap(automation.begin {})
        defer { automation.end(session) }
        _ = try await action("create_notebook", ["title": "Native Ink"], automation: automation, store: notebooks)
        let page = try XCTUnwrap(notebooks.currentPage), id = page.id.uuidString
        _ = try await action("draw_stroke", ["page_id": id, "width": 3, "color": "#D97757", "points": [["x": 100, "y": 120], ["x": 160, "y": 160], ["x": 220, "y": 120]]], automation: automation, store: notebooks)
        let original = try notebooks.drawingChecked(for: page.id)
        XCTAssertEqual(original.strokes.count, 1)
        _ = try await action("move_strokes", ["page_id": id, "indices": [0], "dx": 50, "dy": 40], automation: automation, store: notebooks)
        let moved = try notebooks.drawingChecked(for: page.id)
        XCTAssertEqual(moved.strokes[0].renderBounds.minX - original.strokes[0].renderBounds.minX, 50, accuracy: 1)
        _ = try await action("erase_strokes", ["page_id": id, "indices": [0]], automation: automation, store: notebooks)
        XCTAssertTrue(try notebooks.drawingChecked(for: page.id).strokes.isEmpty)
        _ = try await action("undo", [:], automation: automation, store: notebooks)
        XCTAssertEqual(try notebooks.drawingChecked(for: page.id).strokes.count, 1)
        let read = try await automation.perform("read_page", args: ["page_id": id], notebooks: notebooks, learning: nil)
        let image = try XCTUnwrap(read.first(where: { ($0["type"] as? String) == "image" }))
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(image["data"] as? String)))
        XCTAssertNotNil(UIImage(data: data)); XCTAssertEqual(image["mimeType"] as? String, "image/png")
        XCTAssertEqual(NotebookStore(folder: notebooks.repository.folder).drawing(for: page.id).strokes.count, 1)
    }

    func testMissingViewportCannotClaimSuccess() async throws {
        let automation = AppAutomation(), notebooks = store()
        let session = try XCTUnwrap(automation.begin {})
        defer { automation.end(session) }
        _ = try await action("create_notebook", ["title": "No View"], automation: automation, store: notebooks)
        let id = try XCTUnwrap(notebooks.currentPage).id.uuidString
        do { _ = try await action("zoom_viewport", ["page_id": id, "zoom": 2], automation: automation, store: notebooks); XCTFail("No canvas must return an error") }
        catch {}
    }

    func testMCPCropsPhotoAndUndoRestoresOriginalAsset() async throws {
        let automation = AppAutomation(), notebooks = store()
        defer { try? FileManager.default.removeItem(at: notebooks.repository.folder) }
        _ = notebooks.createNotebook(title: "照片")
        let page = try XCTUnwrap(notebooks.currentPage)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let object = try XCTUnwrap(notebooks.addImage(data: XCTUnwrap(image.pngData()), name: "照片", to: page.id))
        let original = try XCTUnwrap(notebooks.object(id: object, pageID: page.id)?.image)
        let session = try XCTUnwrap(automation.begin {})
        defer { automation.end(session) }
        _ = try await action("crop_image", ["page_id": page.id.uuidString, "object_id": object.uuidString, "x": 0.5, "y": 0, "width": 0.5, "height": 1], automation: automation, store: notebooks)
        let cropped = try XCTUnwrap(notebooks.object(id: object, pageID: page.id)?.image)
        XCTAssertNotEqual(cropped.id, original.id)
        XCTAssertEqual(notebooks.image(for: cropped)?.size, CGSize(width: 100, height: 100))
        _ = try await action("undo", [:], automation: automation, store: notebooks)
        XCTAssertEqual(notebooks.object(id: object, pageID: page.id)?.image?.id, original.id)
    }

    func testSchemaListsEveryActionAndCannotExposeSecretsOrPaths() throws {
        let tools = AppAutomation.tools
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["read_app_state", "list_notebooks", "list_pages", "read_page", "read_ink", "search_notes", "perform_app_action"])
        let data = try JSONSerialization.data(withJSONObject: tools)
        let schema = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(AppAutomation.AppAction.allCases.allSatisfy { schema.contains($0.rawValue) })
        XCTAssertFalse(schema.contains("api_key")); XCTAssertFalse(schema.contains("file_path"))
    }
}
