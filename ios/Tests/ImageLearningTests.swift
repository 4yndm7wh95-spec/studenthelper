import XCTest
import UIKit
@testable import StudentHelper

@MainActor
final class ImageLearningTests: XCTestCase {
    private var folder: URL!
    private var store: LearningStore!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("image-tests-" + UUID().uuidString, isDirectory: true)
        store = LearningStore(fileURL: folder.appendingPathComponent("state.json"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder); store = nil }
    private func fixture() throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "homework", withExtension: "png", subdirectory: "Fixtures")) }

    func testFirstLaunchHasNoCoursesOrSampleMessages() throws {
        XCTAssertEqual(store.state.courses, [])
        XCTAssertEqual(store.state.selectedCourse, "")
        XCTAssertEqual(store.current?.course, "")
        XCTAssertEqual(store.current?.messages, [])
    }
    func testFileImportPreservesImageAndDraftAcrossRestart() async throws {
        let id = try XCTUnwrap(store.state.currentID)
        await store.addFiles([try fixture()], to: .chat(id))
        let image = try XCTUnwrap(store.current?.draftImages?.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.images.url(for: image).path))
        XCTAssertNotNil(store.images.thumbnail(image))
        XCTAssertEqual(store.current?.messages, [], "Import must prepare a real image rather than send an attachment filename")
        let restored = LearningStore(fileURL: folder.appendingPathComponent("state.json"))
        XCTAssertEqual(restored.current?.draftImages?.first?.id, image.id)
        XCTAssertNotNil(restored.images.thumbnail(image))
    }
    func testImportedImageOnlyMessageUsesMultimodalWireFormat() async throws {
        let id = try XCTUnwrap(store.state.currentID)
        await store.addFiles([try fixture()], to: .chat(id))
        let images = try XCTUnwrap(store.current?.draftImages)
        var chat = try XCTUnwrap(store.current)
        chat.messages = [LearningMessage(role: "user", text: "", images: images)]
        let request = try ModelClient.request(configuration: ModelConfiguration(), key: "test-key", messages: store.modelMessages(for: chat))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let url = try XCTUnwrap((parts[1]["image_url"] as? [String: String])?["url"])
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"))
        let jpeg = try XCTUnwrap(Data(base64Encoded: String(url.split(separator: ",")[1])))
        XCTAssertNotNil(UIImage(data: jpeg))
        XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("附件："))
        chat.messages[0].text = "只抄写图中的算式，不要计算。"
        let live = try ModelClient.request(configuration: ModelConfiguration(), key: "test-key", messages: store.modelMessages(for: chat))
        let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try XCTUnwrap(live.httpBody).write(to: destination.appendingPathComponent("ios-vision-request.json"))
    }
    func testPhotoDataAndFileInputProduceSameReadableImages() throws {
        let photoData = try Data(contentsOf: fixture())
        let photo = try store.images.importData(photoData, name: "照片.jpg")
        let file = try store.images.importFile(fixture())
        XCTAssertEqual(photo.width, file.width); XCTAssertEqual(photo.height, file.height)
        XCTAssertEqual(try Data(contentsOf: store.images.url(for: photo)), try Data(contentsOf: store.images.url(for: file)))
        XCTAssertThrowsError(try store.images.importData(Data("invalid image".utf8), name: "fake.png"))
    }
    func testCourseImageReuseAndDeletionRetainSharedImage() async throws {
        store.addCourse("数学")
        await store.addFiles([try fixture()], to: .course("数学"))
        let file = try XCTUnwrap(store.state.files.first), image = try XCTUnwrap(file.image)
        store.useFileImage(file)
        XCTAssertEqual(store.current?.course, "数学")
        XCTAssertEqual(store.current?.draftImages?.first?.id, image.id)
        store.removeFile(file.id)
        XCTAssertNotNil(store.images.thumbnail(image), "Removing a resource must keep the image used by a chat")
        store.removeDraftImage(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.images.url(for: image).path))
    }
    func testCourseDeletionRemovesOnlyItsDataAndPersists() async throws {
        store.addCourse("数学"); store.newChat(course: "数学")
        let removed = try XCTUnwrap(store.state.currentID)
        await store.addFiles([try fixture()], to: .course("数学"))
        let image = try XCTUnwrap(store.state.files.first?.image)
        store.state.subjects["数学"] = "其他"; store.state.courseNotes["数学"] = "note"
        store.addCourse("物理"); store.newChat(course: "物理")
        let kept = try XCTUnwrap(store.state.currentID)
        store.select(try XCTUnwrap(store.state.chats.first { $0.id == removed }))
        store.deleteCourse("数学")
        XCTAssertEqual(store.state.courses, ["物理"])
        XCTAssertFalse(store.state.chats.contains { $0.id == removed })
        XCTAssertTrue(store.state.chats.contains { $0.id == kept })
        XCTAssertEqual(store.state.currentID, kept)
        XCTAssertTrue(store.state.files.isEmpty); XCTAssertNil(store.state.subjects["数学"]); XCTAssertNil(store.state.courseNotes["数学"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.images.url(for: image).path))
        let restored = LearningStore(fileURL: folder.appendingPathComponent("state.json"))
        XCTAssertEqual(restored.state.courses, ["物理"])
        XCTAssertEqual(restored.state.currentID, kept)
        store.deleteCourse("物理")
        XCTAssertTrue(store.state.courses.isEmpty)
        XCTAssertNotNil(store.current); XCTAssertEqual(store.current?.course, "")
    }
    func testRenameBeforeFirstMessageIsSaved() throws {
        let id = try XCTUnwrap(store.state.currentID)
        store.renameChat(id, to: "  周一作业  ")
        store.renameChat(id, to: "   ")
        let restored = LearningStore(fileURL: folder.appendingPathComponent("state.json"))
        XCTAssertEqual(restored.current?.title, "周一作业")
        XCTAssertEqual(restored.current?.titleEdited, true)
    }
    func testMigrationPreservesExistingCoursesChatsAndFilenameAttachments() throws {
        var legacy = LearningState()
        legacy.courses = ["概率论与数理统计", "高等数学", "线性代数"]
        legacy.selectedCourse = legacy.courses[0]
        legacy.chats = [LearningChat(title: "我的作业", course: legacy.selectedCourse, messages: [LearningMessage(role: "user", text: "附件：旧图.png")])]
        legacy.currentID = legacy.chats[0].id
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var chats = try XCTUnwrap(object["chats"] as? [[String: Any]])
        chats[0].removeValue(forKey: "draftImages"); chats[0].removeValue(forKey: "titleEdited")
        object["chats"] = chats
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("state.json"))
        let restored = LearningStore(fileURL: folder.appendingPathComponent("state.json"))
        XCTAssertEqual(restored.state.courses, legacy.courses)
        XCTAssertEqual(restored.current?.title, "我的作业")
        XCTAssertEqual(restored.current?.messages.first?.text, "附件：旧图.png")
    }
    func testImageHistoryLimitsPayloadToMostRecentEightImages() throws {
        let image = try store.images.importFile(fixture())
        var chat = try XCTUnwrap(store.current)
        var references: [LearningImage] = []
        for _ in 0..<10 {
            var copy = image; copy.id = UUID()
            try FileManager.default.copyItem(at: store.images.url(for: image), to: store.images.url(for: copy))
            references.append(copy)
        }
        chat.messages = references.map { LearningMessage(role: "user", text: "", images: [$0]) }
        let data = try JSONEncoder().encode(store.modelMessages(for: chat))
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(serialized.components(separatedBy: "image_url").count - 1, 16, "Each image has a type and image_url key")
        XCTAssertTrue(serialized.contains("超出本次图片上下文"))
    }
}
