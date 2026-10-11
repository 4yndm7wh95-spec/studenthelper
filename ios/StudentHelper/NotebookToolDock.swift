import SwiftUI

struct NotebookToolDock<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @AppStorage("notebook.dock.edge") private var edge = "bottom"
    @AppStorage("notebook.dock.fraction") private var fraction = 0.5
    @State private var dragging = false
    @State private var finger = CGPoint.zero
    let content: (Bool) -> Content

    private var vertical: Bool { edge == "left" || edge == "right" }
    private var curve: Animation? { reduced ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.48) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let length = min(CGFloat(452), max(100, (vertical ? size.height : size.width) - 32))
            let width: CGFloat = dragging ? 58 : vertical ? 68 : length
            let height: CGFloat = dragging ? 58 : vertical ? length : 68
            ZStack {
                RoundedRectangle(cornerRadius: dragging ? 29 : 26, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay { RoundedRectangle(cornerRadius: dragging ? 29 : 26).stroke(.primary.opacity(0.08), lineWidth: 0.5) }
                if dragging {
                    Image(systemName: "pencil.tip").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Notebook.accent).transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
                Group {
                    let layout = vertical ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        handle(vertical: vertical, size: size)
                        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                            let tools = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
                            tools { content(vertical) }.padding(4)
                        }
                    }
                }.opacity(dragging ? 0 : 1).scaleEffect(dragging ? 0.75 : 1)
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(dragging ? 0.16 : 0.09), radius: dragging ? 18 : 10, y: 5)
            .position(dragging ? finger : position(size: size, length: length))
            .animation(curve, value: dragging)
            .animation(curve, value: edge)
            .animation(curve, value: fraction)
            .accessibilityIdentifier("notebook-tool-dock")
            .accessibilityValue(dragging ? "移动中" : edge)
        }.coordinateSpace(name: "notebook-dock-space")
    }

    private func handle(vertical: Bool, size: CGSize) -> some View {
        Capsule().fill(Notebook.secondary.opacity(0.35))
            .frame(width: vertical ? 3 : 26, height: vertical ? 26 : 3)
            .frame(width: vertical ? 16 : nil, height: vertical ? nil : 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("notebook-dock-space"))
                .onChanged { value in move(value.location) }
                .onEnded { value in snap(value.location, size: size) })
            .accessibilityLabel("移动工具栏")
            .accessibilityIdentifier("dock-drag-handle")
            .accessibilityAdjustableAction { direction in
                let edges = ["bottom", "left", "top", "right"]
                let index = edges.firstIndex(of: edge) ?? 0
                withAnimation(curve) { edge = edges[(index + (direction == .increment ? 1 : 3)) % 4] }
            }
    }

    private func move(_ point: CGPoint) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { finger = point }
        if !dragging { withAnimation(curve) { dragging = true } }
    }

    private func snap(_ point: CGPoint, size: CGSize) {
        let distances: [(String, CGFloat)] = [("left", point.x), ("right", size.width - point.x), ("top", point.y), ("bottom", size.height - point.y)]
        let next = distances.min { $0.1 < $1.1 }?.0 ?? "bottom"
        withAnimation(curve) {
            edge = next
            fraction = Double(min(1, max(0, next == "left" || next == "right" ? point.y / max(1, size.height) : point.x / max(1, size.width))))
            dragging = false
        }
    }

    private func position(size: CGSize, length: CGFloat) -> CGPoint {
        let margin: CGFloat = 12
        let x = min(max(length / 2 + margin, size.width * fraction), max(length / 2 + margin, size.width - length / 2 - margin))
        let y = min(max(length / 2 + margin, size.height * fraction), max(length / 2 + margin, size.height - length / 2 - margin))
        switch edge {
        case "left": return CGPoint(x: 46, y: y)
        case "right": return CGPoint(x: max(46, size.width - 46), y: y)
        case "top": return CGPoint(x: x, y: 88)
        default: return CGPoint(x: x, y: max(88, size.height - 82))
        }
    }
}
