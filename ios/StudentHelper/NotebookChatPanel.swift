import SwiftUI
import UIKit

struct NotebookChatPanel<Content: View>: View {
    let available: CGSize
    let content: (CGSize, Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var customSize: CGSize?
    @State private var resizing = false
    @State private var startSize = CGSize.zero
    @State private var offset = CGSize.zero
    @State private var startOffset = CGSize.zero
    @State private var moving = false
    @State private var measuredHeight: CGFloat = 190

    private var minimum: CGSize { CGSize(width: min(370, available.width), height: min(190, available.height)) }
    private var maximum: CGSize {
        CGSize(width: min(available.width, max(minimum.width, available.width * 0.75)),
               height: min(available.height, max(minimum.height, available.height * 0.75)))
    }
    private var size: CGSize {
        let chosen = customSize ?? minimum
        return CGSize(width: min(maximum.width, max(minimum.width, chosen.width)), height: min(maximum.height, max(minimum.height, chosen.height)))
    }
    var body: some View {
        content(size, customSize != nil)
            .frame(width: size.width, height: customSize == nil ? nil : size.height, alignment: .top)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { measuredHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in measuredHeight = height }
            })
            .overlay(alignment: .top) {
                Capsule().fill(Notebook.secondary.opacity(moving ? 0.7 : 0.3)).frame(width: 26, height: 3)
                    .frame(width: 104, height: 44, alignment: .top).padding(.top, 6)
                    .overlay {
                        NotebookWindowGrip(label: "长按移动聊天窗口", identifier: "chat-move-handle",
                            onBegin: { startOffset = boundedOffset; withAnimation(curve) { moving = true } },
                            onChange: { delta in updateWithoutAnimation { offset = CGSize(width: startOffset.width + delta.width, height: startOffset.height + delta.height) } },
                            onEnd: { withAnimation(curve) { offset = boundedOffset; moving = false } })
                    }
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Notebook.tertiary)
                    .frame(width: 44, height: 44, alignment: .topLeading).padding(6)
                    .background { Circle().fill(Notebook.soft.opacity(resizing ? 1 : 0)).frame(width: 32, height: 32) }
                    .overlay {
                        NotebookWindowGrip(label: "长按调整聊天窗口大小", identifier: "chat-resize-handle",
                            onBegin: {
                                startSize = CGSize(width: size.width, height: min(maximum.height, max(minimum.height, measuredHeight)))
                                withAnimation(curve) { resizing = true }
                            }, onChange: { delta in
                                updateWithoutAnimation {
                                    customSize = CGSize(width: min(maximum.width, max(minimum.width, startSize.width - delta.width)),
                                                        height: min(maximum.height, max(minimum.height, startSize.height - delta.height)))
                                }
                            }, onEnd: { withAnimation(curve) { resizing = false } },
                            onAdjust: { increase in withAnimation(curve) { customSize = increase ? maximum : minimum } })
                    }
            }
            .animation(curve, value: available)
            .animation(curve, value: resizing)
            .animation(curve, value: moving)
            .shadow(color: .black.opacity(moving ? 0.16 : 0), radius: 20, y: 8)
            .offset(boundedOffset)
            .onChange(of: available) { _, _ in if customSize != nil { withAnimation(curve) { customSize = size } } }
    }
    private func updateWithoutAnimation(_ change: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
    private var boundedOffset: CGSize {
        CGSize(width: min(size.width / 2, max(-(available.width - size.width / 2), offset.width)),
               height: min(measuredHeight / 2, max(-(available.height - measuredHeight / 2), offset.height)))
    }
    private var curve: Animation? { reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.42) }
}

private struct NotebookWindowGrip: UIViewRepresentable {
    let label: String
    let identifier: String
    let onBegin: () -> Void
    let onChange: (CGSize) -> Void
    let onEnd: () -> Void
    var onAdjust: ((Bool) -> Void)? = nil
    func makeUIView(context: Context) -> GripView {
        let view = GripView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 44
        press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(press)
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: GripView, context: Context) {
        context.coordinator.parent = self
        view.onAdjust = onAdjust
        view.accessibilityTraits = onAdjust == nil ? [] : .adjustable
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class GripView: UIView {
        var onAdjust: ((Bool) -> Void)?
        override func accessibilityIncrement() { onAdjust?(true) }
        override func accessibilityDecrement() { onAdjust?(false) }
    }
    final class Coordinator: NSObject {
        var parent: NotebookWindowGrip
        private var origin = CGPoint.zero
        init(_ parent: NotebookWindowGrip) { self.parent = parent }
        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            guard let window = gesture.view?.window else { return }
            let point = gesture.location(in: window)
            switch gesture.state {
            case .began: origin = point; parent.onBegin()
            case .changed: parent.onChange(CGSize(width: point.x - origin.x, height: point.y - origin.y))
            case .ended:
                parent.onChange(CGSize(width: point.x - origin.x, height: point.y - origin.y)); parent.onEnd()
            case .cancelled, .failed: parent.onEnd()
            default: break
            }
        }
    }
}
