import UIKit
import ImageIO

struct ImageRepository {
    let folder: URL
    func url(for image: LearningImage) -> URL { folder.appendingPathComponent(image.id.uuidString + ".jpg") }

    func importFile(_ url: URL) throws -> LearningImage {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<LearningImage, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let size = try readable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20 * 1024 * 1024 else { throw ImageImportError.tooLarge }
                return try importData(Data(contentsOf: readable), name: url.lastPathComponent)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImageImportError.unreadable }
        return try result.get()
    }

    func importData(_ data: Data, name: String) throws -> LearningImage {
        guard data.count <= 20 * 1024 * 1024 else { throw ImageImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageImportError.unreadable }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: CGFloat(pixels.width), height: CGFloat(pixels.height))
        let flattened = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: pixels).draw(in: CGRect(origin: .zero, size: size))
        }
        var encoded: Data?
        for quality in [0.94, 0.86, 0.76, 0.65] {
            if let candidate = flattened.jpegData(compressionQuality: CGFloat(quality)), candidate.count <= 2 * 1024 * 1024 { encoded = candidate; break }
        }
        guard let encoded else { throw ImageImportError.tooLarge }
        let image = LearningImage(name: name, width: pixels.width, height: pixels.height, size: encoded.count)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoded.write(to: url(for: image), options: [.atomic, .completeFileProtection])
        return image
    }

    func encoded(_ image: LearningImage) throws -> String {
        guard let data = try? Data(contentsOf: url(for: image)) else { throw ImageImportError.missing }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    func thumbnail(_ image: LearningImage, maxSize: Int = 600) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url(for: image) as CFURL, nil),
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: pixels)
    }

    func remove(_ image: LearningImage) { try? FileManager.default.removeItem(at: url(for: image)) }
    func removeUnreferenced(in state: LearningState) {
        let keep = Set((state.files.compactMap(\.image) + state.chats.flatMap { ($0.draftImages ?? []) + $0.messages.flatMap { $0.images ?? [] } }).map { $0.id.uuidString + ".jpg" })
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "jpg" && !keep.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }
}

enum ImageImportError: LocalizedError {
    case unreadable, tooLarge, missing, limit
    var errorDescription: String? {
        switch self {
        case .unreadable: return "这张图片无法读取，请换一张或重新下载后添加。"
        case .tooLarge: return "图片太大，请缩小后添加。"
        case .missing: return "这张图片已丢失，请重新添加。"
        case .limit: return "一次最多添加 4 张图片。"
        }
    }
}
