import SwiftUI
import UIKit
import PencilKit
import CoreFoundation

enum AppAutomationError: LocalizedError {
    case invalid(String), unavailable(String), failed(String), stopped
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "操作参数无效：" + detail
        case .unavailable(let detail): return detail
        case .failed(let detail): return "操作未完成：" + detail
        case .stopped: return "操作已停止。"
        }
    }
}

extension Notification.Name {
    static let notebookCanvasCommand = Notification.Name("NotebookCanvasCommand")
    static let notebookToolCommand = Notification.Name("NotebookToolCommand")
    static let notebookAutomationStopped = Notification.Name("NotebookAutomationStopped")
}

/// A synchronous acknowledgement comes from the real visible UIKit canvas.
@MainActor
final class NotebookCanvasCommand {
    enum Action {
        case tool(NotebookDrawingTool, UIColor, CGFloat, Bool?)
        case viewport(x: CGFloat?, y: CGFloat?, dx: CGFloat?, dy: CGFloat?, zoom: CGFloat?)
        case region(NoteRect?)
    }
    let pageID: UUID
    let action: Action
    var result: [String: Any]?
    var accepted = false
    var failure: String?
    init(pageID: UUID, action: Action) { self.pageID = pageID; self.action = action }
}

/// All MCP and in-app model operations share this validated document interface.
/// Keys, settings credentials, filesystem paths, and arbitrary code are excluded.
@MainActor
final class AppAutomation: ObservableObject {
    @Published private(set) var active = false
    @Published var destination = "notebooks"
    @Published var requestedNotebookID: UUID?
    @Published var requestedPageID: UUID?
    @Published var operationRegion: NoteRect?
    @Published var status = "正在查看笔记"
    @Published private(set) var navigationRevision = 0
    private var sessionID: UUID?
    private var cancelOperation: (() -> Void)?

    func begin(cancel: @escaping () -> Void) -> UUID? {
        guard !active else { return nil }
        let id = UUID(); sessionID = id; cancelOperation = cancel
        operationRegion = nil; status = "正在查看笔记"; active = true
        return id
    }
    func end(_ id: UUID) {
        guard sessionID == id else { return }
        sessionID = nil; cancelOperation = nil; operationRegion = nil; active = false
        NotificationCenter.default.post(name: .notebookAutomationStopped, object: nil)
    }
    func stop() {
        let cancel = cancelOperation
        sessionID = nil; cancelOperation = nil; operationRegion = nil; active = false
        NotificationCenter.default.post(name: .notebookAutomationStopped, object: nil)
        status = "已停止操作"
        cancel?()
    }

