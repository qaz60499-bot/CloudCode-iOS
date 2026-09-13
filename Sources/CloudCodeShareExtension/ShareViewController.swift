import UIKit
import UniformTypeIdentifiers
import CloudCodeCore

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在保存到 Cloud Code…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.startAnimating()

        view.addSubview(statusLabel)
        view.addSubview(activity)
        NSLayoutConstraint.activate([
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -18),
            statusLabel.topAnchor.constraint(equalTo: activity.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { @MainActor in
            await receiveSharedItems()
        }
    }

    @MainActor
    private func receiveSharedItems() async {
        do {
            let store = try CloudCodeShareInboxStore.appGroupStore()
            let providers = extensionContext?.inputItems
                .compactMap { $0 as? NSExtensionItem }
                .flatMap { $0.attachments ?? [] } ?? []
            guard !providers.isEmpty else {
                throw ShareExtensionError.noSupportedItems
            }

            var saved = 0
            var failures = 0
            for provider in providers.prefix(10) {
                do {
                    if try await persist(provider: provider, store: store) {
                        saved += 1
                    } else {
                        failures += 1
                    }
                } catch {
                    failures += 1
                }
            }
            guard saved > 0 else {
                throw ShareExtensionError.noSupportedItems
            }

            activity.stopAnimating()
            statusLabel.text = failures == 0
                ? "已保存 \(saved) 项到 Cloud Code"
                : "已保存 \(saved) 项；\(failures) 项未能导入"
            try? await Task.sleep(nanoseconds: 450_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            activity.stopAnimating()
            statusLabel.text = "无法保存到 Cloud Code"
            try? await Task.sleep(nanoseconds: 650_000_000)
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func persist(provider: NSItemProvider, store: CloudCodeShareInboxStore) async throws -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if try await persistFileURL(provider: provider, store: store) {
                return true
            }
        }

        if let typeIdentifier = preferredFileTypeIdentifier(provider) {
            return try await persistFileRepresentation(
                provider: provider,
                typeIdentifier: typeIdentifier,
                store: store
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try await loadURL(provider: provider, typeIdentifier: UTType.url.identifier) {
                if url.isFileURL {
                    return try storeFileURL(url, provider: provider, typeIdentifier: UTType.fileURL.identifier, store: store)
                }
                let text = url.absoluteString + "\n"
                _ = try store.enqueueData(
                    Data(text.utf8),
                    originalFilename: "Shared URL.txt",
                    mimeType: "text/plain",
                    typeIdentifier: UTType.url.identifier,
                    sourceType: "url"
                )
                return true
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
           let text = try await loadText(provider: provider) {
            _ = try store.enqueueData(
                Data(text.utf8),
                originalFilename: provider.suggestedName.map { safeFilename($0, fallbackExtension: "txt") } ?? "Shared Text.txt",
                mimeType: "text/plain",
                typeIdentifier: UTType.text.identifier,
                sourceType: "text"
            )
            return true
        }

        return false
    }

    private func preferredFileTypeIdentifier(_ provider: NSItemProvider) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if type.conforms(to: .fileURL) || type.conforms(to: .url) || type.conforms(to: .text) {
                continue
            }
            if type.conforms(to: .data) || type.conforms(to: .image) {
                return identifier
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return UTType.image.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            return UTType.data.identifier
        }
        return nil
    }

    private func persistFileRepresentation(
        provider: NSItemProvider,
        typeIdentifier: String,
        store: CloudCodeShareInboxStore
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    let type = UTType(typeIdentifier)
                    let fallbackExtension = type?.preferredFilenameExtension ?? url.pathExtension
                    let suggested = provider.suggestedName ?? url.lastPathComponent
                    let filename = safeFilename(suggested, fallbackExtension: fallbackExtension)
                    _ = try store.enqueueFile(
                        from: url,
                        originalFilename: filename,
                        mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                        typeIdentifier: typeIdentifier,
                        sourceType: type?.conforms(to: .image) == true ? "image" : "file"
                    )
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func persistFileURL(provider: NSItemProvider, store: CloudCodeShareInboxStore) async throws -> Bool {
        guard let url = try await loadURL(provider: provider, typeIdentifier: UTType.fileURL.identifier), url.isFileURL else {
            return false
        }
        let inferred = UTType(filenameExtension: url.pathExtension)
        return try storeFileURL(
            url,
            provider: provider,
            typeIdentifier: inferred?.identifier ?? UTType.data.identifier,
            store: store
        )
    }

    private func storeFileURL(
        _ url: URL,
        provider: NSItemProvider,
        typeIdentifier: String,
        store: CloudCodeShareInboxStore
    ) throws -> Bool {
        let gainedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if gainedSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        let type = UTType(typeIdentifier)
        let filename = safeFilename(
            provider.suggestedName ?? url.lastPathComponent,
            fallbackExtension: type?.preferredFilenameExtension ?? url.pathExtension
        )
        _ = try store.enqueueFile(
            from: url,
            originalFilename: filename,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            typeIdentifier: typeIdentifier,
            sourceType: type?.conforms(to: .image) == true ? "image" : "file"
        )
        return true
    }

    private func loadURL(provider: NSItemProvider, typeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let text = item as? NSAttributedString {
                    continuation.resume(returning: text.string)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func safeFilename(_ name: String, fallbackExtension: String?) -> String {
        var component = URL(fileURLWithPath: name).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if component.isEmpty || component == "." || component == ".." {
            component = "attachment"
        }
        if URL(fileURLWithPath: component).pathExtension.isEmpty,
           let fallbackExtension,
           !fallbackExtension.isEmpty {
            let ext = fallbackExtension.filter { $0.isLetter || $0.isNumber }.lowercased()
            if !ext.isEmpty { component += ".\(String(ext.prefix(16)))" }
        }
        return String(component.prefix(180))
    }
}

private enum ShareExtensionError: LocalizedError {
    case noSupportedItems

    var errorDescription: String? {
        switch self {
        case .noSupportedItems:
            return "No supported share items were provided."
        }
    }
}
