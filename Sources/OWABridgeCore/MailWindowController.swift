import AppKit
import WebKit

final class MailWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private(set) var userPinned = false
    var onLoginRequired: (() -> Void)?
    var onMailPage: (() -> Void)?
    var onLoadFailed: (() -> Void)?

    private let visibleFrame = NSRect(x: 0, y: 0, width: 1100, height: 780)
    private let parkedFrame = NSRect(x: -16000, y: -16000, width: 1100, height: 780)

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let source = try? ExtractorScript.load() {
            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            configuration.userContentController.addUserScript(userScript)
        } else {
            BridgeLog.error("extractor.js 没有打进应用包")
        }
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: parkedFrame, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        self.webView = webView

        window = NSWindow(
            contentRect: parkedFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Outlook — OWA Bridge"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 600)
        window.contentView = webView
        super.init()
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.orderFrontRegardless()
    }

    func loadOutlook() {
        guard let url = URL(string: "https://outlook.office.com/mail/") else { return }
        webView.load(URLRequest(url: url))
    }

    var isPresented: Bool {
        window.frame.origin.x > -1000 && window.isVisible
    }

    func present(userInitiated: Bool) {
        if userInitiated {
            userPinned = true
        }
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var frame = visibleFrame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func park() {
        userPinned = false
        window.setFrame(parkedFrame, display: false)
        window.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        park()
        return false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if allows(url) {
            decisionHandler(.allow)
        } else {
            BridgeLog.info("已拦截跳转 \(url.host ?? "")")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        if isLogin(url) {
            onLoginRequired?()
            return
        }
        if isMail(url) {
            onMailPage?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLoadFailed?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        onLoadFailed?()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let request = navigationAction.request.url.flatMap({ allows($0) ? navigationAction.request : nil }) {
            webView.load(request)
        }
        return nil
    }

    private func allows(_ url: URL) -> Bool {
        if url.scheme == "about" { return true }
        guard url.scheme == "https" || url.scheme == "http" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        let suffixes = [
            "office.com", "office.net", "office365.com", "microsoft.com", "microsoftonline.com",
            "live.com", "msauth.net", "msftauth.net", "msocdn.com", "sharepoint.com",
            "outlook.com", "windows.net", "azureedge.net", "msecnd.net"
        ]
        return suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private func isLogin(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host == "login.microsoftonline.com" || host == "login.microsoft.com" || host == "login.windows.net" {
            return true
        }
        return host.hasSuffix(".login.microsoftonline.com")
    }

    private func isMail(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let outlook = host == "outlook.office.com" || host == "outlook.office365.com"
        guard outlook else { return false }
        return url.path.contains("/mail") || url.path.hasPrefix("/owa")
    }
}
