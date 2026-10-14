import UIKit
import PencilKit

/// A scratch is a single, dense back-and-forth pen gesture over existing ink.
/// It deletes ink throughout the covered patch, including gaps between passes, never images.
enum NotebookScratchOut {
    struct Result {
        let drawing: PKDrawing
        let region: CGRect
    }
    static func apply(to drawing: PKDrawing, baseline: PKDrawing) -> Result? {
        guard !baseline.strokes.isEmpty, drawing.strokes.count == baseline.strokes.count + 1,
              let scratch = drawing.strokes.last, scratch.ink.inkType == .pen,
              zip(baseline.strokes, drawing.strokes).allSatisfy({ $0.0.path.creationDate == $0.1.path.creationDate }) else { return nil }
        let points = samples(scratch)
        guard points.count >= 16 else { return nil }
        let region = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 0.01, height: 0.01))) }
        let span = max(region.width, region.height)
        guard span >= 10, span <= 2000 else { return nil }
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        guard length >= max(60, span * 4),
              distance(points[0], points[points.count - 1]) < span * 0.65,
              max(turns(points.map(\.x), threshold: max(6, region.width * 0.18)),
                  turns(points.map(\.y), threshold: max(6, region.height * 0.18))) >= 4 else { return nil }
        let radius: CGFloat = 9
        let hull = convexHull(points)
        var erased = Set<Int>()
        for (index, stroke) in baseline.strokes.enumerated() {
            guard stroke.renderBounds.intersects(region.insetBy(dx: -radius, dy: -radius)) else { continue }
            let target = samples(stroke)
            guard !target.isEmpty else { continue }
            if target.contains(where: { inside($0, hull: hull, padding: radius) }) { erased.insert(index) }
        }
        guard !erased.isEmpty else { return nil }
        return Result(drawing: PKDrawing(strokes: baseline.strokes.enumerated().compactMap { erased.contains($0.offset) ? nil : $0.element }), region: region)
    }
    private static func samples(_ stroke: PKStroke) -> [CGPoint] {
        guard !stroke.path.isEmpty else { return [] }
        return stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower.last!, point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper.last!, point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
    private static func inside(_ point: CGPoint, hull: [CGPoint], padding: CGFloat) -> Bool {
        guard hull.count >= 2 else { return hull.contains { distance($0, point) <= padding } }
        var contained = false
        for index in hull.indices {
            let a = hull[index], b = hull[(index + 1) % hull.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.001, dx * dx + dy * dy)))
            if distance(point, CGPoint(x: a.x + t * dx, y: a.y + t * dy)) <= padding { return true }
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { contained.toggle() }
        }
        return contained
    }
    private static func turns(_ values: [CGFloat], threshold: CGFloat) -> Int {
        guard let first = values.first else { return 0 }
        var extreme = first, direction: CGFloat = 0, count = 0
        for value in values.dropFirst() {
            if direction == 0 {
                if abs(value - extreme) >= threshold { direction = value > extreme ? 1 : -1; extreme = value }
            } else if (value - extreme) * direction > 0 { extreme = value }
            else if (extreme - value) * direction >= threshold { direction = -direction; extreme = value; count += 1 }
        }
        return count
    }
}
