import UIKit
import WebKit
import PencilKit

@MainActor
final class NotebookHandwriting: NSObject, WKNavigationDelegate {
    private var ready = false
    private var navigationError: Error?
    static let red = UIColor(red: 0.82, green: 0.15, blue: 0.17, alpha: 1)

    static func drawing(text: String, frame: CGRect) async throws -> PKDrawing {
        let renderer = NotebookHandwriting()
        return try await renderer.render(text: text, frame: frame)
    }
    private func render(text: String, frame: CGRect) async throws -> PKDrawing {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 1600, frame.width >= 24, frame.height >= 24,
              let folder = Bundle.main.url(forResource: "WebMath", withExtension: nil) else { throw NotebookAgentError.invalidTool }
        let width = min(600, frame.width)
        let web = WKWebView(frame: CGRect(x: -2000, y: 0, width: width, height: 1600))
        web.isAccessibilityElement = false; web.accessibilityElementsHidden = true
        web.navigationDelegate = self
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        window?.addSubview(web)
        defer { web.stopLoading(); web.navigationDelegate = nil; web.removeFromSuperview() }
        web.loadFileURL(folder.appendingPathComponent("ink.html"), allowingReadAccessTo: folder)
        for _ in 0..<240 {
            try Task.checkCancellation()
            if ready || navigationError != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        if let navigationError { throw navigationError }
        guard ready else { throw NotebookAgentError.unreadable }
        let layout = try await web.callAsyncJavaScript("return await window.prepareInk(text);", arguments: ["text": text], in: nil, contentWorld: .page) as? [String: Any]
        guard let height = (layout?["height"] as? NSNumber)?.doubleValue, height > 0, height <= 1500,
              (layout?["errors"] as? NSNumber)?.intValue == 0 else {
            throw AppAutomationError.invalid("公式无法正确排版，请使用完整的LaTeX公式并用$或\\(…\\)包围，不写原始公式代码。")
        }
        let scale = min(1, min(frame.width / width, frame.height / CGFloat(height)))
        guard scale >= 0.4 else { throw AppAutomationError.invalid("批注区域太小，请减少文字或扩大区域，不能挤成看不清的公式。") }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.snapshotWidth = NSNumber(value: width * 2)
        let image = try await web.takeSnapshot(configuration: configuration)
        try Task.checkCancellation()
        guard let cg = image.cgImage else { throw NotebookAgentError.unreadable }
        let pixels = Self.mask(cg)
        let paths = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.centerlines(pixels, width: cg.width, height: cg.height)
        }.value
        try Task.checkCancellation()
        let pixelScale = width / CGFloat(cg.width) * scale
        var strokes: [PKStroke] = []
        for (index, path) in paths.enumerated() where !path.isEmpty {
            let points = path.enumerated().map { offset, point in
                PKStrokePoint(location: CGPoint(x: frame.minX + point.x * pixelScale, y: frame.minY + point.y * pixelScale),
                    timeOffset: Double(offset) * 0.008, size: CGSize(width: 1.65 * scale, height: 1.65 * scale), opacity: 1,
                    force: 0.8, azimuth: 0, altitude: .pi / 2)
            }
            strokes.append(PKStroke(ink: PKInk(.pen, color: Self.red), path: PKStrokePath(controlPoints: points,
                creationDate: Date(timeIntervalSince1970: Date().timeIntervalSince1970 + Double(index) * 0.0001))))
        }
        guard !strokes.isEmpty, strokes.count <= 6000 else { throw NotebookAgentError.unreadable }
        return PKDrawing(strokes: strokes)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }

    private static func mask(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels.map { $0 < 180 ? 1 : 0 }
    }

    // Thin rendered glyphs into connected pen centerlines, preserving mathematical layout.
    nonisolated private static func centerlines(_ source: [UInt8], width: Int, height: Int) throws -> [[CGPoint]] {
        guard width >= 3, height >= 3 else { return [] }
        var pixels = source
        let offsets = [-width, -width + 1, 1, width + 1, width, width - 1, -1, -width - 1]
        let active = source.indices.filter { source[$0] == 1 && $0 % width > 0 && $0 % width < width - 1 && $0 / width > 0 && $0 / width < height - 1 }
        for _ in 0..<80 {
            try Task.checkCancellation()
            var changed = false
            for phase in 0...1 {
                var removed: [Int] = []
                for index in active where pixels[index] == 1 {
                    let p = offsets.map { pixels[index + $0] }
                    let count = p.reduce(0) { $0 + Int($1) }
                    guard count >= 2, count <= 6 else { continue }
                    let transitions = (0..<8).filter { p[$0] == 0 && p[($0 + 1) % 8] == 1 }.count
                    guard transitions == 1 else { continue }
                    let first = phase == 0 ? p[0] * p[2] * p[4] : p[0] * p[2] * p[6]
                    let second = phase == 0 ? p[2] * p[4] * p[6] : p[0] * p[4] * p[6]
                    if first == 0 && second == 0 { removed.append(index) }
                }
                if !removed.isEmpty { changed = true; removed.forEach { pixels[$0] = 0 } }
            }
            if !changed { break }
        }
        func neighbors(_ index: Int) -> [Int] {
            offsets.map { index + $0 }.filter { $0 >= 0 && $0 < pixels.count && pixels[$0] == 1 && abs($0 % width - index % width) <= 1 }
        }
        func edge(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
        var visited = Set<UInt64>(), paths: [[CGPoint]] = []
        let skeleton = active.filter { pixels[$0] == 1 }
        for start in skeleton.sorted(by: { neighbors($0).count != 2 && neighbors($1).count == 2 }) {
            try Task.checkCancellation()
            let choices = neighbors(start)
            if choices.isEmpty { paths.append([CGPoint(x: start % width, y: start / width)]); continue }
            for next in choices where !visited.contains(edge(start, next)) {
                var path = [start], previous = start, current = next
                visited.insert(edge(previous, current))
                while true {
                    path.append(current)
                    let options = neighbors(current).filter { $0 != previous }
                    guard neighbors(current).count == 2, let following = options.first,
                          !visited.contains(edge(current, following)) else { break }
                    visited.insert(edge(current, following)); previous = current; current = following
                }
                paths.append(path.map { CGPoint(x: $0 % width, y: $0 / width) })
            }
        }
        return paths
    }
}
