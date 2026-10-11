import SwiftUI
import UIKit

/// 独立于内容层显示，原生弹窗打开时仍能停止 AI。
struct AIControlOverlay: View {
    @ObservedObject var automation: AppAutomation
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var breathing = false

    private var motion: Animation? {
        reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 3.8).repeatForever(autoreverses: true)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.025).contentShape(Rectangle()).onTapGesture {}
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AngularGradient(colors: [Notebook.accent.opacity(0.06), Notebook.accent.opacity(0.48), Notebook.soft.opacity(0.2), Notebook.accent.opacity(0.08)],
                                        center: .center, angle: .degrees(breathing ? 45 : -20)), lineWidth: breathing ? 2.5 : 1.5)
                .blur(radius: breathing ? 1 : 2).padding(9)
                .opacity(breathing ? 0.95 : 0.65).animation(motion, value: breathing)
                .allowsHitTesting(false).accessibilityHidden(true)
            GeometryReader { geometry in
                Circle().fill(Notebook.accent.opacity(0.55)).frame(width: 6, height: 6)
                    .blur(radius: 0.5)
                    .position(x: geometry.size.width - (breathing ? 24 : 31), y: geometry.size.height * (breathing ? 0.3 : 0.34))
                    .opacity(breathing ? 0.85 : 0.35).animation(motion, value: breathing)
                Circle().fill(Notebook.accent.opacity(0.3)).frame(width: 4, height: 4)
                    .position(x: breathing ? 21 : 29, y: geometry.size.height * (breathing ? 0.7 : 0.73))
                    .animation(motion, value: breathing)
            }.allowsHitTesting(false).accessibilityHidden(true)
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(Notebook.accent)
                    .scaleEffect(breathing ? 1.08 : 0.94).animation(motion, value: breathing)
                    .accessibilityLabel("AI 操作中").accessibilityIdentifier("ai-control-overlay")
                Text(automation.status.isEmpty ? "正在处理" : automation.status)
                    .font(.subheadline).foregroundStyle(Notebook.ink).lineLimit(2)
                    .contentTransition(.opacity)
                    .animation(reduced ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.4), value: automation.status)
                Button { automation.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 14)).foregroundStyle(Notebook.ink)
                        .frame(width: 44, height: 44).background(Notebook.sunk, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("停止 AI 操作").accessibilityIdentifier("ai-stop")
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            .background(Notebook.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Notebook.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 18, y: 4)
            .frame(maxWidth: 440).padding(.horizontal, 22).padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: [.leading, .trailing, .bottom])
        .accessibilityElement(children: .contain)
        .onAppear { if !reduced { breathing = true } }
        .onChange(of: reduced) { _, value in breathing = !value }
    }
}

private struct AIInteractionLock: ViewModifier {
    @EnvironmentObject private var automation: AppAutomation
    func body(content: Content) -> some View {
        content.allowsHitTesting(!automation.active).accessibilityHidden(automation.active)
    }
}

private struct AIWindowLayer: ViewModifier {
    @EnvironmentObject private var automation: AppAutomation
    func body(content: Content) -> some View {
        content.aiInteractionLocked()
            .background(AIControlWindowHost(automation: automation).frame(width: 0, height: 0))
    }
}

extension View {
    func aiInteractionLocked() -> some View { modifier(AIInteractionLock()) }
    func aiControlWindow() -> some View { modifier(AIWindowLayer()) }
}

/// 触控先进入这个窗口，避免 sheet / 文件选择器绕过底层锁定。
private struct AIControlWindowHost: UIViewRepresentable {
    @ObservedObject var automation: AppAutomation
    func makeCoordinator() -> Coordinator { Coordinator(automation: automation) }
    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] scene in coordinator?.update(scene: scene) }
        return view
    }
    func updateUIView(_ uiView: HostView, context: Context) {
        context.coordinator.automation = automation
        context.coordinator.update(scene: uiView.window?.windowScene)
    }
    static func dismantleUIView(_ uiView: HostView, coordinator: Coordinator) { coordinator.removeWindow() }

    final class HostView: UIView {
        var onWindowChanged: ((UIWindowScene?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onWindowChanged?(window?.windowScene) }
        override func layoutSubviews() { super.layoutSubviews(); onWindowChanged?(window?.windowScene) }
    }

    @MainActor final class Coordinator {
        var automation: AppAutomation
        private var overlayWindow: UIWindow?
        private weak var previousKeyWindow: UIWindow?
        init(automation: AppAutomation) { self.automation = automation }
        func update(scene: UIWindowScene?) {
            guard automation.active, let scene else { removeWindow(); return }
            if let window = overlayWindow {
                if window.frame != scene.coordinateSpace.bounds { window.frame = scene.coordinateSpace.bounds }
                return
            }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            let controller = UIHostingController(rootView: AIControlOverlay(automation: automation).tint(Notebook.accent))
            controller.view.backgroundColor = .clear
            controller.view.accessibilityViewIsModal = true
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.rootViewController = controller
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            overlayWindow = window
            window.makeKeyAndVisible()
            UIAccessibility.post(notification: .screenChanged, argument: controller.view)
        }
        func removeWindow() {
            guard let window = overlayWindow else { return }
            window.isHidden = true; window.rootViewController = nil; overlayWindow = nil
            previousKeyWindow?.makeKey(); previousKeyWindow = nil
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}
