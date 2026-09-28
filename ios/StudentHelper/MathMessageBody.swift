import SwiftUI
import WebKit

struct MathMessageBody: View {
    let text: String
    var cards = true
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 16
    @State private var height: CGFloat = 28
    var body: some View {
        if text.contains("\\") || text.contains("P(") || text.contains("$") {
            LocalMathView(text: text, cards: cards, fontSize: fontSize, height: $height).frame(maxWidth: .infinity).frame(height: height)
        } else { Text(text).reading().textSelection(.enabled) }
    }
}

private struct LocalMathView: UIViewRepresentable {
    let text: String
    let cards: Bool
    let fontSize: CGFloat
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mathHeight")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear; view.scrollView.isScrollEnabled = false; view.allowsLinkPreview = false
        if let folder = Bundle.main.url(forResource: "WebMath", withExtension: nil) { view.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder) }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.payload = ["text": text, "cards": cards, "fontSize": fontSize]
        if context.coordinator.ready { context.coordinator.render(view) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName: "mathHeight"); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var ready = false
        var payload: [String: Any] = [:]
        private var lastJSON = ""
        private var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func render(_ view: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8), json != lastJSON else { return }
            lastJSON = json; view.evaluateJavaScript("window.showMath(\(json))")
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mathHeight", let value = message.body as? NSNumber else { return }
            let next = min(10000, max(28, CGFloat(truncating: value).rounded(.up)))
            if abs(height.wrappedValue - next) > 1 { DispatchQueue.main.async { self.height.wrappedValue = next } }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    }
}
