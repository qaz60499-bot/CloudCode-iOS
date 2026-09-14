import SwiftUI
import UIKit
import WebKit

private let chatGPTURL = URL(string: "https://chatgpt.com/")!
private let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

@main
struct ChatGPTWebCompatApp: App {
    var body: some Scene {
        WindowGroup {
            ChatGPTWebContainer()
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

private final class WebHostView: UIView {
    let webView: WKWebView
    private let overlay = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let safariButton = UIButton(type: .system)
    var onRetry: (() -> Void)?
    var onOpenSafari: (() -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)

        backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .systemBackground
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        overlay.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label
        statusLabel.text = "正在加载 ChatGPT…"
        overlay.addSubview(statusLabel)

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重新加载", for: .normal)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        overlay.addSubview(retryButton)

        safariButton.translatesAutoresizingMaskIntoConstraints = false
        safariButton.setTitle("在 Safari 中打开", for: .normal)
        safariButton.isHidden = true
        safariButton.addTarget(self, action: #selector(safariTapped), for: .touchUpInside)
        overlay.addSubview(safariButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -58),
            statusLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -28),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 18),
            retryButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            safariButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            safariButton.topAnchor.constraint(equalTo: retryButton.bottomAnchor, constant: 10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showLoading(_ message: String) {
        overlay.isHidden = false
        spinner.isHidden = false
        if !spinner.isAnimating { spinner.startAnimating() }
        statusLabel.text = message
        retryButton.isHidden = true
        safariButton.isHidden = true
    }

    func showWebContent() {
        spinner.stopAnimating()
        overlay.isHidden = true
    }

    func showFailure(_ message: String) {
        overlay.isHidden = false
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        retryButton.isHidden = false
        safariButton.isHidden = false
    }

    @objc private func retryTapped() {
        onRetry?()
    }

    @objc private func safariTapped() {
        onOpenSafari?()
    }
}

private struct ChatGPTWebContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WebHostView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            configuration.limitsNavigationsToAppBoundDomains = false
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        let host = WebHostView(webView: webView)
        context.coordinator.hostView = host
        context.coordinator.webView = webView
        host.onRetry = { [weak coordinator = context.coordinator] in
            coordinator?.loadChatGPT(reason: "manual-retry")
        }
        host.onOpenSafari = {
            UIApplication.shared.open(chatGPTURL, options: [:], completionHandler: nil)
        }

        context.coordinator.loadChatGPT(reason: "initial")
        return host
    }

    func updateUIView(_ uiView: WebHostView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        weak var hostView: WebHostView?
        private var navigationSerial = 0
        private var blankProbeGeneration = 0

        func loadChatGPT(reason: String) {
            guard let webView else { return }
            navigationSerial += 1
            blankProbeGeneration += 1
            hostView?.showLoading("正在加载 ChatGPT…")
            NSLog("[ChatGPTWebCompat] load reason=%@ serial=%d url=%@", reason, navigationSerial, chatGPTURL.absoluteString)
            let request = URLRequest(url: chatGPTURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
            webView.load(request)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            NSLog("[ChatGPTWebCompat] didStart url=%@", webView.url?.absoluteString ?? "nil")
            hostView?.showLoading("正在连接 ChatGPT…")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            NSLog("[ChatGPTWebCompat] didCommit url=%@", webView.url?.absoluteString ?? "nil")
            hostView?.showLoading("ChatGPT 已连接，正在渲染页面…")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("[ChatGPTWebCompat] didFinish url=%@ title=%@", webView.url?.absoluteString ?? "nil", webView.title ?? "")
            blankProbeGeneration += 1
            let generation = blankProbeGeneration
            probeDOM(webView, generation: generation, attempt: 1)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(stage: "navigation", error: error, webView: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(stage: "provisional", error: error, webView: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("[ChatGPTWebCompat] webContentProcessDidTerminate url=%@", webView.url?.absoluteString ?? "nil")
            hostView?.showFailure("ChatGPT 网页进程已停止。\n可以重新加载，或直接在 Safari 中打开。")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let response = navigationResponse.response as? HTTPURLResponse {
                NSLog("[ChatGPTWebCompat] response status=%d url=%@ mime=%@", response.statusCode, response.url?.absoluteString ?? "nil", response.mimeType ?? "")
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                NSLog("[ChatGPTWebCompat] popup->same-webview url=%@", url.absoluteString)
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", "blob"].contains(scheme) {
                NSLog("[ChatGPTWebCompat] external-scheme scheme=%@ url=%@", scheme, url.absoluteString)
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func reportNavigationFailure(stage: String, error: Error, webView: WKWebView) {
            let nsError = error as NSError
            NSLog("[ChatGPTWebCompat] failed stage=%@ domain=%@ code=%d message=%@ url=%@", stage, nsError.domain, nsError.code, nsError.localizedDescription, webView.url?.absoluteString ?? "nil")
            hostView?.showFailure("ChatGPT 网页加载失败。\n\(nsError.domain) (\(nsError.code))\n\(nsError.localizedDescription)")
        }

        private func probeDOM(_ webView: WKWebView, generation: Int, attempt: Int) {
            guard generation == blankProbeGeneration else { return }
            let script = """
            (() => {
              try {
                const body = document.body;
                const root = document.documentElement;
                const text = body ? (body.innerText || '') : '';
                const style = body ? getComputedStyle(body) : null;
                return JSON.stringify({
                  href: location.href,
                  title: document.title || '',
                  readyState: document.readyState,
                  textLength: text.trim().length,
                  htmlLength: root ? root.outerHTML.length : 0,
                  childCount: body ? body.children.length : 0,
                  bodyDisplay: style ? style.display : '',
                  bodyVisibility: style ? style.visibility : '',
                  userAgent: navigator.userAgent
                });
              } catch (error) {
                return JSON.stringify({ probeError: String(error) });
              }
            })()
            """

            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
                guard let self, let webView, generation == self.blankProbeGeneration else { return }
                if let error {
                    let nsError = error as NSError
                    NSLog("[ChatGPTWebCompat] domProbe attempt=%d jsError=%@/%d %@", attempt, nsError.domain, nsError.code, nsError.localizedDescription)
                    if attempt >= 3 {
                        self.hostView?.showFailure("ChatGPT 页面已连接，但 iOS 16.6 WebKit 无法执行页面脚本。\n可以重新加载，或在 Safari 中打开。")
                    } else {
                        self.scheduleProbe(webView, generation: generation, attempt: attempt + 1)
                    }
                    return
                }

                let raw = result as? String ?? "{}"
                NSLog("[ChatGPTWebCompat] domProbe attempt=%d payload=%@", attempt, raw)
                var textLength = 0
                if let data = raw.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    textLength = (json["textLength"] as? NSNumber)?.intValue ?? 0
                }

                if textLength >= 20 {
                    self.hostView?.showWebContent()
                    return
                }

                if attempt >= 3 {
                    self.hostView?.showFailure("ChatGPT 已完成网络加载，但页面没有渲染出可见内容。\n这通常表示当前 iOS 16.6 WebKit 与最新网页不兼容。\n可以重新加载，或在 Safari 中打开。")
                } else {
                    self.hostView?.showLoading("ChatGPT 已连接，等待网页内容渲染…")
                    self.scheduleProbe(webView, generation: generation, attempt: attempt + 1)
                }
            }
        }

        private func scheduleProbe(_ webView: WKWebView, generation: Int, attempt: Int) {
            let delay: TimeInterval = attempt == 2 ? 3 : 5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView, generation == self.blankProbeGeneration else { return }
                self.probeDOM(webView, generation: generation, attempt: attempt)
            }
        }
    }
}
