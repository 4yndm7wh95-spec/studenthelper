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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
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
                    onAdjust: { increase in withAnimation(curve) { customSize = increase ? maximum : minimum } }, symbol: "arrow.up.left.and.arrow.down.right", active: resizing)
                    .frame(width: 44, height: 44)
                NotebookWindowGrip(label: "长按移动聊天窗口", identifier: "chat-move-handle",
                    onBegin: { startOffset = boundedOffset; withAnimation(curve) { moving = true } },
                    onChange: { delta in updateWithoutAnimation { offset = CGSize(width: startOffset.width + delta.width, height: startOffset.height + delta.height) } },
                    onEnd: { withAnimation(curve) { offset = boundedOffset; moving = false } }, active: moving)
                    .frame(maxWidth: .infinity).frame(height: 44)
                Color.clear.frame(width: 44, height: 44).allowsHitTesting(false)
            }
            content(CGSize(width: size.width, height: max(150, size.height - 44)), customSize != nil)
        }
            .frame(width: size.width, height: customSize == nil ? nil : size.height, alignment: .top)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .background(GeometryReader { geometry in
                Color.clear.onAppear { measuredHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in measuredHeight = height }
            })
            .animation(curve, value: available)
            .animation(curve, value: resizing)
            .animation(curve, value: moving)
            .shadow(color: .black.opacity(moving ? 0.16 : 0), radius: 20, y: 8)
            .offset(boundedOffset)
            .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-floating-window")
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
    var symbol: String? = nil
    var active = false
    func makeUIView(context: Context) -> GripView {
        let view = GripView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 44
        press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(press)
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: GripView, context: Context) {
        context.coordinator.parent = self
        view.onAdjust = onAdjust
        view.configure(symbol: symbol, active: active)
        view.accessibilityTraits = onAdjust == nil ? [] : .adjustable
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class GripView: UIView {
        var onAdjust: ((Bool) -> Void)?
        private let icon = UIImageView()
        private let bar = UIView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(icon); addSubview(bar)
            icon.contentMode = .scaleAspectFit
            icon.isUserInteractionEnabled = false; bar.isUserInteractionEnabled = false
            bar.layer.cornerRadius = 1.5
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(symbol: String?, active: Bool) {
            icon.image = symbol.flatMap { UIImage(systemName: $0) }
            icon.tintColor = UIColor(Notebook.tertiary)
            bar.isHidden = symbol != nil
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                self.bar.backgroundColor = UIColor(Notebook.secondary).withAlphaComponent(active ? 0.7 : 0.3)
                self.icon.transform = active ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            icon.frame = CGRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12)
            bar.frame = CGRect(x: bounds.midX - 13, y: bounds.midY - 1.5, width: 26, height: 3)
        }
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
