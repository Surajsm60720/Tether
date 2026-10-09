import TetherCore
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private var finishing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "Preparing to send…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.startAnimating()
        view.addSubview(statusLabel)
        view.addSubview(activity)
        NSLayoutConstraint.activate([
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: activity.bottomAnchor, constant: 16),
        ])
        Task { await prepareAndHandoff() }
    }

    private func prepareAndHandoff() async {
        guard !finishing else { return }
        do {
            let urls = try await loadSharedFileURLs()
            guard !urls.isEmpty else {
                statusLabel.text = "Nothing to send."
                try? await Task.sleep(for: .seconds(1.2))
                close()
                return
            }
            try ShareInboxQueue.enqueue(fileURLs: urls)
            statusLabel.text = "Open Tether to finish sending."
            activity.stopAnimating()
            if let url = URL(string: "tether://send") {
                _ = openURL(url)
            }
            try? await Task.sleep(for: .seconds(0.8))
            close()
        } catch {
            statusLabel.text = "Couldn't prepare those files."
            activity.stopAnimating()
            try? await Task.sleep(for: .seconds(1.5))
            close()
        }
    }

    private func loadSharedFileURLs() async throws -> [URL] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return [] }
        var urls: [URL] = []
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = try await loadFileURL(from: provider) {
                    urls.append(url)
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let url = try await loadImageFile(from: provider) {
                    urls.append(url)
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
                   let url = try await loadMovieFile(from: provider) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadImageFile(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tether-share-\(UUID().uuidString).jpg")
                if let url = item as? URL {
                    do {
                        try FileManager.default.copyItem(at: url, to: temp)
                        continuation.resume(returning: temp)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                    do {
                        try data.write(to: temp)
                        continuation.resume(returning: temp)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private func loadMovieFile(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return true
            }
            // Share extensions don't always see UIApplication; try the selector path.
            if current.responds(to: Selector(("openURL:"))), current != self {
                _ = current.perform(Selector(("openURL:")), with: url)
                return true
            }
            responder = current.next
        }
        extensionContext?.open(url, completionHandler: nil)
        return true
    }

    private func close() {
        finishing = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}
