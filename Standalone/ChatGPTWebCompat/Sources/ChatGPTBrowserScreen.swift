import SafariServices
import SwiftUI
import UIKit

struct ChatGPTBrowserScreen: View {
    static let chatGPTURL = URL(string: "https://chatgpt.com/")!

    var body: some View {
        SafariBrowserView(url: Self.chatGPTURL)
            .ignoresSafeArea()
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
        // Preserve the system browser session across SwiftUI updates.
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        func safariViewController(
            _ controller: SFSafariViewController,
            didCompleteInitialLoad didLoadSuccessfully: Bool
        ) {
            guard !didLoadSuccessfully else { return }
            UIApplication.shared.open(ChatGPTBrowserScreen.chatGPTURL, options: [:], completionHandler: nil)
        }
    }
}