    func perform(_ name: String, args: [String: Any], notebooks: NotebookStore, learning: LearningStore?) async throws -> [[String: Any]] {
        try Task.checkCancellation()
        let session = sessionID
        switch name {
        case "list_notebooks":
            try Self.keys(args, allowed: ["offset", "limit"])
            status = "正在查看笔记本"
            let range = try Self.range(args, count: notebooks.notebooks.count)
            let books = notebooks.notebooks[range].map { ["id": $0.id.uuidString, "title": $0.title, "course": $0.course, "page_count": $0.pages.count] as [String: Any] }
            return try Self.text(["notebooks": books, "total": notebooks.notebooks.count, "next_offset": range.upperBound])
        case "list_pages":
            try Self.keys(args, allowed: ["notebook_id", "offset", "limit"])
            let book = try Self.book(args, notebooks)
            status = "正在查找笔记页面"
            let range = try Self.range(args, count: book.pages.count)
            let pages = range.map { index in
                let page = book.pages[index]
                return ["id": page.id.uuidString, "title": page.title, "paper": page.paper.rawValue, "number": index + 1, "object_count": page.objects.count] as [String: Any]
            }
            return try Self.text(["notebook_id": book.id.uuidString, "pages": pages, "total": book.pages.count, "next_offset": range.upperBound])
        case "read_page":
            try Self.keys(args, allowed: ["page_id", "region"])
            NotificationCenter.default.post(name: .notebookFlushDrawing, object: nil)
            let page = try Self.page(args, notebooks)
            status = "正在看清这页的图片与笔迹"
            let region = try Self.optionalRect(args["region"], page: page)
            guard var context = notebooks.readContext(pageID: page.id) else { throw AppAutomationError.failed(notebooks.storageError ?? "页面无法读取") }
            if let region {
                context.objects = context.objects.filter { region.cgRect.contains($0.frame.cgRect) }
            }
            let image = NotebookAssistantModel.crop(try NotebookPageRenderer.checkedImage(page: page, store: notebooks), region: region)
            guard let data = image.pngData(), data.count <= 8 * 1024 * 1024 else { throw AppAutomationError.failed("页面图片超出传输大小") }
            let drawing = try notebooks.drawingChecked(for: page.id)
            var metadata = try Self.dictionary(context)
            metadata["stroke_count"] = drawing.strokes.count
            metadata["strokes"] = drawing.strokes.enumerated().prefix(256).map { index, stroke in
                ["index": index, "bounds": Self.rectDictionary(stroke.renderBounds), "ink": stroke.ink.inkType.rawValue] as [String: Any]
            }
            if let region { metadata["region"] = Self.rectDictionary(region.cgRect) }
            try ensure(session)
            return try Self.text(metadata) + [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]]
        case "read_ink":
            try Self.keys(args, allowed: ["page_id", "offset", "limit"])
            NotificationCenter.default.post(name: .notebookFlushDrawing, object: nil)
            let page = try Self.page(args, notebooks)
            status = "正在读取原始笔迹"
            let drawing = try notebooks.drawingChecked(for: page.id)
            let range = try Self.range(args, count: drawing.strokes.count, defaultLimit: 16, maximum: 32)
            let strokes = range.map { index -> [String: Any] in
                let stroke = drawing.strokes[index]
                let stride = max(1, Int(ceil(Double(stroke.path.count) / 512)))
                let points = Swift.stride(from: 0, to: stroke.path.count, by: stride).map { pointIndex -> [String: Any] in
                    let sample = stroke.path[pointIndex], point = sample.location.applying(stroke.transform)
                    return ["x": point.x, "y": point.y, "width": sample.size.width, "pressure": sample.force]
                }
                return ["index": index, "ink": stroke.ink.inkType.rawValue, "bounds": Self.rectDictionary(stroke.renderBounds), "points": points, "control_point_count": stroke.path.count]
            }
            return try Self.text(["page_id": page.id.uuidString, "strokes": strokes, "total": drawing.strokes.count, "next_offset": range.upperBound])
        case "search_notes":
            try Self.keys(args, allowed: ["notebook_id", "query", "offset", "limit"])
            let book = try Self.book(args, notebooks), query = try Self.string(args, "query", maximum: 120).lowercased()
            let range = try Self.range(args, count: book.pages.count, defaultLimit: 6, maximum: 12)
            var matches: [[String: Any]] = []
            for index in range {
                try ensure(session)
                let page = book.pages[index]; status = "正在查找“\(String(query.prefix(20)))”"
                let image = try NotebookPageRenderer.checkedImage(page: page, store: notebooks)
                guard let data = image.pngData() else { throw AppAutomationError.failed("页面图片无法读取") }
                let recognized = try await NoteTextRecognizer.recognize(data)
                try ensure(session)
                let text = ([page.title] + page.objects.compactMap(\.text) + [recognized]).joined(separator: "\n")
                if text.lowercased().contains(query) { matches.append(["page_id": page.id.uuidString, "title": page.title, "excerpt": String(text.prefix(1600))]) }
            }
            return try Self.text(["matches": matches, "next_offset": range.upperBound, "total_pages": book.pages.count, "coverage": "本批已识别\(range.count)页；手写识别可能不完整"])
        case "read_app_state":
            return try readState(args, notebooks: notebooks, learning: learning)
        case "perform_app_action":
            guard active, let session else { throw AppAutomationError.unavailable("请先开始操作会话，界面会暂时锁定并提供停止按钮。") }
            try Self.keys(args, allowed: ["action", "parameters"])
            let actionName = try Self.string(args, "action", maximum: 64)
            guard let action = AppAction(rawValue: actionName) else { throw AppAutomationError.invalid("action 不受支持") }
            let parameters = try Self.object(args["parameters"], key: "parameters")
            return try await actionResult(action, args: parameters, notebooks: notebooks, learning: learning, session: session)
        default: throw AppAutomationError.invalid("未知工具 \(name)")
        }
    }

    private func ensure(_ expected: UUID?) throws {
        try Task.checkCancellation()
        if let expected, sessionID != expected { throw AppAutomationError.stopped }
    }

    private func show(page: NotePage, notebooks: NotebookStore) throws {
        guard let book = notebooks.notebooks.first(where: { $0.pages.contains { $0.id == page.id } }) else { throw NoteStorageError.missingNotebook }
        notebooks.selectPage(page.id)
        if let error = notebooks.storageError { throw AppAutomationError.failed(error) }
        destination = "notebooks"; requestedNotebookID = book.id; requestedPageID = page.id
        navigationRevision += 1
    }

    private func canvas(_ command: NotebookCanvasCommand, session: UUID) async throws -> [String: Any] {
        for _ in 0..<40 {
            try ensure(session)
            if !command.accepted { NotificationCenter.default.post(name: .notebookCanvasCommand, object: command) }
            if let failure = command.failure { throw AppAutomationError.failed(failure) }
            if let result = command.result { return result }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AppAutomationError.unavailable("目标页面的书写画布尚未打开，请先打开这一页再操作。")
    }

    private func actionResult(_ action: AppAction, args: [String: Any], notebooks: NotebookStore, learning: LearningStore?, session: UUID) async throws -> [[String: Any]] {
        try ensure(session)
        try Self.keys(args, allowed: action.allowedKeys)
        status = action.status
        operationRegion = nil
        NotificationCenter.default.post(name: .notebookAutomationStopped, object: nil)
        notebooks.storageError = nil
        NotificationCenter.default.post(name: .notebookFlushDrawing, object: nil)
        if action.isNotebookAction, let error = notebooks.storageError { throw AppAutomationError.failed(error) }
        var result: [String: Any] = ["action": action.rawValue]
        switch action {
        case .navigate:
            let target = try Self.string(args, "destination", maximum: 20)
            guard ["notebooks", "chat", "records", "files", "review", "settings"].contains(target) else { throw AppAutomationError.invalid("destination") }
            destination = target; navigationRevision += 1; result["destination"] = target
        case .createNotebook:
            guard notebooks.notebooks.count < 500 else { throw AppAutomationError.invalid("最多500本笔记本") }
            let title = try Self.string(args, "title", maximum: 160)
            let course = try Self.optionalString(args, "course", maximum: 120) ?? ""
            let color = try Self.colorHex(args, "color", fallback: "#496357")
            guard let id = notebooks.createNotebook(title: title, course: course, coverColor: color) else { throw AppAutomationError.failed(notebooks.storageError ?? "笔记本未创建") }
            requestedNotebookID = id; requestedPageID = notebooks.currentPage?.id; destination = "notebooks"; navigationRevision += 1; result["notebook_id"] = id.uuidString
        case .renameNotebook:
            let book = try Self.book(args, notebooks); notebooks.renameNotebook(book.id, title: try Self.string(args, "title", maximum: 160)); result["notebook_id"] = book.id.uuidString
        case .deleteNotebook:
            let book = try Self.book(args, notebooks); notebooks.deleteNotebook(book.id)
            guard notebooks.notebook(id: book.id) == nil else { throw AppAutomationError.failed(notebooks.storageError ?? "笔记本未删除") }
        case .selectNotebook:
            let book = try Self.book(args, notebooks); notebooks.selectNotebook(book.id)
            requestedNotebookID = book.id; requestedPageID = notebooks.currentPage?.id; destination = "notebooks"
            navigationRevision += 1
        case .reorderNotebooks:
            let ids = try Self.uuids(args, "ids", maximum: 500)
            guard Set(ids) == Set(notebooks.notebooks.map(\.id)) else { throw AppAutomationError.invalid("ids 必须完整列出每本笔记本且不重复") }
            notebooks.beginUndoGroup(); defer { notebooks.endUndoGroup() }
            for (target, id) in ids.enumerated() {
                guard let from = notebooks.notebooks.firstIndex(where: { $0.id == id }) else { throw NoteStorageError.missingNotebook }
                if from != target { notebooks.reorderNotebooks(fromOffsets: IndexSet(integer: from), toOffset: from < target ? target + 1 : target) }
            }
        case .createPage:
            let book = try Self.book(args, notebooks)
            guard book.pages.count < 1000 else { throw AppAutomationError.invalid("每本最多1000页") }
            let after = try Self.optionalUUID(args, "after_page_id")
            if let after, !book.pages.contains(where: { $0.id == after }) { throw NoteStorageError.missingPage }
            let title = try Self.optionalString(args, "title", maximum: 160) ?? ""
            let paper = try Self.paper(args, fallback: .ruled)
            guard let change = notebooks.apply(.createPage(notebookID: book.id, afterPageID: after, title: title, paper: paper)), let id = change.pageID else { throw AppAutomationError.failed(notebooks.storageError ?? "页面未创建") }
            requestedNotebookID = book.id; requestedPageID = id; destination = "notebooks"; navigationRevision += 1; result["page_id"] = id.uuidString
        case .renamePage:
            let page = try Self.page(args, notebooks); notebooks.renamePage(page.id, title: try Self.string(args, "title", maximum: 160))
        case .deletePage:
            let page = try Self.page(args, notebooks); notebooks.deletePage(page.id)
            guard notebooks.page(id: page.id) == nil else { throw AppAutomationError.failed(notebooks.storageError ?? "页面未删除") }
            requestedPageID = notebooks.currentPage?.id
        case .selectPage:
            try show(page: Self.page(args, notebooks), notebooks: notebooks)
        case .reorderPages:
            let book = try Self.book(args, notebooks), ids = try Self.uuids(args, "ids", maximum: 1000)
            guard Set(ids) == Set(book.pages.map(\.id)) else { throw AppAutomationError.invalid("ids 必须完整列出这本笔记本的页面且不重复") }
            notebooks.beginUndoGroup(); defer { notebooks.endUndoGroup() }
            for (target, id) in ids.enumerated() {
                guard let from = notebooks.notebook(id: book.id)?.pages.firstIndex(where: { $0.id == id }) else { throw NoteStorageError.missingPage }
                if from != target { notebooks.reorderPages(notebookID: book.id, fromOffsets: IndexSet(integer: from), toOffset: from < target ? target + 1 : target) }
            }
        case .setPaper:
            let page = try Self.page(args, notebooks); notebooks.setPaper(try Self.paper(args), pageID: page.id)
        case .addText:
            let page = try Self.page(args, notebooks), frame = try Self.rect(args["frame"], page: page)
            guard page.objects.count < 2000 else { throw AppAutomationError.invalid("页面内容数量已达到上限") }
            operationRegion = frame; try show(page: page, notebooks: notebooks)
            guard let id = notebooks.addText(try Self.string(args, "text", maximum: 8000), to: page.id, at: frame) else { throw AppAutomationError.failed(notebooks.storageError ?? "注释未添加") }
            result["object_id"] = id.uuidString
        case .updateText:
            let page = try Self.page(args, notebooks), object = try Self.noteObject(args, page)
            guard object.text != nil else { throw AppAutomationError.invalid("目标不是文字对象") }
            operationRegion = object.frame; try show(page: page, notebooks: notebooks)
            notebooks.updateText(try Self.string(args, "text", maximum: 8000), pageID: page.id, objectID: object.id)
        case .setObjectFrame:
            let page = try Self.page(args, notebooks), object = try Self.noteObject(args, page), frame = try Self.rect(args["frame"], page: page)
            operationRegion = frame; try show(page: page, notebooks: notebooks)
            guard notebooks.updateObjectFrame(frame, pageID: page.id, objectID: object.id) else { throw AppAutomationError.failed(notebooks.storageError ?? "位置未修改") }
        case .deleteObject:
            let page = try Self.page(args, notebooks), object = try Self.noteObject(args, page)
            operationRegion = object.frame; try show(page: page, notebooks: notebooks); notebooks.removeObject(pageID: page.id, objectID: object.id)
            guard notebooks.object(id: object.id, pageID: page.id) == nil else { throw AppAutomationError.failed(notebooks.storageError ?? "内容未删除") }
        case .addImage:
            let page = try Self.page(args, notebooks), data = try Self.imageData(args)
            guard page.objects.count < 2000 else { throw AppAutomationError.invalid("页面内容数量已达到上限") }
            let frame = try Self.optionalRect(args["frame"], page: page)
            operationRegion = frame; try show(page: page, notebooks: notebooks)
            guard let id = notebooks.addImage(data: data, name: try Self.string(args, "name", maximum: 160), to: page.id, at: frame) else { throw AppAutomationError.failed(notebooks.storageError ?? "图片未添加") }
            operationRegion = notebooks.object(id: id, pageID: page.id)?.frame; result["object_id"] = id.uuidString
        case .drawStroke:
            let page = try Self.page(args, notebooks), width = try Self.number(args, "width", range: 1...60)
            let color = Self.uiColor(try Self.colorHex(args, "color", fallback: "#D97757"))
            let inkType = try Self.optionalString(args, "ink", maximum: 20) ?? "pen"
            guard ["pen", "marker"].contains(inkType) else { throw AppAutomationError.invalid("ink 只支持pen或marker") }
            guard let raw = args["points"] as? [[String: Any]], (2...2048).contains(raw.count) else { throw AppAutomationError.invalid("points 需要2至2048个坐标") }
            let samples = try raw.enumerated().map { index, point -> PKStrokePoint in
                try Self.keys(point, allowed: ["x", "y", "pressure"])
                let x = try Self.number(point, "x", range: 0...page.width), y = try Self.number(point, "y", range: 0...page.height)
                let pressure = try Self.optionalNumber(point, "pressure", range: 0.1...1) ?? 1
                return PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(index) / 60, size: CGSize(width: width, height: width), opacity: inkType == "marker" ? 0.4 : 1, force: pressure, azimuth: 0, altitude: .pi / 2)
            }
            let stroke = PKStroke(ink: PKInk(inkType == "marker" ? .marker : .pen, color: color), path: PKStrokePath(controlPoints: samples, creationDate: Date()))
            operationRegion = Self.visibleRegion(stroke.renderBounds, page: page)
            try show(page: page, notebooks: notebooks)
            var drawing = try notebooks.drawingChecked(for: page.id)
            guard drawing.strokes.count < 20_000 else { throw AppAutomationError.invalid("页面笔迹数量已达到上限") }
            drawing.strokes.append(stroke)
            guard notebooks.updateDrawing(drawing, pageID: page.id) else { throw AppAutomationError.failed(notebooks.storageError ?? "笔迹未保存") }
            result["stroke_index"] = drawing.strokes.count - 1
        case .eraseStrokes, .moveStrokes:
            let page = try Self.page(args, notebooks)
            var drawing = try notebooks.drawingChecked(for: page.id)
            let indices = try Self.indices(args, count: drawing.strokes.count)
            try show(page: page, notebooks: notebooks)
            var region = CGRect.null
            for index in indices { region = region.union(drawing.strokes[index].renderBounds) }
            operationRegion = Self.visibleRegion(region, page: page)
            if action == .eraseStrokes { drawing.strokes = drawing.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element) }
            else {
                let dx = try Self.number(args, "dx", range: -page.width...page.width), dy = try Self.number(args, "dy", range: -page.height...page.height)
                for index in indices {
                    let moved = drawing.strokes[index].renderBounds.offsetBy(dx: dx, dy: dy)
                    guard CGRect(origin: .zero, size: page.size).insetBy(dx: -2, dy: -2).contains(moved) else { throw AppAutomationError.invalid("移动后的笔迹会超出纸张") }
                    drawing.strokes[index].transform = drawing.strokes[index].transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
                }
            }
            guard notebooks.updateDrawing(drawing, pageID: page.id) else { throw AppAutomationError.failed(notebooks.storageError ?? "笔迹未修改") }
            result["stroke_count"] = drawing.strokes.count
        case .undo, .redo:
            guard (action == .undo ? notebooks.canUndo : notebooks.canRedo) else { throw AppAutomationError.unavailable(action == .undo ? "没有可撤销的操作。" : "没有可重做的操作。") }
            if action == .undo { notebooks.undo() } else { notebooks.redo() }
            requestedNotebookID = notebooks.currentNotebook?.id; requestedPageID = notebooks.currentPage?.id; destination = "notebooks"
            navigationRevision += 1
        case .setTool:
            let page = try Self.page(args, notebooks)
            guard let tool = NotebookDrawingTool(rawValue: try Self.string(args, "tool", maximum: 20)) else { throw AppAutomationError.invalid("tool") }
            let widthRange: ClosedRange<Double> = tool == .pen ? 1...20 : tool == .highlighter ? 8...60 : tool == .lasso ? 1...80 : 8...80
            let width = try Self.number(args, "width", range: widthRange), hex = try Self.colorHex(args, "color", fallback: "#292724")
            let finger = try Self.optionalBool(args, "allows_finger_drawing")
            try show(page: page, notebooks: notebooks)
            result.merge(try await canvas(NotebookCanvasCommand(pageID: page.id, action: .tool(tool, Self.uiColor(hex), width, finger)), session: session)) { _, new in new }
            var userInfo: [AnyHashable: Any] = ["pageID": page.id, "tool": tool.rawValue, "colorHex": hex, "width": width]
            if let finger { userInfo["allowsFingerDrawing"] = finger }
            NotificationCenter.default.post(name: .notebookToolCommand, object: nil, userInfo: userInfo)
        case .scrollViewport, .zoomViewport:
            let page = try Self.page(args, notebooks); try show(page: page, notebooks: notebooks)
            let x = try Self.optionalNumber(args, "x", range: 0...page.width), y = try Self.optionalNumber(args, "y", range: 0...page.height)
            let dx = try Self.optionalNumber(args, "dx", range: -page.width...page.width), dy = try Self.optionalNumber(args, "dy", range: -page.height...page.height)
            let zoom = try Self.optionalNumber(args, "zoom", range: 0.25...4)
            if action == .zoomViewport, zoom == nil { throw AppAutomationError.invalid("zoom 是必填项") }
            if action == .scrollViewport, x == nil && y == nil && dx == nil && dy == nil { throw AppAutomationError.invalid("需要x/y或dx/dy") }
            if (x != nil || y != nil) && (dx != nil || dy != nil) { throw AppAutomationError.invalid("绝对与相对滚动参数不能混用") }
            result.merge(try await canvas(NotebookCanvasCommand(pageID: page.id, action: .viewport(x: x.map { CGFloat($0) }, y: y.map { CGFloat($0) }, dx: dx.map { CGFloat($0) }, dy: dy.map { CGFloat($0) }, zoom: zoom.map { CGFloat($0) })), session: session)) { _, new in new }
        default:
            guard let learning else { throw AppAutomationError.unavailable("教题资料库未连接。") }
            result.merge(try await learningAction(action, args: args, store: learning, session: session)) { _, new in new }
        }
        try ensure(session)
        if let error = notebooks.storageError, action.isNotebookAction { throw AppAutomationError.failed(error) }
        if let pageID = requestedPageID, let region = operationRegion {
            let command = NotebookCanvasCommand(pageID: pageID, action: .region(region))
            // Navigation may create the native page on the next run-loop turn.
            // Document editing still works without a visible canvas; viewport
            // commands above require its acknowledgement and never fake success.
            for _ in 0..<4 {
                try ensure(session)
                NotificationCenter.default.post(name: .notebookCanvasCommand, object: command)
                if command.accepted { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        result["completed"] = true
        return try Self.text(result)
    }

    private func learningAction(_ action: AppAction, args: [String: Any], store: LearningStore, session: UUID) async throws -> [String: Any] {
        store.storageError = nil
        var result: [String: Any] = [:]
        switch action {
        case .addCourse:
            let course = try Self.string(args, "course", maximum: 120).trimmingCharacters(in: .whitespacesAndNewlines)
            guard store.state.courses.contains(course) || store.state.courses.count < 500 else { throw AppAutomationError.invalid("课程数量已达到上限") }
            store.addCourse(course); result["course"] = course
        case .deleteCourse:
            let course = try Self.course(args, store); store.deleteCourse(course)
        case .selectCourse:
            let course = try Self.course(args, store); store.state.selectedCourse = course; store.save()
        case .setCourseSubject, .setCourseNotes:
            let course = try Self.course(args, store), text = try Self.string(args, "text", maximum: 20_000, allowEmpty: true)
            if action == .setCourseSubject { store.state.subjects[course] = text } else { store.state.courseNotes[course] = text }; store.save()
        case .newChat:
            let course = try Self.optionalString(args, "course", maximum: 120) ?? store.state.selectedCourse
            guard course.isEmpty || store.state.courses.contains(course) else { throw AppAutomationError.invalid("课程不存在") }
            guard store.state.chats.count < 2000 else { throw AppAutomationError.invalid("对话数量已达到上限") }
            store.newChat(course: course); destination = "chat"; result["chat_id"] = store.current?.id.uuidString
        case .selectChat:
            store.select(try Self.chat(args, store)); destination = "chat"
        case .renameChat:
            store.renameChat(try Self.chat(args, store).id, to: try Self.string(args, "title", maximum: 80))
        case .deleteChat:
            store.delete(try Self.chat(args, store).id)
        case .clearChats:
            store.clearChats()
        case .setChatDraft:
            store.select(try Self.chat(args, store)); store.updateDraft(try Self.string(args, "text", maximum: 20_000, allowEmpty: true)); destination = "chat"
        case .sendMessage, .retryReply, .nextQuestion:
            let chat = try Self.chat(args, store)
            guard !store.pending.contains(chat.id), store.pending.count < 3 else { throw AppAutomationError.unavailable("这条对话仍在回复中。") }
            store.select(chat); destination = "chat"
            if action == .sendMessage {
                let text = try Self.string(args, "text", maximum: 20_000, allowEmpty: true)
                guard !text.isEmpty || !(chat.draftImages ?? []).isEmpty else { throw AppAutomationError.invalid("消息与图片不能同时为空") }
                guard !store.importing.contains(.chat(chat.id)) else { throw AppAutomationError.unavailable("请等待图片导入完成。") }
                await withTaskCancellationHandler { await store.send(text) } onCancel: { Task { @MainActor in store.stop() } }
            } else if action == .retryReply {
                guard !chat.messages.isEmpty else { throw AppAutomationError.invalid("空对话不能重试") }
                await withTaskCancellationHandler { await store.retry() } onCancel: { Task { @MainActor in store.stop() } }
            } else {
                guard store.canNext else { throw AppAutomationError.unavailable("没有下一题。") }
                await withTaskCancellationHandler { await store.nextQuestion() } onCancel: { Task { @MainActor in store.stop() } }
            }
            try ensure(session)
            if let failure = store.state.chats.first(where: { $0.id == chat.id })?.failure { throw AppAutomationError.failed(failure) }
            result["chat_id"] = chat.id.uuidString
        case .stopReply:
            store.select(try Self.chat(args, store)); store.stop()
        case .skipPacing:
            store.skipPacing()
        case .setReview:
            let chat = try Self.chat(args, store), draft = try Self.optionalString(args, "draft", maximum: 20_000, allowEmpty: true), reviewStatus = try Self.optionalString(args, "status", maximum: 120, allowEmpty: true)
            guard draft != nil || reviewStatus != nil else { throw AppAutomationError.invalid("需要draft或status") }
            if let reviewStatus, !["", "queued", "again", "know"].contains(reviewStatus) { throw AppAutomationError.invalid("status只支持queued/again/know或空值") }
            store.setReview(chat.id, draft: draft, status: reviewStatus); destination = "review"
        case .addCourseFile:
            let course = try Self.course(args, store), name = try Self.string(args, "name", maximum: 160)
            guard store.state.files.count < 5000 else { throw AppAutomationError.invalid("资料数量已达到上限") }
            let file = CourseFile(name: name, course: course); store.state.files.append(file); store.save(); destination = "files"
            result["file_id"] = file.id.uuidString; result["kind"] = "metadata_only"
        case .importLearningImage:
            let data = try Self.imageData(args), name = try Self.string(args, "name", maximum: 160)
            let target = try Self.string(args, "destination", maximum: 10)
            let attachment: AttachmentDestination
            if target == "chat" {
                let chat = try Self.chat(args, store)
                guard (chat.draftImages ?? []).count < 4 else { throw ImageImportError.limit }
                attachment = .chat(chat.id)
            } else if target == "course" {
                guard store.state.files.count < 5000 else { throw AppAutomationError.invalid("资料数量已达到上限") }
                attachment = .course(try Self.course(args, store))
            }
            else { throw AppAutomationError.invalid("destination 只能是chat或course") }
            let image = try store.images.importData(data, name: name)
            try store.keepImage(image, at: attachment); result["image_id"] = image.id.uuidString
        case .removeDraftImage:
            let chat = try Self.chat(args, store), id = try Self.uuid(args, "image_id")
            guard let image = chat.draftImages?.first(where: { $0.id == id }) else { throw AppAutomationError.invalid("草稿图片不存在") }
            store.select(chat); store.removeDraftImage(image)
        case .removeFile:
            store.removeFile(try Self.file(args, store).id)
        case .useFileImage:
            let file = try Self.file(args, store)
            guard let image = file.image else { throw AppAutomationError.invalid("该资料没有可添加的图片") }
            if let chat = store.state.chats.first(where: { $0.course == file.course }), !(chat.draftImages ?? []).contains(where: { $0.id == image.id }), (chat.draftImages ?? []).count >= 4 { throw ImageImportError.limit }
            store.useFileImage(file)
            guard store.current?.draftImages?.contains(where: { $0.id == image.id }) == true else { throw AppAutomationError.failed(store.notice ?? "图片未添加到草稿") }
            destination = "chat"
        default: throw AppAutomationError.invalid("不支持的资料操作")
        }
        if let error = store.storageError { throw AppAutomationError.failed(error) }
        return result
    }

    private func readState(_ args: [String: Any], notebooks: NotebookStore, learning: LearningStore?) throws -> [[String: Any]] {
        try Self.keys(args, allowed: ["scope", "chat_id", "course", "offset", "limit", "file_id", "image_id"])
        let scope = try Self.optionalString(args, "scope", maximum: 20) ?? "overview"
        status = "正在查看软件中的资料"
        if scope == "overview" { return try Self.text(["destination": destination, "notebook_count": notebooks.notebooks.count, "selected_notebook_id": notebooks.currentNotebook?.id.uuidString ?? "", "selected_page_id": notebooks.currentPage?.id.uuidString ?? "", "course_count": learning?.state.courses.count ?? 0, "chat_count": learning?.state.chats.count ?? 0, "file_count": learning?.state.files.count ?? 0, "actions": AppAction.allCases.map(\.rawValue)]) }
        guard let learning else { throw AppAutomationError.unavailable("教题资料库未连接。") }
        switch scope {
        case "courses":
            return try Self.text(["courses": learning.state.courses, "selected_course": learning.state.selectedCourse, "subjects": learning.state.subjects, "notes": learning.state.courseNotes])
        case "chats", "reviews":
            var chats = learning.state.chats
            if scope == "reviews" { chats = chats.filter { chat in chat.messages.contains { $0.text == Example.question } && ["queued", "again"].contains(chat.reviewStatus ?? "") } }
            if let course = try Self.optionalString(args, "course", maximum: 120) { chats = chats.filter { $0.course == course } }
            let range = try Self.range(args, count: chats.count)
            let values = chats[range].map { ["id": $0.id.uuidString, "title": $0.title, "course": $0.course, "message_count": $0.messages.count, "review_status": $0.reviewStatus ?? "", "reply_in_progress": $0.replyInProgress] as [String: Any] }
            return try Self.text(["chats": values, "total": chats.count, "next_offset": range.upperBound])
        case "chat", "review":
            let chat = try Self.chat(args, learning), range = try Self.range(args, count: chat.messages.count, defaultLimit: 30, maximum: 50)
            let messages = chat.messages[range].map { ["id": $0.id.uuidString, "role": $0.role, "text": String($0.text.prefix(8000)), "image_ids": ($0.images ?? []).map { $0.id.uuidString }] as [String: Any] }
            return try Self.text(["id": chat.id.uuidString, "title": chat.title, "course": chat.course, "draft": String(chat.draft.prefix(20_000)), "draft_image_ids": (chat.draftImages ?? []).map { $0.id.uuidString }, "messages": messages, "message_count": chat.messages.count, "next_offset": range.upperBound, "review_draft": String(chat.reviewDraft.prefix(20_000)), "review_status": chat.reviewStatus ?? "", "failure": chat.failure ?? ""])
        case "records":
            let course = try Self.optionalString(args, "course", maximum: 120) ?? learning.state.selectedCourse
            let records = learning.record(for: course).map { [["chat_id": $0.id.uuidString, "title": $0.title, "course": $0.course, "questions": learning.questions(in: $0)]] as [[String: Any]] } ?? []
            return try Self.text(["records": records, "course": course, "kind": "existing_demo_record"])
        case "record":
            let chat = try Self.chat(args, learning)
            guard chat.messages.contains(where: { $0.role == "paper" && $0.text == Example.question }) else { throw AppAutomationError.invalid("当前软件没有这条对话的记录视图") }
            return try Self.text(["chat_id": chat.id.uuidString, "question": Example.question, "answer": Example.answer, "steps": Example.steps, "student_questions": learning.questions(in: chat), "kind": "existing_demo_record"])
        case "files":
            let range = try Self.range(args, count: learning.state.files.count)
            return try Self.text(["files": try learning.state.files[range].map { try Self.dictionary($0) }, "total": learning.state.files.count, "next_offset": range.upperBound])
        case "file":
            let file = try Self.file(args, learning)
            var content = try Self.text(Self.dictionary(file))
            if let image = file.image {
                let data = try Data(contentsOf: learning.images.url(for: image))
                guard data.count <= 8 * 1024 * 1024 else { throw AppAutomationError.failed("图片超出传输大小") }
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            return content
        case "chat_image":
            let chat = try Self.chat(args, learning), id = try Self.uuid(args, "image_id")
            let images = (chat.draftImages ?? []) + chat.messages.flatMap { $0.images ?? [] }
            guard let image = images.first(where: { $0.id == id }) else { throw AppAutomationError.invalid("这条对话中的图片不存在") }
            let data = try Data(contentsOf: learning.images.url(for: image))
            guard data.count <= 8 * 1024 * 1024 else { throw AppAutomationError.failed("图片超出传输大小") }
            return try Self.text(Self.dictionary(image)) + [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]]
        default: throw AppAutomationError.invalid("scope 不受支持")
        }
    }

    enum AppAction: String, CaseIterable {
        case navigate
        case createNotebook = "create_notebook", renameNotebook = "rename_notebook", deleteNotebook = "delete_notebook", selectNotebook = "select_notebook", reorderNotebooks = "reorder_notebooks"
        case createPage = "create_page", renamePage = "rename_page", deletePage = "delete_page", selectPage = "select_page", reorderPages = "reorder_pages"
        case setPaper = "set_paper", addText = "add_text", updateText = "update_text", setObjectFrame = "set_object_frame", deleteObject = "delete_object", addImage = "add_image"
        case drawStroke = "draw_stroke", eraseStrokes = "erase_strokes", moveStrokes = "move_strokes", setTool = "set_tool", scrollViewport = "scroll_viewport", zoomViewport = "zoom_viewport", undo, redo
        case addCourse = "add_course", deleteCourse = "delete_course", selectCourse = "select_course", setCourseSubject = "set_course_subject", setCourseNotes = "set_course_notes"
        case newChat = "new_chat", selectChat = "select_chat", renameChat = "rename_chat", deleteChat = "delete_chat", clearChats = "clear_chats", setChatDraft = "set_chat_draft", sendMessage = "send_message", retryReply = "retry_reply", stopReply = "stop_reply", nextQuestion = "next_question", skipPacing = "skip_pacing"
        case setReview = "set_review", addCourseFile = "add_course_file", importLearningImage = "import_learning_image", removeDraftImage = "remove_draft_image", removeFile = "remove_file", useFileImage = "use_file_image"

        var isNotebookAction: Bool { Self.allCases.firstIndex(of: self)! < Self.allCases.firstIndex(of: .addCourse)! }
        var status: String {
            switch self {
            case .drawStroke: return "正在标出关键位置"
            case .eraseStrokes: return "正在擦去选中的笔迹"
            case .moveStrokes: return "正在调整笔迹的位置"
            case .addImage, .setObjectFrame: return "正在整理题图"
            case .addText, .updateText: return "正在写下这一步的说明"
            case .selectPage, .createPage: return "正在翻到笔记页面"
            case .scrollViewport, .zoomViewport: return "正在调整纸张的位置"
            case .sendMessage, .retryReply, .nextQuestion: return "正在继续教题"
            case .deleteObject, .deletePage, .deleteNotebook: return "正在移除选中的内容"
            case .undo: return "正在撤销上一步"
            case .redo: return "正在恢复上一步"
            case .setReview: return "正在整理复习记录"
            default: return "正在调整软件中的内容"
            }
        }
        var allowedKeys: Set<String> {
            switch self {
            case .navigate: return ["destination"]
            case .createNotebook: return ["title", "course", "color"]
            case .renameNotebook: return ["notebook_id", "title"]
            case .deleteNotebook, .selectNotebook: return ["notebook_id"]
            case .reorderNotebooks: return ["ids"]
            case .createPage: return ["notebook_id", "after_page_id", "title", "paper"]
            case .renamePage: return ["page_id", "title"]
            case .deletePage, .selectPage: return ["page_id"]
            case .reorderPages: return ["notebook_id", "ids"]
            case .setPaper: return ["page_id", "paper"]
            case .addText: return ["page_id", "text", "frame"]
            case .updateText: return ["page_id", "object_id", "text"]
            case .setObjectFrame: return ["page_id", "object_id", "frame"]
            case .deleteObject: return ["page_id", "object_id"]
            case .addImage: return ["page_id", "name", "data_base64", "frame"]
            case .drawStroke: return ["page_id", "points", "color", "width", "ink"]
            case .eraseStrokes: return ["page_id", "indices"]
            case .moveStrokes: return ["page_id", "indices", "dx", "dy"]
            case .setTool: return ["page_id", "tool", "color", "width", "allows_finger_drawing"]
            case .scrollViewport: return ["page_id", "x", "y", "dx", "dy"]
            case .zoomViewport: return ["page_id", "zoom", "x", "y"]
            case .undo, .redo, .clearChats, .skipPacing: return []
            case .addCourse, .deleteCourse, .selectCourse: return ["course"]
            case .setCourseSubject, .setCourseNotes: return ["course", "text"]
            case .newChat: return ["course"]
            case .selectChat, .deleteChat, .retryReply, .stopReply, .nextQuestion: return ["chat_id"]
            case .renameChat: return ["chat_id", "title"]
            case .setChatDraft, .sendMessage: return ["chat_id", "text"]
            case .setReview: return ["chat_id", "draft", "status"]
            case .addCourseFile: return ["course", "name"]
            case .importLearningImage: return ["destination", "chat_id", "course", "name", "data_base64"]
            case .removeDraftImage: return ["chat_id", "image_id"]
            case .removeFile, .useFileImage: return ["file_id"]
            }
        }
    }

    // MARK: Strict, bounded input parsing
    static func keys(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw AppAutomationError.invalid("包含未支持的参数") }
    }
    static func object(_ value: Any?, key: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw AppAutomationError.invalid(key + "需要对象") }; return value
    }
    static func string(_ args: [String: Any], _ key: String, maximum: Int, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key] as? String, value.count <= maximum, (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { throw AppAutomationError.invalid(key + "需要有效文字（最多\(maximum)字）") }
        return value
    }
    static func optionalString(_ args: [String: Any], _ key: String, maximum: Int, allowEmpty: Bool = false) throws -> String? {
        guard args[key] != nil else { return nil }; return try string(args, key, maximum: maximum, allowEmpty: allowEmpty)
    }
    static func number(_ args: [String: Any], _ key: String, range: ClosedRange<Double>) throws -> Double {
        guard let value = args[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, range.contains(value.doubleValue) else { throw AppAutomationError.invalid(key + "超出有效范围") }; return value.doubleValue
    }
    static func optionalNumber(_ args: [String: Any], _ key: String, range: ClosedRange<Double>) throws -> Double? {
        guard args[key] != nil else { return nil }; return try number(args, key, range: range)
    }
    static func optionalBool(_ args: [String: Any], _ key: String) throws -> Bool? {
        guard let value = args[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw AppAutomationError.invalid(key + "需要布尔值") }; return number.boolValue
    }
    static func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try string(args, key, maximum: 36)) else { throw AppAutomationError.invalid(key + "需要UUID") }; return id
    }
    static func optionalUUID(_ args: [String: Any], _ key: String) throws -> UUID? { args[key] == nil ? nil : try uuid(args, key) }
    static func uuids(_ args: [String: Any], _ key: String, maximum: Int) throws -> [UUID] {
        guard let raw = args[key] as? [String], !raw.isEmpty, raw.count <= maximum else { throw AppAutomationError.invalid(key + "需要有界UUID列表") }
        let ids = try raw.map { value -> UUID in guard let id = UUID(uuidString: value) else { throw AppAutomationError.invalid(key + "含无效UUID") }; return id }
        guard Set(ids).count == ids.count else { throw AppAutomationError.invalid(key + "不能重复") }; return ids
    }
    static func range(_ args: [String: Any], count: Int, defaultLimit: Int = 50, maximum: Int = 100) throws -> Range<Int> {
        let offset = try optionalNumber(args, "offset", range: 0...Double(count)) ?? 0
        let limit = try optionalNumber(args, "limit", range: 1...Double(maximum)) ?? Double(defaultLimit)
        guard offset.rounded() == offset, limit.rounded() == limit else { throw AppAutomationError.invalid("分页参数需要整数") }
        return Int(offset)..<min(count, Int(offset) + Int(limit))
    }
    static func book(_ args: [String: Any], _ store: NotebookStore) throws -> NoteBookDocument {
        guard let value = store.notebook(id: try uuid(args, "notebook_id")) else { throw NoteStorageError.missingNotebook }; return value
    }
    static func page(_ args: [String: Any], _ store: NotebookStore) throws -> NotePage {
        guard let value = store.page(id: try uuid(args, "page_id")) else { throw NoteStorageError.missingPage }; return value
    }
    static func noteObject(_ args: [String: Any], _ page: NotePage) throws -> NoteObject {
        guard let value = page.objects.first(where: { $0.id == (try? uuid(args, "object_id")) }) else { throw NoteStorageError.missingObject }; return value
    }
    static func rect(_ value: Any?, page: NotePage) throws -> NoteRect {
        let args = try object(value, key: "frame"); try keys(args, allowed: ["x", "y", "width", "height"])
        let x = try number(args, "x", range: 0...page.width), y = try number(args, "y", range: 0...page.height)
        let width = try number(args, "width", range: 24...page.width), height = try number(args, "height", range: 24...page.height)
        guard x + width <= page.width, y + height <= page.height else { throw AppAutomationError.invalid("矩形超出纸张") }
        return NoteRect(x: x, y: y, width: width, height: height)
    }
    static func optionalRect(_ value: Any?, page: NotePage) throws -> NoteRect? { value == nil ? nil : try rect(value, page: page) }
    static func paper(_ args: [String: Any], fallback: NotePaper? = nil) throws -> NotePaper {
        if args["paper"] == nil, let fallback { return fallback }
        guard let value = NotePaper(rawValue: try string(args, "paper", maximum: 10)) else { throw AppAutomationError.invalid("paper") }; return value
    }
    static func colorHex(_ args: [String: Any], _ key: String, fallback: String) throws -> String {
        let hex = try optionalString(args, key, maximum: 7) ?? fallback
        guard hex.count == 7, hex.first == "#", UInt32(hex.dropFirst(), radix: 16) != nil else { throw AppAutomationError.invalid(key + "需要#RRGGBB颜色") }; return hex
    }
    static func uiColor(_ hex: String) -> UIColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func indices(_ args: [String: Any], count: Int) throws -> Set<Int> {
        guard let raw = args["indices"] as? [NSNumber], (1...512).contains(raw.count), count > 0 else { throw AppAutomationError.invalid("indices需要1至512个有效笔迹索引") }
        let values = try raw.map { number -> Int in
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue, (0..<Double(count)).contains(number.doubleValue) else { throw AppAutomationError.invalid("笔迹索引不存在") }; return number.intValue
        }
        guard Set(values).count == values.count else { throw AppAutomationError.invalid("笔迹索引不能重复") }; return Set(values)
    }
    static func imageData(_ args: [String: Any]) throws -> Data {
        let raw = try string(args, "data_base64", maximum: 12 * 1024 * 1024)
        guard let data = Data(base64Encoded: raw), !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw AppAutomationError.invalid("图片必须为8MB以内的base64数据") }; return data
    }
    static func course(_ args: [String: Any], _ store: LearningStore) throws -> String {
        let course = try string(args, "course", maximum: 120)
        guard store.state.courses.contains(course) else { throw AppAutomationError.invalid("课程不存在") }; return course
    }
    static func chat(_ args: [String: Any], _ store: LearningStore) throws -> LearningChat {
        let id = try uuid(args, "chat_id")
        guard let value = store.state.chats.first(where: { $0.id == id }) else { throw AppAutomationError.invalid("对话不存在") }; return value
    }
    static func file(_ args: [String: Any], _ store: LearningStore) throws -> CourseFile {
        let id = try uuid(args, "file_id")
        guard let value = store.state.files.first(where: { $0.id == id }) else { throw AppAutomationError.invalid("资料不存在") }; return value
    }
    static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw AppAutomationError.failed("资料无法序列化") }; return result
    }
    static func text(_ value: Any) throws -> [[String: Any]] {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 2 * 1024 * 1024 else { throw AppAutomationError.failed("返回资料过多，请缩小读取范围") }
        return [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
    }
    static func visibleRegion(_ rect: CGRect, page: NotePage) -> NoteRect? {
        let region = rect.intersection(CGRect(origin: .zero, size: page.size))
        return region.isNull || region.isEmpty || region.isInfinite ? nil : NoteRect(region)
    }
    static func rectDictionary(_ rect: CGRect) -> [String: Double] {
        if rect.isNull || rect.isInfinite { return ["x": 0, "y": 0, "width": 0, "height": 0] }
        return ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }

    static var tools: [[String: Any]] {
        let string: [String: Any] = ["type": "string"]
        let integer: [String: Any] = ["type": "integer", "minimum": 0]
        let rect: [String: Any] = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number", "minimum": 24], "height": ["type": "number", "minimum": 24]], "required": ["x", "y", "width", "height"], "additionalProperties": false]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        let actionSchemas = AppAction.allCases.map { action -> [String: Any] in
            var properties: [String: Any] = [:]
            for key in action.allowedKeys {
                if key == "frame" { properties[key] = rect }
                else if ["x", "y", "dx", "dy", "zoom", "width"].contains(key) { properties[key] = ["type": "number"] }
                else if key == "allows_finger_drawing" { properties[key] = ["type": "boolean"] }
                else if key == "ids" { properties[key] = ["type": "array", "items": string, "maxItems": 1000] }
                else if key == "indices" { properties[key] = ["type": "array", "items": integer, "minItems": 1, "maxItems": 512] }
                else if key == "points" { properties[key] = ["type": "array", "minItems": 2, "maxItems": 2048, "items": ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"], "pressure": ["type": "number", "minimum": 0.1, "maximum": 1]], "required": ["x", "y"], "additionalProperties": false]] }
                else { properties[key] = string }
            }
            let optional: Set<String> = ["course", "color", "after_page_id", "title", "paper", "frame", "ink", "allows_finger_drawing", "x", "y", "dx", "dy", "draft", "status"]
            var required = action.allowedKeys.subtracting(optional)
            if action == .importLearningImage { required.remove("chat_id"); required.remove("course") }
            if [.createNotebook, .renameNotebook, .renamePage, .renameChat].contains(action) { required.insert("title") }
            if [.addCourse, .deleteCourse, .selectCourse, .setCourseSubject, .setCourseNotes, .addCourseFile].contains(action) { required.insert("course") }
            if [.addText, .setObjectFrame].contains(action) { required.insert("frame") }
            if action == .setPaper { required.insert("paper") }
            return ["type": "object", "properties": ["action": ["type": "string", "const": action.rawValue], "parameters": ["type": "object", "properties": properties, "required": required.sorted(), "additionalProperties": false]], "required": ["action", "parameters"], "additionalProperties": false]
        }
        return [
            tool("read_app_state", "读取软件中的课程、教题对话、记录、资料与复习状态；chat_image/file含真实图片，不包含任何密钥。", ["scope": ["type": "string", "enum": ["overview", "courses", "chats", "chat", "chat_image", "records", "record", "files", "file", "reviews", "review"]], "chat_id": string, "file_id": string, "image_id": string, "course": string, "offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 100]]),
            tool("list_notebooks", "分页列出本机笔记本。", ["offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 100]]),
            tool("list_pages", "分页列出指定笔记本的页面与真实页面ID。", ["notebook_id": string, "offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 100]], ["notebook_id"]),
            tool("read_page", "读取真实纸张截图（包含图片和笔迹）以及对象与墨水结构；region可限制选区，坐标为纸张原始点。", ["page_id": string, "region": rect], ["page_id"]),
            tool("read_ink", "分页读取原生笔迹索引和采样坐标，可供移动/擦除。", ["page_id": string, "offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 32]], ["page_id"]),
            tool("search_notes", "每批本机OCR识别最多12页笔记，按关键词检索；offset分页，识别可能不完整。", ["notebook_id": string, "query": string, "offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 12]], ["notebook_id", "query"]),
            ["name": "perform_app_action", "description": "操作真实软件：笔记本/页面/内容/原生笔迹/视口/导航，以及课程、教题、资料与复习。需要操作会话；动作会立即执行且用户可停止。draw_stroke的points可画圈、下划线或箭头。add_course_file仅添加资料目录记录，导入实际图片使用import_learning_image。", "inputSchema": ["type": "object", "oneOf": actionSchemas]]
        ]
    }
}
