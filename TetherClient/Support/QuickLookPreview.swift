import QuickLook
import SwiftUI

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.item = NamedPreviewItem(url: url, title: title)
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url, title: title) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var item: NamedPreviewItem
        init(url: URL, title: String) { item = NamedPreviewItem(url: url, title: title) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            item
        }
    }
}

final class NamedPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}
