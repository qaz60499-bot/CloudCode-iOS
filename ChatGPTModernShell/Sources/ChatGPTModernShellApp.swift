import SwiftUI
import WebKit

@main
struct ChatGPTModernShellApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserScreen()
        }
    }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var title = "ChatGPT"

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences = preferences

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.keyboardDismissMode = .interactive
        loadHome()
    }

    func loadHome() {
        guard let url = URL(string: "https://chatgpt.com/") else { return }
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    func openCurrentInSafari() {
        guard let url = webView.url else { return }
        UIApplication.shared.open(url)
    }

    private func refreshState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let pageTitle = webView.title, !pageTitle.isEmpty {
            title = pageTitle
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshState()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
            webView.load(URLRequest(url: requestURL))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        switch scheme {
        case "http", "https", "about", "blob", "data":
            decisionHandler(.allow)
        default:
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

struct BrowserView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserScreen: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!model.canGoBack)

                Button(action: model.goForward) {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!model.canGoForward)

                Button(action: model.loadHome) {
                    Image(systemName: "house")
                }

                Spacer()

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }

                Button(action: model.openCurrentInSafari) {
                    Image(systemName: "safari")
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(.ultraThinMaterial)

            Divider()

            BrowserView(model: model)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(uiColor: .systemBackground))
    }
}
