import SwiftUI
import PencilKit
import UIKit

@MainActor
final class NotebookStore: ObservableObject {
    @Published private(set) var library: NoteLibrary
    @Published var storageError: String?
    @Published private(set) var isStorageReadOnly = false
    @Published private(set) var pendingDrawingPageIDs = Set<UUID>()
    let repository: NoteRepository
    private var undoHistory: [NoteLibrary] = []
    private var redoHistory: [NoteLibrary] = []
    private var groupInitial: NoteLibrary?
    private var groupDepth = 0
    private var drawingCache: [String: PKDrawing] = [:]
    // A full disk must not erase ink when its canvas is dismantled or changed.
    // Drafts remain in memory, visible on reopening the page, until a retry commits.
    private var pendingDrawings: [UUID: PKDrawing] = [:]
    private let imageCache = NSCache<NSString, UIImage>()
    private var commitCount = 0

    var notebooks: [NoteBookDocument] { library.notebooks }
    var currentNotebook: NoteBookDocument? { library.notebooks.first { $0.id == library.selectedNotebookID } }
    var currentPage: NotePage? { currentNotebook?.pages.first { $0.id == library.selectedPageID } }
    var canUndo: Bool { !isStorageReadOnly && (!undoHistory.isEmpty || (groupInitial != nil && groupInitial != library)) }
    var canRedo: Bool { !isStorageReadOnly && !redoHistory.isEmpty }

