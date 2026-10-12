import SwiftUI
import UIKit

enum NotebookWindowCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var right: Bool { self == .topRight || self == .bottomRight }
    var bottom: Bool { self == .bottomLeft || self == .bottomRight }
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
    var identifier: String {
        switch self {
        case .topLeft: return "chat-resize-handle"
        case .topRight: return "chat-resize-top-right"
        case .bottomLeft: return "chat-resize-bottom-left"
        case .bottomRight: return "chat-resize-bottom-right"
        }
    }
    func resized(_ size: CGSize, offset: CGSize, delta: CGSize) -> (CGSize, CGSize) {
        let width = max(1, size.width + (right ? delta.width : -delta.width))
        let height = max(1, size.height + (bottom ? delta.height : -delta.height))
        return (CGSize(width: width, height: height),
                CGSize(width: offset.width + (right ? width - size.width : 0),
                       height: offset.height + (bottom ? height - size.height : 0)))
    }
}

struct NotebookChatPanel<Content: View>: View {
    let available: CGSize
    let viewport: CGRect
    let content: (CGSize, Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var customSize: CGSize?
    @State private var resizing = false
    @State private var startSize = CGSize.zero
    @State private var offset = CGSize.zero
    @State private var startOffset = CGSize.zero
    @State private var moving = false
    @State private var measuredHeight: CGFloat = 190
    @State private var keyboardFrame: CGRect?
    @State private var keyboardManuallyPositioned = false

    private var size: CGSize { customSize ?? CGSize(width: min(370, available.width), height: 190) }
    var body: some View {
        VStack(spacing: 0) {
            NotebookWindowGrip(label: "长按移动聊天窗口", identifier: "chat-move-handle",
                onBegin: {
                    startOffset = displayOffset
                    offset = startOffset
                    keyboardManuallyPositioned = true
                    withAnimation(curve) { moving = true }
                }, onChange: { delta in
                    updateWithoutAnimation { offset = CGSize(width: startOffset.width + delta.width, height: startOffset.height + delta.height) }
                }, onEnd: { withAnimation(curve) { moving = false } }, active: moving)
                .frame(height: 52).padding(.horizontal, min(52, size.width / 3))
            content(CGSize(width: size.width, height: max(1, displayHeight - 52)), customSize != nil || keyboardSpace != nil)
        }
        .frame(width: size.width, height: customSize == nil && keyboardSpace == nil ? nil : displayHeight, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .background(GeometryReader { geometry in
            Color.clear.onAppear { measuredHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in measuredHeight = height }
        })
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .animation(curve, value: resizing)
        .animation(curve, value: moving)
        .shadow(color: .black.opacity(moving || resizing ? 0.16 : 0), radius: 20, y: 8)
        .overlay {
            ZStack {
                ForEach(NotebookWindowCorner.allCases, id: \.self) { corner in
                    resizeGrip(corner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                }
            }
        }
        .offset(displayOffset)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
            let local = window?.convert(frame, from: nil) ?? frame
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.35
            withAnimation(reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: duration)) {
                keyboardFrame = local; keyboardManuallyPositioned = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(curve) { keyboardFrame = nil; keyboardManuallyPositioned = false }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-floating-window")
    }
    private func resizeGrip(_ corner: NotebookWindowCorner) -> some View {
        NotebookWindowGrip(label: "调整聊天窗口大小", identifier: corner.identifier,
            onBegin: {
                startSize = CGSize(width: size.width, height: measuredHeight)
                startOffset = displayOffset
                keyboardManuallyPositioned = true
                offset = startOffset
                withAnimation(curve) { resizing = true }
            }, onChange: { delta in
                updateWithoutAnimation {
                    let result = corner.resized(startSize, offset: startOffset, delta: delta)
                    customSize = result.0; offset = result.1
                }
            }, onEnd: { withAnimation(curve) { resizing = false } },
            onAdjust: { increase in
                withAnimation(curve) {
                    let step: CGFloat = increase ? 40 : -40
                    let result = corner.resized(CGSize(width: size.width, height: measuredHeight), offset: offset,
                        delta: CGSize(width: corner.right ? step : -step, height: corner.bottom ? step : -step))
                    customSize = result.0; offset = result.1
                }
            }, symbol: corner.right == corner.bottom ? "arrow.up.left.and.arrow.down.right" : "arrow.down.left.and.arrow.up.right", active: resizing)
            .frame(width: min(52, size.width / 2), height: min(52, max(1, measuredHeight / 2)))
    }
    private func updateWithoutAnimation(_ change: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
    private var keyboardSpace: CGFloat? {
        guard !keyboardManuallyPositioned, let keyboardFrame, keyboardFrame.width >= viewport.width * 0.6,
              keyboardFrame.intersects(viewport) else { return nil }
        return max(190, keyboardFrame.minY - viewport.minY - 24)
    }
    private var displayHeight: CGFloat {
        guard let keyboardSpace else { return size.height }
        return min(customSize == nil ? max(190, measuredHeight) : size.height, keyboardSpace)
    }
    private var displayOffset: CGSize {
        guard keyboardSpace != nil, let keyboardFrame else { return offset }
        let lift = max(0, viewport.maxY - keyboardFrame.minY)
        return CGSize(width: offset.width, height: max(displayHeight - available.height, min(offset.height, -lift)))
    }
    private var curve: Animation? { reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.42) }
}

private struct NotebookWindowGrip: View {
    let label: String
    let identifier: String
    let onBegin: () -> Void
    let onChange: (CGSize) -> Void
    let onEnd: () -> Void
    var onAdjust: ((Bool) -> Void)? = nil
    var symbol: String? = nil
    var active = false
    @State private var tracking = false
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        ZStack {
            Rectangle().fill(Notebook.surface.opacity(0.001))
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Notebook.tertiary)
                    .scaleEffect(active ? 1.12 : 1)
            } else {
                Capsule().fill(Notebook.secondary.opacity(active ? 0.7 : 0.3)).frame(width: 26, height: 3)
                    .scaleEffect(active ? 1.16 : 1)
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("notebook-window-space"))
            .onChanged { value in
                if !tracking { tracking = true; onBegin() }
                onChange(value.translation)
            }
            .onEnded { value in onChange(value.translation); tracking = false; onEnd() })
        .animation(reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.25), value: active)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
        .accessibilityValue(active ? "移动中" : "就绪")
        .accessibilityAdjustableAction { direction in onAdjust?(direction == .increment) }
    }
}
