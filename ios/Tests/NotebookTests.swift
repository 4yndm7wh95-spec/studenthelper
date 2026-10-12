import XCTest
import PencilKit
import UIKit
@testable import StudentHelper

@MainActor
final class NotebookTests: XCTestCase {
    private var folder: URL!
    private var store: NotebookStore!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-tests-" + UUID().uuidString, isDirectory: true)
        store = NotebookStore(folder: folder)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder); store = nil
    }

    func testCleanFirstLaunchHasNoSampleNotebook() {
        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertNil(store.currentPage)
        XCTAssertNil(store.storageError)
        XCTAssertFalse(store.isStorageReadOnly)
    }

    func testImageRotationPersistsRendersAndUndoRestoresWholeTransform() throws {
        _ = store.createNotebook(title: "旋转")
        let page = try XCTUnwrap(store.currentPage)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 60)).image { output in
            UIColor.red.setFill(); output.fill(CGRect(x: 0, y: 0, width: 160, height: 60))
        }
        let id = try XCTUnwrap(store.addImage(data: XCTUnwrap(image.pngData()), name: "题目", to: page.id, at: NoteRect(x: 200, y: 200, width: 160, height: 60)))
        let before = try XCTUnwrap(store.page(id: page.id)?.objects.first)
        let originalImage = try NotebookPageRenderer.checkedImage(page: XCTUnwrap(store.page(id: page.id)), store: store).pngData()
        XCTAssertTrue(store.updateObjectTransform(NoteRect(x: 180, y: 160, width: 200, height: 75), rotation: .pi / 3, pageID: page.id, objectID: id))
        let rotated = try XCTUnwrap(store.page(id: page.id)?.objects.first)
        XCTAssertEqual(rotated.angle, .pi / 3, accuracy: 0.0001)
        XCTAssertNotEqual(originalImage, try NotebookPageRenderer.checkedImage(page: XCTUnwrap(store.page(id: page.id)), store: store).pngData())
        let reopened = NotebookStore(folder: folder)
        XCTAssertEqual(reopened.page(id: page.id)?.objects.first, rotated)
        store.undo(); XCTAssertEqual(store.page(id: page.id)?.objects.first, before)
        store.redo(); XCTAssertEqual(store.page(id: page.id)?.objects.first, rotated)
        XCTAssertFalse(store.updateObjectTransform(rotated.frame, rotation: .nan, pageID: page.id, objectID: id))
        let bounded = try NoteObject.bounded(NoteRect(x: 0, y: 0, width: 700, height: 900), rotation: .pi / 4, pageWidth: page.width, pageHeight: page.height)
        let object = NoteObject(frame: bounded, content: before.content, rotation: .pi / 4)
        XCTAssertGreaterThanOrEqual(object.rotatedBounds.minX, -0.001)
        XCTAssertLessThanOrEqual(object.rotatedBounds.maxX, page.width + 0.001)
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as! [String: Any]
        var old = legacy; old.removeValue(forKey: "rotation")
        XCTAssertEqual(try JSONDecoder().decode(NoteObject.self, from: JSONSerialization.data(withJSONObject: old)).angle, 0)
    }

    func testImageCanExtendOutsidePaperAndSurviveReloadAndUndo() throws {
        _ = store.createNotebook(title: "越界图片")
        let page = try XCTUnwrap(store.currentPage)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 60)).image { output in
            UIColor.blue.setFill(); output.fill(CGRect(x: 0, y: 0, width: 160, height: 60))
        }
        let original = NoteRect(x: -80, y: -40, width: page.width * 1.5, height: 300)
        let id = try XCTUnwrap(store.addImage(data: XCTUnwrap(image.pngData()), name: "题目", to: page.id, at: original))
        XCTAssertEqual(store.object(id: id, pageID: page.id)?.frame, original)
        let moved = NoteRect(x: -400, y: page.height - 60, width: page.width * 2, height: 600)
        XCTAssertTrue(store.updateObjectTransform(moved, rotation: .pi / 4, pageID: page.id, objectID: id))
        let reopened = NotebookStore(folder: folder)
        XCTAssertNil(reopened.storageError)
        XCTAssertEqual(reopened.object(id: id, pageID: page.id)?.frame, moved)
        XCTAssertNoThrow(try NotebookPageRenderer.checkedImage(page: XCTUnwrap(reopened.currentPage), store: reopened))
        store.undo(); XCTAssertEqual(store.object(id: id, pageID: page.id)?.frame, original)
        store.redo(); XCTAssertEqual(store.object(id: id, pageID: page.id)?.frame, moved)
        XCTAssertFalse(store.updateObjectFrame(NoteRect(x: -.infinity, y: 0, width: 10, height: 10), pageID: page.id, objectID: id))
    }

    func testNotebookAndPageCRUDOrderAndSelectionPersist() throws {
        let a = try XCTUnwrap(store.createNotebook(title: "数学", course: "高等数学"))
        let first = try XCTUnwrap(store.currentPage?.id)
        let second = try XCTUnwrap(store.createPage(title: "极限", paper: .grid))
        store.renamePage(first, title: "定义")
        store.reorderPages(notebookID: a, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.notebook(id: a)?.pages.map(\.id), [second, first])
        XCTAssertEqual(store.page(id: second)?.paper, .grid)
        let b = try XCTUnwrap(store.createNotebook(title: "物理"))
        store.reorderNotebooks(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(store.notebooks.map(\.id), [a, b])
        store.renameNotebook(a, title: "数学 · 课堂")
        store.selectPage(first)

        let restored = NotebookStore(folder: folder)
        XCTAssertEqual(restored.currentNotebook?.id, a)
        XCTAssertEqual(restored.currentPage?.title, "定义")
        XCTAssertEqual(restored.notebook(id: a)?.course, "高等数学")
        XCTAssertEqual(restored.notebook(id: a)?.title, "数学 · 课堂")
        restored.deleteNotebook(b)
        XCTAssertEqual(NotebookStore(folder: folder).notebooks.map(\.id), [a])
    }

    func testInkAndTransparentImageRemainSeparateAcrossRestartAndUndo() throws {
        _ = try XCTUnwrap(store.createNotebook(title: "手写测试"))
        let pageID = try XCTUnwrap(store.currentPage?.id)
        let ink = drawing(strokes: 1)
        XCTAssertTrue(store.updateDrawing(ink, pageID: pageID))
        let drawingAsset = try XCTUnwrap(store.currentPage?.drawingAsset)
        let imageID = try XCTUnwrap(store.addImage(data: imageData(), name: "图形.png", to: pageID))
        let asset = try XCTUnwrap(store.object(id: imageID, pageID: pageID)?.image)
        XCTAssertEqual(store.currentPage?.drawingAsset, drawingAsset, "Inserting an image must not flatten it into ink")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.repository.drawingsFolder.appendingPathComponent(drawingAsset).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.repository.imagesFolder.appendingPathComponent(asset.fileName).path))

        let restored = NotebookStore(folder: folder)
        XCTAssertEqual(restored.drawing(for: pageID).strokes.count, 1)
        XCTAssertEqual(restored.drawing(for: pageID).bounds, ink.bounds)
        XCTAssertNotNil(restored.image(for: asset))
        XCTAssertEqual(restored.currentPage?.objects.first?.id, imageID)
        store.removeObject(pageID: pageID, objectID: imageID)
        XCTAssertTrue(store.currentPage?.objects.isEmpty == true)
        store.undo()
        XCTAssertEqual(store.currentPage?.objects.first?.id, imageID)
        XCTAssertNotNil(store.image(for: asset))
        XCTAssertEqual(store.drawing(for: pageID).strokes.count, 1)
    }

    func testDeletingLastPageCreatesReplacementAndUndoRestoresContents() throws {
        _ = try XCTUnwrap(store.createNotebook())
        let old = try XCTUnwrap(store.currentPage?.id)
        let text = try XCTUnwrap(store.addText("保留这个证明", to: old))
        XCTAssertTrue(store.updateDrawing(drawing(strokes: 1), pageID: old))
        store.deletePage(old)
        let replacement = try XCTUnwrap(store.currentPage?.id)
        XCTAssertNotEqual(replacement, old)
        XCTAssertEqual(store.currentNotebook?.pages.count, 1)
        XCTAssertNil(store.page(id: old))
        XCTAssertEqual(NotebookStore(folder: folder).currentPage?.id, replacement)
        store.undo()
        XCTAssertEqual(store.currentPage?.id, old)
        XCTAssertEqual(store.currentPage?.objects.first?.id, text)
        XCTAssertEqual(store.drawing(for: old).strokes.count, 1)
        store.redo()
        XCTAssertEqual(store.currentPage?.id, replacement)
    }

    func testProblemImageKeepsAspectRatioAndLeavesRoomForHandwrittenSolution() throws {
        _ = try XCTUnwrap(store.createNotebook(title: "图片题目"))
        let page = try XCTUnwrap(store.currentPage)
        let tallID = try XCTUnwrap(store.addImage(data: imageData(size: CGSize(width: 120, height: 600)), name: "竖向题目.png", to: page.id))
        let tall = try XCTUnwrap(store.object(id: tallID, pageID: page.id)?.frame)
        XCTAssertEqual(tall.x, 64, accuracy: 0.001)
        XCTAssertEqual(tall.y, 64, accuracy: 0.001)
        XCTAssertEqual(tall.width / tall.height, 0.2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(tall.height, page.height * 0.35 + 0.001)
        XCTAssertGreaterThan(page.height - tall.y - tall.height, page.height * 0.5,
                             "A tall problem must leave the lower half free for working through it")

        let wideID = try XCTUnwrap(store.addImage(data: imageData(), name: "另一道题目.png", to: page.id))
        let wide = try XCTUnwrap(store.object(id: wideID, pageID: page.id)?.frame)
        XCTAssertEqual(wide.width / wide.height, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(wide.width, min(640, page.width - 128))
        XCTAssertEqual(wide.y, tall.y + tall.height + 24, accuracy: 0.001)
        XCTAssertFalse(tall.cgRect.intersects(wide.cgRect))
        XCTAssertLessThanOrEqual(wide.y + wide.height, page.height)

        let chosen = NoteRect(x: 300, y: 500, width: 240, height: 80)
        let chosenID = try XCTUnwrap(store.addImage(data: imageData(), name: "自定尺寸.png", to: page.id, at: chosen))
        XCTAssertEqual(store.object(id: chosenID, pageID: page.id)?.frame, chosen,
                       "An explicit user frame must not be replaced by the default problem layout")
        let restored = NotebookStore(folder: folder)
        XCTAssertEqual(restored.object(id: tallID, pageID: page.id)?.frame, tall)
        XCTAssertEqual(restored.object(id: wideID, pageID: page.id)?.frame, wide)
    }

    func testDrawingGroupIsOneUndoAndRestoresNativeInkOnDisk() throws {
        _ = try XCTUnwrap(store.createNotebook())
        let pageID = try XCTUnwrap(store.currentPage?.id)
        store.beginUndoGroup()
        XCTAssertTrue(store.updateDrawing(drawing(strokes: 1), pageID: pageID))
        XCTAssertTrue(store.updateDrawing(drawing(strokes: 2), pageID: pageID))
        store.endUndoGroup()
        XCTAssertEqual(store.drawing(for: pageID).strokes.count, 2)
        store.undo()
        XCTAssertEqual(store.drawing(for: pageID).strokes.count, 0)
        XCTAssertEqual(NotebookStore(folder: folder).drawing(for: pageID).strokes.count, 0)
        store.redo()
        XCTAssertEqual(store.drawing(for: pageID).strokes.count, 2)
    }

    func testObjectBoundsClampAndNonFiniteChangesDoNotPublish() throws {
        _ = try XCTUnwrap(store.createNotebook())
        let pageID = try XCTUnwrap(store.currentPage?.id)
        let objectID = try XCTUnwrap(store.addText("注释", to: pageID,
                                                at: NoteRect(x: -80, y: 2000, width: 2000, height: 2000)))
        let frame = try XCTUnwrap(store.object(id: objectID, pageID: pageID)?.frame)
        XCTAssertEqual(frame, NoteRect(x: 0, y: 0, width: 768, height: 1086))
        let before = store.library
        XCTAssertFalse(store.updateObjectFrame(NoteRect(x: .nan, y: 20, width: 200, height: 60), pageID: pageID, objectID: objectID))
        XCTAssertEqual(store.library, before)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try store.repository.load(), before)
    }

    func testReviewedActionBatchIsAtomicAndOneUndo() throws {
        _ = try XCTUnwrap(store.createNotebook())
        let pageID = try XCTUnwrap(store.currentPage?.id)
        let before = store.library
        let frame = NoteRect(x: 70, y: 80, width: 400, height: 100)
        XCTAssertNil(store.apply([
            .addText(pageID: pageID, text: "不能只执行第一步", frame: frame),
            .renamePage(pageID: UUID(), title: "不存在")
        ]))
        XCTAssertEqual(store.library, before)
        XCTAssertEqual(try store.repository.load(), before)
        let results = try XCTUnwrap(store.apply([
            .addText(pageID: pageID, text: "导数提示", frame: frame),
            .setPaper(pageID: pageID, paper: .dotted)
        ]))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(store.currentPage?.objects.count, 1)
        XCTAssertEqual(store.currentPage?.paper, .dotted)
        store.undo()
        XCTAssertEqual(store.library, before)
        let context = try XCTUnwrap(store.readContext(pageID: pageID))
        XCTAssertEqual(context.pageID, pageID)
        XCTAssertEqual(context.width, 768)
        XCTAssertFalse(context.hasDrawing)
        XCTAssertNoThrow(try JSONEncoder().encode(context))
    }

    func testUnreadableIndexCannotBeOverwrittenWithoutPreservedBackup() throws {
        _ = try XCTUnwrap(store.createNotebook(title: "原笔记"))
        let damaged = Data("{ broken index".utf8)
        try damaged.write(to: store.repository.indexURL)
        let protected = NotebookStore(folder: folder)
        XCTAssertTrue(protected.isStorageReadOnly)
        XCTAssertNotNil(protected.storageError)
        XCTAssertNil(protected.createNotebook(title: "不能覆盖"))
        protected.save()
        XCTAssertEqual(try Data(contentsOf: protected.repository.indexURL), damaged)
        let preservedAsset = protected.repository.drawingsFolder.appendingPathComponent("old.pkdraw")
        try FileManager.default.createDirectory(at: protected.repository.drawingsFolder, withIntermediateDirectories: true)
        try Data("valuable original".utf8).write(to: preservedAsset)
        protected.recoverStorage()
        XCTAssertFalse(protected.isStorageReadOnly)
        XCTAssertTrue(protected.notebooks.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), damaged)
        for index in 0..<22 { _ = protected.createNotebook(title: "新笔记 \(index)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedAsset.path), "Unknown references in the backup must be preserved")
    }

    func testFailedWriteLeavesMemoryAndExistingFileUntouched() throws {
        let blockingFile = folder.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentinel = Data("keep this file".utf8)
        try sentinel.write(to: blockingFile)
        let blocked = NotebookStore(folder: blockingFile)
        XCTAssertNil(blocked.createNotebook(title: "无法保存"))
        XCTAssertTrue(blocked.notebooks.isEmpty)
        XCTAssertNotNil(blocked.storageError)
        XCTAssertEqual(try Data(contentsOf: blockingFile), sentinel)
        XCTAssertFalse(blocked.canUndo)
    }

    func testFailedInkSaveKeepsDraftAcrossPageSwitchAndRetriesOnSave() throws {
        _ = try XCTUnwrap(store.createNotebook())
        let first = try XCTUnwrap(store.currentPage?.id)
        let second = try XCTUnwrap(store.createPage())
        // A file in place of the asset directory simulates a real write failure
        // while leaving the existing atomic library index intact.
        let sentinel = Data("keep blocking asset".utf8)
        try sentinel.write(to: store.repository.drawingsFolder)
        let previousIndex = try Data(contentsOf: store.repository.indexURL)
        XCTAssertFalse(store.updateDrawing(drawing(strokes: 2), pageID: first))
        XCTAssertEqual(store.pendingDrawingPageIDs, [first])
        XCTAssertEqual(store.drawing(for: first).strokes.count, 2)
        XCTAssertEqual(try Data(contentsOf: store.repository.indexURL), previousIndex)
        store.selectPage(second); store.selectPage(first)
        XCTAssertEqual(store.drawing(for: first).strokes.count, 2)
        // A deletion must not make the unsaved draft impossible to recover.
        store.deletePage(first)
        XCTAssertNotNil(store.page(id: first))
        XCTAssertEqual(try Data(contentsOf: store.repository.drawingsFolder), sentinel)
        try FileManager.default.removeItem(at: store.repository.drawingsFolder)
        store.save()
        XCTAssertTrue(store.pendingDrawingPageIDs.isEmpty)
        XCTAssertNil(store.storageError)
        XCTAssertEqual(NotebookStore(folder: folder).drawing(for: first).strokes.count, 2)
    }

    func testDamagedNativeInkIsReportedAndCannotBeReplacedByFallbackBlank() throws {
        _ = try XCTUnwrap(store.createNotebook())
        let id = try XCTUnwrap(store.currentPage?.id)
        XCTAssertTrue(store.updateDrawing(drawing(strokes: 1), pageID: id))
        let asset = try XCTUnwrap(store.currentPage?.drawingAsset)
        let url = store.repository.drawingsFolder.appendingPathComponent(asset)
        let damaged = Data("damaged native drawing".utf8)
        try damaged.write(to: url)
        let restored = NotebookStore(folder: folder)
        XCTAssertNil(restored.readContext(pageID: id), "A read tool must not claim damaged ink is an empty page")
        XCTAssertEqual(restored.drawing(for: id).strokes.count, 0)
        XCTAssertNotNil(restored.storageError)
        XCTAssertFalse(restored.updateDrawing(PKDrawing(), pageID: id))
        restored.save()
        XCTAssertEqual(restored.page(id: id)?.drawingAsset, asset)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertEqual(try restored.repository.load().notebooks[0].pages[0].drawingAsset, asset)
    }

    func testMaintenanceKeepsAssetReferencedByUndoAfterManyEdits() throws {
        _ = try XCTUnwrap(store.createNotebook())
        let id = try XCTUnwrap(store.currentPage?.id)
        XCTAssertTrue(store.updateDrawing(drawing(strokes: 1), pageID: id))
        let oldAsset = try XCTUnwrap(store.currentPage?.drawingAsset)
        XCTAssertTrue(store.updateDrawing(drawing(strokes: 2), pageID: id))
        for index in 0..<25 { store.renamePage(id, title: "第 \(index) 次修改") }
        let oldURL = store.repository.drawingsFolder.appendingPathComponent(oldAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        for _ in 0..<26 { store.undo() }
        XCTAssertEqual(store.drawing(for: id).strokes.count, 1)
        XCTAssertEqual(store.currentPage?.drawingAsset, oldAsset)
        XCTAssertEqual(NotebookStore(folder: folder).drawing(for: id).strokes.count, 1)
    }

    func testMaintenanceOnUndoCommitKeepsOutgoingInkForRedo() throws {
        _ = try XCTUnwrap(store.createNotebook()) // Commit 1.
        let id = try XCTUnwrap(store.currentPage?.id)
        for index in 0..<17 { store.renamePage(id, title: "页名 \(index)") } // Commits 2–18.
        XCTAssertTrue(store.updateDrawing(drawing(strokes: 1), pageID: id)) // Commit 19.
        let newestAsset = try XCTUnwrap(store.currentPage?.drawingAsset)
        store.undo() // Commit 20 runs maintenance before the redo stack changes.
        XCTAssertEqual(store.drawing(for: id).strokes.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.repository.drawingsFolder.appendingPathComponent(newestAsset).path))
        store.redo()
        XCTAssertEqual(store.drawing(for: id).strokes.count, 1)
        XCTAssertEqual(NotebookStore(folder: folder).drawing(for: id).strokes.count, 1)
    }

    func testInvalidAssetPathCannotEscapeLibrary() throws {
        _ = try XCTUnwrap(store.createNotebook())
        var invalid = store.library
        invalid.notebooks[0].pages[0].drawingAsset = "../../outside.pkdraw"
        XCTAssertThrowsError(try store.repository.save(invalid))
        XCTAssertEqual(try store.repository.load(), store.library)
    }

    private func drawing(strokes count: Int) -> PKDrawing {
        let strokes = (0..<count).map { index -> PKStroke in
            let points = (0..<3).map { point in
                PKStrokePoint(location: CGPoint(x: 70 + point * 40, y: 100 + index * 60), timeOffset: Double(point) * 0.1,
                              size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1)))
        }
        return PKDrawing(strokes: strokes)
    }
    private func imageData(size: CGSize = CGSize(width: 120, height: 60)) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 20, y: 10, width: max(1, size.width - 40), height: max(1, size.height - 20)))
        }
        return try XCTUnwrap(image.pngData())
    }
}