    init(folder: URL? = nil) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let preview = folder == nil && args.contains("--notebook-preview")
        let isolated = folder == nil && (preview || args.contains("--ui-tests-reset"))
        let testFolder: URL?
        if folder == nil, let flag = args.firstIndex(of: "--notebook-test-id"), args.indices.contains(flag + 1),
           let id = UUID(uuidString: args[flag + 1]) {
            testFolder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-ui-" + id.uuidString, isDirectory: true)
        } else { testFolder = nil }
        #else
        let preview = false, isolated = false
        let testFolder: URL? = nil
        #endif
        repository = NoteRepository(folder: testFolder ?? (isolated ? FileManager.default.temporaryDirectory.appendingPathComponent("notebooks-" + UUID().uuidString) : folder))
        do { library = try repository.load() }
        catch {
            library = NoteLibrary(); storageError = error.localizedDescription; isStorageReadOnly = true
        }
        normalizeSelection(&library)
        imageCache.countLimit = 24
        imageCache.totalCostLimit = 64 * 1024 * 1024
        #if DEBUG
        if preview {
            let first = createNotebook(title: "微积分 · 课堂笔记", course: "高等数学", coverColor: "#496357")
            if let page = currentPage {
                _ = addText("第二章 · 导数与微分\n\n今天先整理：函数在一点的变化率。", to: page.id,
                            at: NoteRect(x: 72, y: 80, width: 610, height: 140))
                _ = addText("先看图，再列式。\n把每一步的理由写在旁边。", to: page.id,
                            at: NoteRect(x: 88, y: 310, width: 560, height: 120))
            }
            _ = createNotebook(title: "概率论 · 习题整理", course: "概率论", coverColor: "#D97757")
            if let first { selectNotebook(first) }
            undoHistory.removeAll(); redoHistory.removeAll()
        }
        #endif
    }

    func notebook(id: UUID) -> NoteBookDocument? { notebooks.first { $0.id == id } }
    func page(id: UUID) -> NotePage? { notebooks.lazy.flatMap(\.pages).first { $0.id == id } }
    func object(id: UUID, pageID: UUID) -> NoteObject? { page(id: pageID)?.objects.first { $0.id == id } }

    func selectNotebook(_ id: UUID) {
        guard let book = notebook(id: id) else { return }
        var next = library
        next.selectedNotebookID = id
        if !book.pages.contains(where: { $0.id == next.selectedPageID }) { next.selectedPageID = book.pages.first?.id }
        _ = commit(next, recordUndo: false)
    }

    func selectPage(_ id: UUID) {
        guard let book = notebooks.first(where: { $0.pages.contains(where: { $0.id == id }) }) else { return }
        var next = library; next.selectedNotebookID = book.id; next.selectedPageID = id
        _ = commit(next, recordUndo: false)
    }

    @discardableResult
    func createNotebook(title: String = "新笔记本", course: String = "", coverColor: String = "#496357") -> UUID? {
        do {
            let title = try cleanedTitle(title)
            var book = NoteBookDocument(); book.title = title; book.course = course; book.coverColor = coverColor
            var next = library; next.notebooks.insert(book, at: 0)
            next.selectedNotebookID = book.id; next.selectedPageID = book.pages[0].id
            return commit(next) ? book.id : nil
        } catch { report(error); return nil }
    }

    func renameNotebook(_ id: UUID, title: String) { _ = apply(.renameNotebook(notebookID: id, title: title)) }
    func renamePage(_ id: UUID, title: String) { _ = apply(.renamePage(pageID: id, title: title)) }

    func deleteNotebook(_ id: UUID) {
        flushActiveCanvas()
        finishUndoGroup()
        guard let book = notebook(id: id) else { return }
        guard retryPendingDrawings(pageIDs: Set(book.pages.map(\.id))) else { return }
        var next = library; next.notebooks.removeAll { $0.id == id }; normalizeSelection(&next)
        _ = commit(next)
    }

    func reorderNotebooks(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard validMove(source, destination: destination, count: notebooks.count) else { return }
        var next = library; next.notebooks.move(fromOffsets: source, toOffset: destination); _ = commit(next)
    }

    @discardableResult
    func createPage(notebookID: UUID? = nil, title: String = "", paper: NotePaper = .ruled) -> UUID? {
        guard let bookID = notebookID ?? library.selectedNotebookID, let book = notebook(id: bookID) else {
            report(NoteStorageError.missingNotebook); return nil
        }
        let after = book.pages.contains { $0.id == library.selectedPageID } ? library.selectedPageID : nil
        return apply(.createPage(notebookID: bookID, afterPageID: after, title: title, paper: paper))?.pageID
    }

    /// Deleting the only page inserts a fresh page in the same atomic transaction.
    func deletePage(_ id: UUID) {
        flushActiveCanvas()
        finishUndoGroup()
        guard retryPendingDrawings(pageIDs: [id]) else { return }
        do {
            var next = library
            let (n, p) = try location(of: id, in: next)
            next.notebooks[n].pages.remove(at: p)
            if next.notebooks[n].pages.isEmpty { next.notebooks[n].pages = [NotePage()] }
            next.notebooks[n].updatedAt = Date()
            if next.selectedPageID == id {
                next.selectedPageID = next.notebooks[n].pages[min(p, next.notebooks[n].pages.count - 1)].id
            }
            normalizeSelection(&next); _ = commit(next)
        } catch { report(error) }
    }

    func reorderPages(notebookID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let n = library.notebooks.firstIndex(where: { $0.id == notebookID }),
              validMove(source, destination: destination, count: library.notebooks[n].pages.count) else { return }
        var next = library
        next.notebooks[n].pages.move(fromOffsets: source, toOffset: destination)
        next.notebooks[n].updatedAt = Date(); _ = commit(next)
    }

    func setPaper(_ paper: NotePaper, pageID: UUID) { _ = apply(.setPaper(pageID: pageID, paper: paper)) }

    @discardableResult
    func addText(_ text: String, to pageID: UUID, at frame: NoteRect? = nil) -> UUID? {
        let frame = frame ?? NoteRect(x: 64, y: 80, width: 460, height: 160)
        return apply(.addText(pageID: pageID, text: text, frame: frame))?.objectID
    }

    func updateText(_ text: String, pageID: UUID, objectID: UUID) {
        _ = apply(.updateText(pageID: pageID, objectID: objectID, text: text))
    }

    @discardableResult
    func cropImage(pageID: UUID, objectID: UUID, region: CGRect, expectedAssetID: UUID? = nil) -> Bool {
        flushActiveCanvas(); finishUndoGroup()
        guard retryPendingDrawings(pageIDs: [pageID]) else { return false }
        do {
            try ensureWritable()
            guard region.origin.x.isFinite, region.origin.y.isFinite, region.width.isFinite, region.height.isFinite,
                  region.width > 0, region.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(region) else { throw NoteStorageError.invalidGeometry }
            var next = library; let (n, p) = try location(of: pageID, in: next)
            let index = try objectIndex(objectID, page: next.notebooks[n].pages[p])
            let object = next.notebooks[n].pages[p].objects[index]
            guard let asset = object.image, expectedAssetID == nil || expectedAssetID == asset.id,
                  let image = image(for: asset), let source = image.cgImage else { throw NoteStorageError.invalidAsset }
            let pixels = CGRect(x: region.minX * CGFloat(source.width), y: region.minY * CGFloat(source.height),
                width: region.width * CGFloat(source.width), height: region.height * CGFloat(source.height)).integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard let cropped = source.cropping(to: pixels), let data = UIImage(cgImage: cropped).pngData() else { throw NoteStorageError.invalidAsset }
            let replacement = try repository.importImage(data, name: asset.name)
            let normalized = CGRect(x: pixels.minX / CGFloat(source.width), y: pixels.minY / CGFloat(source.height),
                width: pixels.width / CGFloat(source.width), height: pixels.height / CGFloat(source.height))
            let original = object.frame.cgRect
            let delta = CGPoint(x: (normalized.midX - 0.5) * original.width, y: (normalized.midY - 0.5) * original.height)
                .applying(CGAffineTransform(rotationAngle: CGFloat(object.angle)))
            let size = CGSize(width: original.width * normalized.width, height: original.height * normalized.height)
            let frame = CGRect(x: original.midX + delta.x - size.width / 2, y: original.midY + delta.y - size.height / 2, width: size.width, height: size.height)
            next.notebooks[n].pages[p].objects[index].content = .image(replacement)
            next.notebooks[n].pages[p].objects[index].frame = try NoteObject.freeImageFrame(NoteRect(frame), rotation: object.angle)
            touch(&next, notebook: n, page: p)
            return commit(next)
        } catch { report(error); return false }
    }

    @discardableResult
    func updateObjectTransform(_ frame: NoteRect, rotation: Double, pageID: UUID, objectID: UUID) -> Bool {
        apply(.setObjectTransform(pageID: pageID, objectID: objectID, frame: frame, rotation: rotation)) != nil
    }

    @discardableResult
    func updateObjectFrame(_ frame: NoteRect, pageID: UUID, objectID: UUID) -> Bool {
        apply(.setObjectFrame(pageID: pageID, objectID: objectID, frame: frame)) != nil
    }

    func removeObject(pageID: UUID, objectID: UUID) { _ = apply(.deleteObject(pageID: pageID, objectID: objectID)) }

    @discardableResult
    func addImage(data: Data, name: String, to pageID: UUID, at frame: NoteRect? = nil) -> UUID? {
        do {
            try ensureWritable()
            var next = library; let (n, p) = try location(of: pageID, in: next)
            let asset = try repository.importImage(data, name: name)
            let page = next.notebooks[n].pages[p]
            let placedFrame: NoteRect
            if let frame {
                placedFrame = try NoteObject.freeImageFrame(frame)
            } else {
                placedFrame = defaultImageFrame(asset, page: page)
            }
            let object = NoteObject(frame: placedFrame, content: .image(asset))
            next.notebooks[n].pages[p].objects.append(object)
            touch(&next, notebook: n, page: p)
            return commit(next) ? object.id : nil
        } catch { report(error); return nil }
    }

    func drawing(for pageID: UUID) -> PKDrawing {
        do { return try drawingChecked(for: pageID) }
        catch { report(error); return PKDrawing() }
    }

    /// Consumers that read page evidence can reject missing ink instead of treating
    /// a damaged native asset as a genuinely empty page.
    func drawingChecked(for pageID: UUID) throws -> PKDrawing {
        guard let page = page(id: pageID) else { throw NoteStorageError.missingPage }
        if let pending = pendingDrawings[pageID] { return pending }
        if let key = page.drawingAsset, let cached = drawingCache[key] { return cached }
        let drawing = try repository.drawing(for: page)
        if let key = page.drawingAsset { cache(drawing, key: key) }
        return drawing
    }

    @discardableResult
    func updateDrawing(_ drawing: PKDrawing, pageID: UUID) -> Bool {
        do {
            try ensureWritable()
            var next = library; let (n, p) = try location(of: pageID, in: next)
            let old = try repository.drawing(for: next.notebooks[n].pages[p])
            if old.dataRepresentation() == drawing.dataRepresentation() {
                clearPendingDrawing(pageID); return true
            }
            let asset = try repository.saveDrawing(drawing, pageID: pageID)
            next.notebooks[n].pages[p].drawingAsset = asset
            next.notebooks[n].pages[p].drawingChecksum = NoteRepository.checksum(drawing.dataRepresentation())
            touch(&next, notebook: n, page: p)
            if commit(next) { cache(drawing, key: asset); clearPendingDrawing(pageID); return true }
            retainPendingDrawing(drawing, pageID: pageID)
            return false
        } catch {
            if page(id: pageID) != nil { retainPendingDrawing(drawing, pageID: pageID) }
            report(error); return false
        }
    }

    func imageData(for asset: NoteImageAsset) -> Data? {
        do { return try repository.imageData(for: asset) }
        catch { report(error); return nil }
    }
    func image(for asset: NoteImageAsset) -> UIImage? {
        let key = asset.fileName as NSString
        if let image = imageCache.object(forKey: key) { return image }
        guard let data = imageData(for: asset), let image = UIImage(data: data) else { return nil }
        let cost = (image.cgImage?.width ?? 0) * (image.cgImage?.height ?? 0) * 4
        imageCache.setObject(image, forKey: key, cost: cost); return image
    }

    func readContext(pageID: UUID) -> NoteReadContext? {
        guard let book = notebooks.first(where: { $0.pages.contains { $0.id == pageID } }),
              let page = book.pages.first(where: { $0.id == pageID }) else { return nil }
        let ink: PKDrawing
        do { ink = try drawingChecked(for: pageID) }
        catch { report(error); return nil }
        return NoteReadContext(notebookID: book.id, notebookTitle: book.title, course: book.course,
                               pageID: page.id, pageTitle: page.title, paper: page.paper,
                               width: page.width, height: page.height, objects: page.objects,
                               hasDrawing: !ink.strokes.isEmpty,
                               drawingBounds: ink.strokes.isEmpty ? nil : NoteRect(ink.bounds))
    }

    @discardableResult func apply(_ action: NoteAction) -> NoteActionResult? { apply([action])?.first }

    /// Applies an entire reviewed proposal or none of it, with one undo entry.
    @discardableResult
    func apply(_ actions: [NoteAction]) -> [NoteActionResult]? {
        do {
            try ensureWritable()
            var next = library
            let results = try actions.map { try perform($0, in: &next) }
            return commit(next) ? results : nil
        } catch { report(error); return nil }
    }

    func beginUndoGroup() {
        if groupDepth == 0 { groupInitial = library }
        groupDepth += 1
    }
    func endUndoGroup() {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        if groupDepth == 0 {
            if let initial = groupInitial, initial != library { pushUndo(initial); redoHistory.removeAll() }
            groupInitial = nil; objectWillChange.send()
        }
    }
    func undo() {
        guard retryPendingDrawings() else { return }
        finishUndoGroup()
        guard let previous = undoHistory.last, !isStorageReadOnly else { return }
        let current = library
        if commit(previous, recordUndo: false) {
            undoHistory.removeLast(); redoHistory.append(current); objectWillChange.send()
        }
    }
    func redo() {
        guard retryPendingDrawings() else { return }
        finishUndoGroup()
        guard let next = redoHistory.last, !isStorageReadOnly else { return }
        let current = library
        if commit(next, recordUndo: false) {
            redoHistory.removeLast(); pushUndo(current); objectWillChange.send()
        }
    }

    func save() {
        // A lasso/menu change may still be waiting for the canvas debounce.
        // Save the live canvas before retrying drafts or writing the index.
        flushActiveCanvas()
        guard retryPendingDrawings() else { return }
        do { try ensureWritable(); try repository.save(library); storageError = nil }
        catch { report(error) }
    }

    func retryLoad() {
        guard retryPendingDrawings() else { return }
        do {
            var loaded = try repository.load(); normalizeSelection(&loaded)
            library = loaded; undoHistory.removeAll(); redoHistory.removeAll()
            groupInitial = nil; groupDepth = 0; drawingCache.removeAll(); imageCache.removeAllObjects()
            isStorageReadOnly = false; storageError = nil
        } catch { isStorageReadOnly = true; report(error) }
    }

    /// The UI must explain this recovery action. Existing assets and the backed-up
    /// unreadable index stay on disk; a failed backup never enables replacement.
    func recoverStorage() {
        guard isStorageReadOnly else { return }
        do {
            _ = try repository.backupIndex()
            let fresh = NoteLibrary(); try repository.save(fresh)
            library = fresh; undoHistory.removeAll(); redoHistory.removeAll()
            groupInitial = nil; groupDepth = 0; drawingCache.removeAll(); imageCache.removeAllObjects()
            isStorageReadOnly = false; storageError = nil
        } catch { report(error) }
    }

    private func perform(_ action: NoteAction, in next: inout NoteLibrary) throws -> NoteActionResult {
        switch action {
        case .createPage(let notebookID, let afterPageID, let title, let paper):
            guard let n = next.notebooks.firstIndex(where: { $0.id == notebookID }) else { throw NoteStorageError.missingNotebook }
            let position: Int
            if let afterPageID {
                guard let p = next.notebooks[n].pages.firstIndex(where: { $0.id == afterPageID }) else { throw NoteStorageError.missingPage }
                position = p + 1
            } else { position = next.notebooks[n].pages.count }
            var page = NotePage(); page.paper = paper
            page.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "第 \(next.notebooks[n].pages.count + 1) 页" : try cleanedTitle(title)
            next.notebooks[n].pages.insert(page, at: position); next.notebooks[n].updatedAt = Date()
            next.selectedNotebookID = notebookID; next.selectedPageID = page.id
            return NoteActionResult(notebookID: notebookID, pageID: page.id, objectID: nil)
        case .renameNotebook(let notebookID, let title):
            guard let n = next.notebooks.firstIndex(where: { $0.id == notebookID }) else { throw NoteStorageError.missingNotebook }
            next.notebooks[n].title = try cleanedTitle(title); next.notebooks[n].updatedAt = Date()
            return NoteActionResult(notebookID: notebookID, pageID: nil, objectID: nil)
        default:
            let pageID: UUID
            switch action {
            case .renamePage(let id, _), .setPaper(let id, _), .addText(let id, _, _), .appendInk(let id, _),
                 .updateText(let id, _, _), .setObjectFrame(let id, _, _), .setObjectTransform(let id, _, _, _), .deleteObject(let id, _): pageID = id
            default: throw NoteStorageError.missingPage
            }
            let (n, p) = try location(of: pageID, in: next)
            var objectID: UUID?
            switch action {
            case .renamePage(_, let title): next.notebooks[n].pages[p].title = try cleanedTitle(title)
            case .setPaper(_, let paper): next.notebooks[n].pages[p].paper = paper
            case .addText(_, let text, let frame):
                let page = next.notebooks[n].pages[p]
                let object = NoteObject(frame: try frame.clamped(pageWidth: page.width, pageHeight: page.height), content: .text(NoteText(text: text)))
                next.notebooks[n].pages[p].objects.append(object); objectID = object.id
            case .appendInk(_, let data):
                guard data.count <= 8 * 1024 * 1024 else { throw NoteStorageError.invalidAsset }
                let ink = try PKDrawing(data: data)
                let page = next.notebooks[n].pages[p]
                let old = try repository.drawing(for: page)
                let combined = PKDrawing(strokes: old.strokes + ink.strokes)
                let asset = try repository.saveDrawing(combined, pageID: page.id)
                next.notebooks[n].pages[p].drawingAsset = asset
                next.notebooks[n].pages[p].drawingChecksum = NoteRepository.checksum(combined.dataRepresentation())
            case .updateText(_, let id, let text):
                let o = try objectIndex(id, page: next.notebooks[n].pages[p])
                guard case .text(var value) = next.notebooks[n].pages[p].objects[o].content else { throw NoteStorageError.missingObject }
                value.text = text; next.notebooks[n].pages[p].objects[o].content = .text(value); objectID = id
            case .setObjectFrame(_, let id, let frame):
                let page = next.notebooks[n].pages[p], o = try objectIndex(id, page: page)
                next.notebooks[n].pages[p].objects[o].frame = try page.objects[o].placedFrame(frame, rotation: page.objects[o].angle, pageWidth: page.width, pageHeight: page.height); objectID = id
            case .setObjectTransform(_, let id, let frame, let rotation):
                let page = next.notebooks[n].pages[p], o = try objectIndex(id, page: page)
                let normalized = atan2(sin(rotation), cos(rotation))
                guard rotation.isFinite else { throw NoteStorageError.invalidGeometry }
                next.notebooks[n].pages[p].objects[o].frame = try page.objects[o].placedFrame(frame, rotation: normalized, pageWidth: page.width, pageHeight: page.height)
                next.notebooks[n].pages[p].objects[o].rotation = normalized; objectID = id
            case .deleteObject(_, let id):
                let o = try objectIndex(id, page: next.notebooks[n].pages[p])
                next.notebooks[n].pages[p].objects.remove(at: o); objectID = id
            default: break
            }
            touch(&next, notebook: n, page: p)
            return NoteActionResult(notebookID: next.notebooks[n].id, pageID: pageID, objectID: objectID)
        }
    }

    @discardableResult
    private func commit(_ next: NoteLibrary, recordUndo: Bool = true) -> Bool {
        do {
            try ensureWritable()
            guard next != library else { return true }
            try repository.save(next)
            // Undo/redo moves its history entries after this commit returns.
            // Keep the outgoing snapshot through maintenance at this boundary.
            let outgoing = library
            if recordUndo && groupDepth == 0 { pushUndo(library); redoHistory.removeAll() }
            library = next; storageError = nil; commitCount += 1
            if commitCount.isMultiple(of: 20) {
                repository.removeUnreferenced(keeping: [library, outgoing] + undoHistory + redoHistory + (groupInitial.map { [$0] } ?? []))
            }
            return true
        } catch { report(error); return false }
    }

    private func pushUndo(_ state: NoteLibrary) {
        undoHistory.append(state)
        if undoHistory.count > 50 { undoHistory.removeFirst(undoHistory.count - 50) }
    }
    private func finishUndoGroup() { if groupDepth > 0 { groupDepth = 1; endUndoGroup() } }
    private func flushActiveCanvas() {
        NotificationCenter.default.post(name: .notebookFlushDrawing, object: nil)
    }
    private func ensureWritable() throws { if isStorageReadOnly { throw NoteStorageError.readOnly } }
    private func report(_ error: Error) { storageError = error.localizedDescription }
    private func cache(_ drawing: PKDrawing, key: String) {
        // Caching every saved stroke would retain many growing copies of a page.
        // Keep one version per page; undo history references disk assets instead.
        let pagePrefix = String(key.prefix(36)) + "-"
        for oldKey in Array(drawingCache.keys) where oldKey.hasPrefix(pagePrefix) && oldKey != key {
            drawingCache.removeValue(forKey: oldKey)
        }
        if drawingCache.count >= 8 && drawingCache[key] == nil { drawingCache.removeAll() }
        drawingCache[key] = drawing
    }
    private func retainPendingDrawing(_ drawing: PKDrawing, pageID: UUID) {
        pendingDrawings[pageID] = drawing
        if !pendingDrawingPageIDs.contains(pageID) { pendingDrawingPageIDs.insert(pageID) }
    }
    private func clearPendingDrawing(_ pageID: UUID) {
        pendingDrawings.removeValue(forKey: pageID)
        if pendingDrawingPageIDs.contains(pageID) { pendingDrawingPageIDs.remove(pageID) }
    }
    private func defaultImageFrame(_ asset: NoteImageAsset, page: NotePage) -> NoteRect {
        let horizontalInset = min(64, page.width * 0.1)
        let verticalInset = min(64, page.height * 0.1)
        let maxWidth = min(640, page.width - 2 * horizontalInset)
        let maxHeight = min(page.height * 0.35, page.height - 2 * verticalInset)
        let scale = min(maxWidth / Double(asset.width), maxHeight / Double(asset.height))
        let width = Double(asset.width) * scale
        let height = Double(asset.height) * scale
        let previousBottom = page.objects.filter { $0.image != nil }.map { $0.frame.y + $0.frame.height }.max()
        let preferredY = previousBottom.map { $0 + 24 } ?? verticalInset
        // A crowded page can still accept a picture within its bounds; the
        // student can move it or make another page. The picture never stretches.
        let y = min(max(verticalInset, preferredY), page.height - verticalInset - height)
        return NoteRect(x: horizontalInset, y: y, width: width, height: height)
    }
    @discardableResult
    private func retryPendingDrawings(pageIDs: Set<UUID>? = nil) -> Bool {
        let pending = pendingDrawings.filter { pageIDs?.contains($0.key) ?? true }
        guard !pending.isEmpty else { return true }
        do {
            try ensureWritable()
            var next = library
            for (id, ink) in pending {
                let (n, p) = try location(of: id, in: next)
                // Even a retry cannot replace a referenced, unreadable original.
                _ = try repository.drawing(for: next.notebooks[n].pages[p])
                next.notebooks[n].pages[p].drawingAsset = try repository.saveDrawing(ink, pageID: id)
                touch(&next, notebook: n, page: p)
            }
            guard commit(next) else { return false }
            for (id, ink) in pending {
                if let asset = page(id: id)?.drawingAsset { cache(ink, key: asset) }
                clearPendingDrawing(id)
            }
            return true
        } catch { report(error); return false }
    }
    private func cleanedTitle(_ title: String) throws -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw NoteStorageError.emptyTitle }; return String(clean.prefix(200))
    }
    private func location(of pageID: UUID, in state: NoteLibrary) throws -> (Int, Int) {
        for n in state.notebooks.indices {
            if let p = state.notebooks[n].pages.firstIndex(where: { $0.id == pageID }) { return (n, p) }
        }
        throw NoteStorageError.missingPage
    }
    private func objectIndex(_ id: UUID, page: NotePage) throws -> Int {
        guard let index = page.objects.firstIndex(where: { $0.id == id }) else { throw NoteStorageError.missingObject }; return index
    }
    private func touch(_ state: inout NoteLibrary, notebook: Int, page: Int) {
        let now = Date(); state.notebooks[notebook].updatedAt = now; state.notebooks[notebook].pages[page].updatedAt = now
    }
    private func validMove(_ source: IndexSet, destination: Int, count: Int) -> Bool {
        !source.isEmpty && destination >= 0 && destination <= count && source.allSatisfy { $0 >= 0 && $0 < count }
    }
    private func normalizeSelection(_ state: inout NoteLibrary) {
        if !state.notebooks.contains(where: { $0.id == state.selectedNotebookID }) { state.selectedNotebookID = state.notebooks.first?.id }
        let pages = state.notebooks.first { $0.id == state.selectedNotebookID }?.pages ?? []
        if !pages.contains(where: { $0.id == state.selectedPageID }) { state.selectedPageID = pages.first?.id }
    }
}
