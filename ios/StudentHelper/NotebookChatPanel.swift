import SwiftUI

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
                    .frame(width: 80, height: 18).contentShape(Rectangle()).offset(y: -6)
                    .gesture(LongPressGesture(minimumDuration: 0.3, maximumDistance: 20)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            if case .second(true, let drag) = value {
                                if !moving { startOffset = boundedOffset; withAnimation(curve) { moving = true } }
                                if let drag {
                                    var transaction = Transaction(); transaction.disablesAnimations = true
                                    withTransaction(transaction) { offset = CGSize(width: startOffset.width + drag.translation.width, height: startOffset.height + drag.translation.height) }
                                }
                            }
                        }.onEnded { _ in withAnimation(curve) { offset = boundedOffset; moving = false } })
                    .accessibilityLabel("长按移动聊天窗口").accessibilityIdentifier("chat-move-handle")
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Notebook.tertiary)
                    .frame(width: 32, height: 32).contentShape(Rectangle()).offset(x: -8, y: -8)
                    .background { Circle().fill(Notebook.soft.opacity(resizing ? 1 : 0)).frame(width: 32, height: 32) }
                    .gesture(LongPressGesture(minimumDuration: 0.3, maximumDistance: 20)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            switch value {
                            case .second(true, let drag):
                                if !resizing {
                                    startSize = CGSize(width: size.width, height: min(maximum.height, max(minimum.height, measuredHeight)))
                                    withAnimation(curve) { resizing = true }
                                }
                                if let drag {
                                    var transaction = Transaction(); transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        customSize = CGSize(width: min(maximum.width, max(minimum.width, startSize.width - drag.translation.width)),
                                                            height: min(maximum.height, max(minimum.height, startSize.height - drag.translation.height)))
                                    }
                                }
                            default: break
                            }
                        }.onEnded { _ in withAnimation(curve) { resizing = false } })
                    .accessibilityLabel("长按调整聊天窗口大小").accessibilityIdentifier("chat-resize-handle")
                    .accessibilityAdjustableAction { direction in
                        withAnimation(curve) { customSize = direction == .increment ? maximum : minimum }
                    }
            }
            .animation(curve, value: available)
            .animation(curve, value: resizing)
            .animation(curve, value: moving)
            .shadow(color: .black.opacity(moving ? 0.16 : 0), radius: 20, y: 8)
            .offset(boundedOffset)
            .onChange(of: available) { _, _ in if customSize != nil { withAnimation(curve) { customSize = size } } }
    }
    private var boundedOffset: CGSize {
        CGSize(width: min(size.width / 2, max(-(available.width - size.width / 2), offset.width)),
               height: min(measuredHeight / 2, max(-(available.height - measuredHeight / 2), offset.height)))
    }
    private var curve: Animation? { reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.42) }
}
