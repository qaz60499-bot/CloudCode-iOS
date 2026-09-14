import SafariServices
import SwiftUI
import UIKit

struct ChatGPTBrowserScreen: View {
    static let chatGPTURL = URL(string: "https://chatgpt.com/")!

    @State private var browserGeneration = 0
    @State private var leftForeground = false

    var body: some View {
        SafariBrowserView(url: Self.chatGPTURL)
            .id(browserGeneration)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            leftForeground = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard leftForeground else { return }
            leftForeground = false
            browserGeneration &+= 1
        }
    }
}

struct SafariBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = .label
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // SFSafariViewController owns the browsing session. Avoid replacing it during
        // SwiftUI updates so login cookies and navigation state remain intact.
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        func safariViewController(
            _ controller: SFSafariViewController,
            didCompleteInitialLoad didLoadSuccessfully: Bool
        ) {
            // Keep the controller alive even when the initial request fails. The system
            // browser can show its own error UI, and recreating it is handled only after
            // the host app actually leaves and re-enters the foreground.
        }
    }
}
