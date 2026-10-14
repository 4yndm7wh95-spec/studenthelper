import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

enum NotebookShapes {
    struct Shape {
        let kind: String
        let points: [CGPoint]
        func stroke(ink: PKInk, width: CGFloat) -> PKStroke {
            PKStroke(ink: ink, path: PKStrokePath(controlPoints: points.enumerated().map {
                PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.008,
                    size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date()))
        }
    }
    static func recognize(_ input: [CGPoint]) -> Shape? {
        guard input.count >= 5, input.count <= 8192, input.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var points = [input[0]]
        for point in input.dropFirst() where distance(points.last!, point) >= 1.5 { points.append(point) }
        guard points.count >= 4 else { return nil }
        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 0.01, height: 0.01))) }
        let span = hypot(box.width, box.height)
        guard span.isFinite, span >= 30, span <= 5000 else { return nil }
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        let first = points[0], last = points.last!
        let closed = distance(first, last) < max(12, span * 0.16)
        if !closed, length <= distance(first, last) * 1.3,
           points.map({ segmentDistance($0, first, last) }).max()! <= max(6, span * 0.07) {
            var start = first, end = last
            if abs(end.y - start.y) < span * 0.06 { start.y = (first.y + last.y) / 2; end.y = start.y }
            else if abs(end.x - start.x) < span * 0.06 { start.x = (first.x + last.x) / 2; end.x = start.x }
            return Shape(kind: "line", points: densify([start, end]))
        }
        if closed, let oval = ellipse(points, length: length) { return oval }
        var vertices = simplify(closed ? points + [first] : points, tolerance: max(5, span * 0.035))
        if closed {
            if distance(vertices.first!, vertices.last!) < max(12, span * 0.16) { vertices.removeLast() }
            var changed = true
            while changed && vertices.count > 3 {
                changed = false
                for index in vertices.indices {
                    let previous = vertices[(index + vertices.count - 1) % vertices.count], next = vertices[(index + 1) % vertices.count]
                    if segmentDistance(vertices[index], previous, next) <= max(5, span * 0.035) {
                        vertices.remove(at: index); changed = true; break
                    }
                }
            }
            guard (3...8).contains(vertices.count), vertices.indices.allSatisfy({ distance(vertices[$0], vertices[($0 + 1) % vertices.count]) >= 14 }) else { return nil }
            let perimeter = vertices.indices.reduce(CGFloat.zero) { $0 + distance(vertices[$1], vertices[($1 + 1) % vertices.count]) }
            guard length <= perimeter * 1.35 else { return nil }
            if vertices.count == 4, rectangular(vertices) {
                var angle = atan2(vertices[1].y - vertices[0].y, vertices[1].x - vertices[0].x)
                let snapped = (angle / (.pi / 4)).rounded() * .pi / 4
                if abs(angle - snapped) < 0.12 { angle = snapped }
                let rotation = CGAffineTransform(rotationAngle: -angle)
                let projected = vertices.map { $0.applying(rotation) }
                let rectangle = projected.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 0.01, height: 0.01))) }
                let square = max(rectangle.width, rectangle.height) / min(rectangle.width, rectangle.height) < 1.18
                let w = square ? (rectangle.width + rectangle.height) / 2 : rectangle.width
                let h = square ? w : rectangle.height
                let x = rectangle.midX - w / 2, y = rectangle.midY - h / 2
                let reverse = CGAffineTransform(rotationAngle: angle)
                vertices = [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)].map { $0.applying(reverse) }
                return Shape(kind: square ? "square" : "rectangle", points: densify(vertices + [vertices[0]]))
            }
            return Shape(kind: vertices.count == 3 ? "triangle" : "polygon", points: densify(vertices + [vertices[0]]))
        }
        guard (3...5).contains(vertices.count) else { return nil }
        let simplifiedLength = zip(vertices, vertices.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        guard length < simplifiedLength * 1.2 else { return nil }
        // Orthogonal turns snap to the first segment's axes, including rotated L/Z paths.
        if vertices.count == 3 {
            let a = vertices[1] - vertices[0], b = vertices[2] - vertices[1]
            let cosine = abs(a.x * b.x + a.y * b.y) / max(1, hypot(a.x, a.y) * hypot(b.x, b.y))
            if cosine < 0.22 {
                let rotation = CGAffineTransform(rotationAngle: -atan2(a.y, a.x))
                var projected = vertices.map { $0.applying(rotation) }
                projected[1].y = projected[0].y; projected[2].x = projected[1].x
                vertices = projected.map { $0.applying(rotation.inverted()) }
            }
        }
        return Shape(kind: "polyline", points: densify(vertices))
    }
    private static func ellipse(_ points: [CGPoint], length: CGFloat) -> Shape? {
        let mean = CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count), y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for p in points { let d = p - mean; xx += d.x * d.x; yy += d.y * d.y; xy += d.x * d.y }
        let angle = atan2(2 * xy, xx - yy) / 2
        let rotation = CGAffineTransform(rotationAngle: -angle)
        let local = points.map { ($0 - mean).applying(rotation) }
        let bounds = local.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 0.01, height: 0.01))) }
        var rx = bounds.width / 2, ry = bounds.height / 2
        guard min(rx, ry) >= 12 else { return nil }
        let errors = local.map { abs(hypot(($0.x - bounds.midX) / rx, ($0.y - bounds.midY) / ry) - 1) }
        guard errors.reduce(0, +) / CGFloat(errors.count) < 0.11, errors.max()! < 0.3 else { return nil }
        let circumference = .pi * (3 * (rx + ry) - sqrt((3 * rx + ry) * (rx + 3 * ry)))
        guard length > circumference * 0.7, length < circumference * 1.3 else { return nil }
        let circle = max(rx, ry) / min(rx, ry) < 1.18
        if circle { rx = (rx + ry) / 2; ry = rx }
        let start = atan2((local[0].y - bounds.midY) / ry, (local[0].x - bounds.midX) / rx)
        let path = (0...96).map { index -> CGPoint in
            let theta = start + CGFloat(index) / 96 * .pi * 2
            let p = CGPoint(x: bounds.midX + rx * cos(theta), y: bounds.midY + ry * sin(theta)).applying(rotation.inverted())
            return CGPoint(x: p.x + mean.x, y: p.y + mean.y)
        }
        return Shape(kind: circle ? "circle" : "ellipse", points: path)
    }
    private static func rectangular(_ v: [CGPoint]) -> Bool {
        v.indices.allSatisfy { i in
            let a = v[(i + 1) % 4] - v[i], b = v[(i + 2) % 4] - v[(i + 1) % 4]
            return abs(a.x * b.x + a.y * b.y) / max(1, hypot(a.x, a.y) * hypot(b.x, b.y)) < 0.3
        }
    }
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let maximum = (1..<points.count - 1).max { segmentDistance(points[$0], points[0], points.last!) < segmentDistance(points[$1], points[0], points.last!) }!
        guard segmentDistance(points[maximum], points[0], points.last!) > tolerance else { return [points[0], points.last!] }
        return Array(simplify(Array(points[...maximum]), tolerance: tolerance).dropLast()) + simplify(Array(points[maximum...]), tolerance: tolerance)
    }
    private static func densify(_ vertices: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            let count = max(1, Int(distance(a, b) / 2))
            for index in 0..<count { let t = CGFloat(index) / CGFloat(count); result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        }
        if let last = vertices.last { result.append(last) }
        return result
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func segmentDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = b - a, t = min(1, max(0, ((point.x - a.x) * d.x + (point.y - a.y) * d.y) / max(0.001, d.x * d.x + d.y * d.y)))
        return distance(point, CGPoint(x: a.x + d.x * t, y: a.y + d.y * t))
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

@MainActor
final class NotebookShapeHoldGesture: UIGestureRecognizer {
    var onHold: (([CGPoint]) -> Void)?
    var onResume: (() -> Void)?
    var onContact: ((Bool) -> Void)?
    private var points: [CGPoint] = []
    private var anchor = CGPoint.zero
    private var timer: DispatchWorkItem?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { state = .failed; return }
        points = [touch.location(in: view)]; anchor = points[0]; state = .began
        onContact?(true)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            let point = sample.location(in: view)
            if points.count < 8192, points.last.map({ hypot($0.x - point.x, $0.y - point.y) >= 1 }) ?? true { points.append(point) }
        }
        let point = touch.location(in: view)
        if hypot(point.x - anchor.x, point.y - anchor.y) >= 3 {
            anchor = point; timer?.cancel(); onResume?()
            let hold = DispatchWorkItem { [weak self] in guard let self else { return }; self.onHold?(self.points) }
            timer = hold; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: hold)
        }
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { timer?.cancel(); timer = nil; onContact?(false); state = .ended }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { timer?.cancel(); timer = nil; onResume?(); onContact?(false); state = .cancelled }
    override func reset() { super.reset(); timer?.cancel(); timer = nil; points = [] }
}
