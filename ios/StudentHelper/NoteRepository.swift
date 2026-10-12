import Foundation
import PencilKit
import UIKit
import ImageIO
import CryptoKit

/// A single atomic index is the commit point. Every referenced asset is immutable:
/// a failed commit leaves the previous index and all of its assets usable.
struct NoteRepository {
    let folder: URL
    var indexURL: URL { folder.appendingPathComponent("library.json") }
    var drawingsFolder: URL { folder.appendingPathComponent("drawings", isDirectory: true) }
    var imagesFolder: URL { folder.appendingPathComponent("images", isDirectory: true) }

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notebooks", isDirectory: true)
    }

    func load() throws -> NoteLibrary {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return NoteLibrary() }
        do {
            let state = try JSONDecoder().decode(NoteLibrary.self, from: Data(contentsOf: indexURL))
            try validate(state)
            return state
        } catch let error as NoteStorageError { throw error }
        catch { throw NoteStorageError.unreadableLibrary }
    }

    func save(_ library: NoteLibrary) throws {
        try validate(library)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(library).write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    func saveDrawing(_ drawing: PKDrawing, pageID: UUID) throws -> String {
        let fileName = pageID.uuidString + "-" + UUID().uuidString + ".pkdraw"
        try FileManager.default.createDirectory(at: drawingsFolder, withIntermediateDirectories: true)
        try drawing.dataRepresentation().write(to: drawingsFolder.appendingPathComponent(fileName), options: [.atomic, .completeFileProtection])
        return fileName
    }

    func drawing(for page: NotePage) throws -> PKDrawing {
        guard let name = page.drawingAsset else { return PKDrawing() }
        guard safeAssetName(name, extension: "pkdraw") else { throw NoteStorageError.invalidAsset }
        do {
            let data = try Data(contentsOf: drawingsFolder.appendingPathComponent(name))
            if let checksum = page.drawingChecksum, Self.checksum(data) != checksum { throw NoteStorageError.invalidAsset }
            guard data.count >= PKDrawing().dataRepresentation().count else { throw NoteStorageError.invalidAsset }
            return try PKDrawing(data: data)
        }
        catch { throw NoteStorageError.invalidAsset }
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func importImage(_ data: Data, name: String) throws -> NoteImageAsset {
        guard data.count <= 20 * 1024 * 1024 else { throw NoteStorageError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560
              ] as CFDictionary), let encoded = UIImage(cgImage: pixels).pngData() else {
            throw NoteStorageError.unreadableImage
        }
        // PNG preserves transparency. It is never composited into PencilKit's ink.
        let id = UUID(), fileName = id.uuidString + ".png"
        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        try encoded.write(to: imagesFolder.appendingPathComponent(fileName), options: [.atomic, .completeFileProtection])
        return NoteImageAsset(id: id, name: name, width: pixels.width, height: pixels.height, fileName: fileName)
    }

    func imageData(for asset: NoteImageAsset) throws -> Data {
        guard safeAssetName(asset.fileName, extension: "png") else { throw NoteStorageError.invalidAsset }
        return try Data(contentsOf: imagesFolder.appendingPathComponent(asset.fileName))
    }

    /// Recovery is explicit and keeps the unreadable index before replacing it.
    @discardableResult func backupIndex() throws -> URL? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let backup = folder.appendingPathComponent("library-recovery-" + UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: indexURL, to: backup)
        return backup
    }

    /// Run only with the current index and every in-memory undo/redo snapshot.
    /// This is optional maintenance; it never deletes an asset referenced by history.
    func removeUnreferenced(keeping libraries: [NoteLibrary]) {
        // An unreadable backup may still refer to assets we cannot discover.
        // Preserve every asset until that backup is exported or repaired.
        let topLevel = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard !topLevel.contains(where: { $0.lastPathComponent.hasPrefix("library-recovery-") }) else { return }
        let pages = libraries.flatMap { $0.notebooks.flatMap(\.pages) }
        let drawings = Set(pages.compactMap(\.drawingAsset))
        let images = Set(pages.flatMap { $0.objects.compactMap { $0.image?.fileName } })
        for (directory, keep, ext) in [(drawingsFolder, drawings, "pkdraw"), (imagesFolder, images, "png")] {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == ext && !keep.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func safeAssetName(_ name: String, extension ext: String) -> Bool {
        !name.isEmpty && name == (name as NSString).lastPathComponent && !name.contains("\\")
            && !name.contains("..") && (name as NSString).pathExtension == ext
    }

    func validate(_ library: NoteLibrary) throws {
        guard library.schemaVersion == 1 else { throw NoteStorageError.unsupportedVersion }
        var notebookIDs = Set<UUID>(), pageIDs = Set<UUID>(), objectIDs = Set<UUID>()
        for notebook in library.notebooks {
            guard notebookIDs.insert(notebook.id).inserted, !notebook.pages.isEmpty,
                  !notebook.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NoteStorageError.unreadableLibrary
            }
            for page in notebook.pages {
                guard pageIDs.insert(page.id).inserted, page.width.isFinite, page.height.isFinite,
                      (64...4096).contains(page.width), (64...4096).contains(page.height) else {
                    throw NoteStorageError.invalidGeometry
                }
                if let drawing = page.drawingAsset, !safeAssetName(drawing, extension: "pkdraw") {
                    throw NoteStorageError.invalidAsset
                }
                for object in page.objects {
                    guard objectIDs.insert(object.id).inserted, object.frame.isFinite, object.angle.isFinite,
                          object.frame.width > 0, object.frame.height > 0,
                          object.frame.x >= 0, object.frame.y >= 0,
                          object.frame.x + object.frame.width <= page.width + 0.001,
                          object.frame.y + object.frame.height <= page.height + 0.001 else {
                        throw NoteStorageError.invalidGeometry
                    }
                    switch object.content {
                    case .text(let text):
                        guard text.fontSize.isFinite, (8...200).contains(text.fontSize) else { throw NoteStorageError.invalidGeometry }
                    case .image(let asset):
                        guard asset.width > 0, asset.height > 0, safeAssetName(asset.fileName, extension: "png") else {
                            throw NoteStorageError.invalidAsset
                        }
                    }
                }
            }
        }
    }
}
