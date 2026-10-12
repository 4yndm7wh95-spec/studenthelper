import SwiftUI
import UIKit

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
            content(CGSize(width: size.width, height: max(150, displayHeight - 44)), customSize != nil || keyboardSpace != nil)
        }
            .frame(width: size.width, height: customSize == nil && keyboardSpace == nil ? nil : displayHeight, alignment: .top)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .background(GeometryReader { geometry in
                Color.clear.onAppear { measuredHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in measuredHeight = height }
            })
            .animation(curve, value: available)
            .animation(curve, value: resizing)
            .animation(curve, value: moving)
            .shadow(color: .black.opacity(moving ? 0.16 : 0), radius: 20, y: 8)
            .overlay(alignment: .bottomLeading) {
                NotebookWindowGrip(label: "调整聊天窗口大小", identifier: "chat-resize-bottom-left",
                    onBegin: {
                        startSize = CGSize(width: size.width, height: min(maximum.height, max(minimum.height, measuredHeight)))
                        startOffset = boundedOffset
                        withAnimation(curve) { resizing = true }
                    }, onChange: { delta in
                        updateWithoutAnimation {
                            let height = min(maximum.height, max(minimum.height, startSize.height + delta.height))
                            customSize = CGSize(width: min(maximum.width, max(minimum.width, startSize.width - delta.width)), height: height)
                            offset = CGSize(width: startOffset.width, height: startOffset.height + height - startSize.height)
                        }
                    }, onEnd: { withAnimation(curve) { offset = boundedOffset; resizing = false } },
                    onAdjust: { increase in withAnimation(curve) { customSize = increase ? maximum : minimum } }, symbol: "arrow.down.left.and.arrow.up.right", active: resizing)
                    .frame(width: 44, height: 44)
            }
            .offset(displayOffset)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
                let local = window?.convert(frame, from: nil) ?? frame
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.35
                withAnimation(reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: duration)) { keyboardFrame = local }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(curve) { keyboardFrame = nil }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-floating-window")
            .onChange(of: available) { _, _ in if customSize != nil { withAnimation(curve) { customSize = size } } }
    }
    private func updateWithoutAnimation(_ change: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
    private var keyboardSpace: CGFloat? {
        guard let keyboardFrame, keyboardFrame.width >= viewport.width * 0.6,
              keyboardFrame.intersects(viewport) else { return nil }
        return max(minimum.height, keyboardFrame.minY - viewport.minY - 24)
    }
    private var displayHeight: CGFloat {
        guard let keyboardSpace else { return size.height }
        return min(customSize == nil ? max(minimum.height, measuredHeight) : size.height, keyboardSpace)
    }
    private var displayOffset: CGSize {
        guard keyboardSpace != nil, let keyboardFrame else { return boundedOffset }
        let lift = max(0, viewport.maxY - keyboardFrame.minY)
        return CGSize(width: boundedOffset.width,
                      height: max(displayHeight - available.height, min(boundedOffset.height, -lift)))
    }
    private var boundedOffset: CGSize {
        CGSize(width: min(size.width / 2, max(-(available.width - size.width / 2), offset.width)),
               height: min(measuredHeight / 2, max(-(available.height - measuredHeight / 2), offset.height)))
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
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("notebook-window-space"))
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
