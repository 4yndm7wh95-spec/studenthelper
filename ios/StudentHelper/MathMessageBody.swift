import SwiftUI
import WebKit

struct MathMessageBody: View {
    let text: String
    var cards = true
    var structured = false
    var paced = false
    var onGrow: () -> Void = {}
    @EnvironmentObject private var store: LearningStore
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17
    @State private var height: CGFloat = 28
    var body: some View {
        if structured || text.contains("\\") || text.contains("P(") || text.contains("$") {
            LocalMathView(text: text, cards: cards, structured: structured, paced: paced, reduced: reduced, fontSize: fontSize, skip: store.skipToken, colorScheme: colorScheme, height: $height,
                          onPace: { active in if paced { store.pacing = active } }, onGrow: onGrow)
                .frame(maxWidth: .infinity).frame(height: height)
                .transaction { $0.animation = nil }          // 高度由网页的 CSS 动画驱动，SwiftUI 不再叠加动画
        } else { Text(text).reading().textSelection(.enabled) }
    }
}

private struct LocalMathView: UIViewRepresentable {
    let text: String; let cards: Bool; let structured: Bool; let paced: Bool; let reduced: Bool; let fontSize: CGFloat; let skip: Int
    let colorScheme: ColorScheme
    @Binding var height: CGFloat
    var onPace: (Bool) -> Void
    var onGrow: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(height: $height, onPace: onPace, onGrow: onGrow) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mathHeight")
        configuration.userContentController.add(context.coordinator, name: "mathPace")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear; view.scrollView.isScrollEnabled = false; view.scrollView.bounces = false; view.allowsLinkPreview = false
        if let folder = Bundle.main.url(forResource: "WebMath", withExtension: nil) { view.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder) }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        context.coordinator.onPace = onPace; context.coordinator.onGrow = onGrow
        context.coordinator.payload = ["text": text, "cards": cards, "structured": structured, "paced": paced, "reduced": reduced, "fontSize": fontSize, "skip": skip]
        if context.coordinator.ready { context.coordinator.render(view) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mathHeight")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mathPace")
        view.navigationDelegate = nil
        if coordinator.paceActive { DispatchQueue.main.async { coordinator.onPace(false) } }
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var ready = false
        var payload: [String: Any] = [:]
        var paceActive = false
        var onPace: (Bool) -> Void
        var onGrow: () -> Void
        private var lastJSON = ""
        private var height: Binding<CGFloat>
        init(height: Binding<CGFloat>, onPace: @escaping (Bool) -> Void, onGrow: @escaping () -> Void) { self.height = height; self.onPace = onPace; self.onGrow = onGrow }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func render(_ view: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8), json != lastJSON else { return }
            lastJSON = json; view.evaluateJavaScript("window.showMath(\(json))")
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "mathPace", let active = message.body as? Bool {
                paceActive = active
                DispatchQueue.main.async { self.onPace(active) }
                return
            }
            guard message.name == "mathHeight", let value = message.body as? NSNumber else { return }
            let next = min(10000, max(28, CGFloat(truncating: value).rounded(.up)))
            if abs(height.wrappedValue - next) > 0.5 {
                DispatchQueue.main.async { self.height.wrappedValue = next; self.onGrow() }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    }
}
