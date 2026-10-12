import Foundation
import CoreGraphics

enum NotePaper: String, CaseIterable, Codable, Identifiable {
    case blank, ruled, grid, dotted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blank: return "空白"
        case .ruled: return "横线"
        case .grid: return "方格"
        case .dotted: return "点阵"
        }
    }
}

/// All object coordinates are in unzoomed page points, independent of the viewport.
struct NoteRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isFinite: Bool { [x, y, width, height].allSatisfy(\.isFinite) }
    func clamped(pageWidth: Double, pageHeight: Double) throws -> NoteRect {
        guard isFinite, pageWidth.isFinite, pageHeight.isFinite, width > 0, height > 0 else {
            throw NoteStorageError.invalidGeometry
        }
        let w = min(max(24, width), pageWidth)
        let h = min(max(24, height), pageHeight)
        return NoteRect(x: min(max(0, x), pageWidth - w), y: min(max(0, y), pageHeight - h), width: w, height: h)
    }
}

struct NoteText: Codable, Equatable {
    var text: String
    var fontSize: Double = 24
    var colorHex: String = "#24262B"
}

struct NoteImageAsset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var width: Int
    var height: Int
    var fileName: String
}

enum NoteObjectContent: Codable, Equatable {
    case text(NoteText)
    case image(NoteImageAsset)
}

struct NoteObject: Identifiable, Codable, Equatable {
    var id = UUID()
    var frame: NoteRect
    var content: NoteObjectContent
    var rotation: Double? = nil
    var angle: Double { rotation ?? 0 }
    var rotatedBounds: CGRect {
        let r = frame.cgRect
        let w = CGFloat(abs(cos(angle))) * r.width + CGFloat(abs(sin(angle))) * r.height
        let h = CGFloat(abs(sin(angle))) * r.width + CGFloat(abs(cos(angle))) * r.height
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
    static func bounded(_ frame: NoteRect, rotation: Double, pageWidth: Double, pageHeight: Double) throws -> NoteRect {
        guard rotation.isFinite else { throw NoteStorageError.invalidGeometry }
        let r = try frame.clamped(pageWidth: pageWidth, pageHeight: pageHeight)
        let w = abs(cos(rotation)) * r.width + abs(sin(rotation)) * r.height
        let h = abs(sin(rotation)) * r.width + abs(cos(rotation)) * r.height
        let scale = min(1, min(pageWidth / max(1, w), pageHeight / max(1, h)))
        let marginX = max(w, r.width) * scale / 2
        let cx = min(max(marginX, r.x + r.width / 2), pageWidth - marginX)
        let marginY = max(h, r.height) * scale / 2
        let cy = min(max(marginY, r.y + r.height / 2), pageHeight - marginY)
        return NoteRect(x: cx - r.width * scale / 2, y: cy - r.height * scale / 2, width: r.width * scale, height: r.height * scale)
    }
    var text: String? { if case .text(let value) = content { return value.text }; return nil }
    var image: NoteImageAsset? { if case .image(let asset) = content { return asset }; return nil }
}

struct NotePage: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "第 1 页"
    var paper: NotePaper = .ruled
    var width: Double = 768
    var height: Double = 1086
    /// Immutable native PencilKit asset. Images and typed annotations stay independent.
    var drawingAsset: String?
    var drawingChecksum: String?
    var objects: [NoteObject] = []
    var createdAt = Date()
    var updatedAt = Date()
    var size: CGSize { CGSize(width: width, height: height) }
}

struct NoteBookDocument: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "新笔记本"
    var course = ""
    var coverColor = "#496357"
    var pages: [NotePage] = [NotePage()]
    var createdAt = Date()
    var updatedAt = Date()
}

struct NoteLibrary: Codable, Equatable {
    var schemaVersion = 1
    var notebooks: [NoteBookDocument] = []
    var selectedNotebookID: UUID?
    var selectedPageID: UUID?
}

/// This is metadata for a tool read. OCR and a rendered page can be supplied by the caller.
struct NoteReadContext: Codable, Equatable {
    var notebookID: UUID
    var notebookTitle: String
    var course: String
    var pageID: UUID
    var pageTitle: String
    var paper: NotePaper
    var width: Double
    var height: Double
    var objects: [NoteObject]
    var hasDrawing: Bool
    var drawingBounds: NoteRect?
}

/// A model can propose these actions; the UI controls when they are applied.
enum NoteAction: Equatable {
    case createPage(notebookID: UUID, afterPageID: UUID?, title: String, paper: NotePaper)
    case renamePage(pageID: UUID, title: String)
    case renameNotebook(notebookID: UUID, title: String)
    case setPaper(pageID: UUID, paper: NotePaper)
    case addText(pageID: UUID, text: String, frame: NoteRect)
    case updateText(pageID: UUID, objectID: UUID, text: String)
    case setObjectFrame(pageID: UUID, objectID: UUID, frame: NoteRect)
    case setObjectTransform(pageID: UUID, objectID: UUID, frame: NoteRect, rotation: Double)
    case deleteObject(pageID: UUID, objectID: UUID)
}

struct NoteActionResult: Equatable {
    var notebookID: UUID
    var pageID: UUID?
    var objectID: UUID?
}

enum NoteStorageError: LocalizedError {
    case unreadableLibrary, unsupportedVersion, invalidGeometry, invalidAsset, missingPage, missingNotebook, missingObject, emptyTitle, imageTooLarge, unreadableImage, readOnly
    var errorDescription: String? {
        switch self {
        case .unreadableLibrary: return "笔记本数据无法读取，原文件已保留。请重试，或备份原文件后新建笔记库。"
        case .unsupportedVersion: return "这份笔记库来自更新的版本，请升级应用后再打开。"
        case .invalidGeometry: return "内容的位置或尺寸无效。"
        case .invalidAsset: return "笔记中的附件无法读取，原文件已保留。"
        case .missingPage: return "这页笔记已不存在。"
        case .missingNotebook: return "这本笔记本已不存在。"
        case .missingObject: return "这项内容已不存在。"
        case .emptyTitle: return "名称不能为空。"
        case .imageTooLarge: return "图片太大，请缩小后再添加。"
        case .unreadableImage: return "这张图片无法读取，请换一张。"
        case .readOnly: return "笔记库暂时处于保护状态，请先重试读取或备份恢复。"
        }
    }
}
