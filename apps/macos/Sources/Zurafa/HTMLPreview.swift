import SwiftUI
import WebKit

/// Renders an agent-written HTML page offline. Elements call `window.webkit.messageHandlers.zurafa.postMessage(text)`
/// to drop a follow-up question into the pane that opened the preview, without pressing Enter.
struct HTMLPreview: NSViewRepresentable {
    let url: URL
    let pane: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "zurafa")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.pane = pane
        Self.withRules { rules in
            if let rules { config.userContentController.add(rules) }
            // Read access stops at the page's folder, so it can load bundled scripts beside it but not the rest of the disk.
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.pane = pane }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "zurafa")
    }

    /// Blocks every request that is not a local file or data URL, so a page cannot reach the network.
    private static let rulesJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^(file|data|about):"},"action":{"type":"ignore-previous-rules"}}]
    """
    @MainActor private static var rules: WKContentRuleList?

    @MainActor private static func withRules(_ body: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let rules { return body(rules) }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "zurafa-offline", encodedContentRuleList: rulesJSON) { list, _ in
            Task { @MainActor in
                rules = list
                body(list)
            }
        }
    }

    /// Single line, no control characters (no Enter, no escape sequences), bounded length.
    static func promptText(_ raw: String) -> String? {
        let cleaned = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return cleaned.isEmpty ? nil : String(cleaned.prefix(500))
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var pane: String?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let pane, let raw = message.body as? String, let text = HTMLPreview.promptText(raw) else { return }
            MainActor.assumeIsolated { TerminalStore.shared.paste(text, into: pane) }
        }

        // Only the page itself may load in the frame; links never navigate away.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}
