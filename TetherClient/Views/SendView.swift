import PhotosUI
import SwiftUI
import TetherCore
import UniformTypeIdentifiers

struct SendView: View {
    @Bindable var store: ClientStore
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Send to this Mac", systemImage: "tray.and.arrow.up")
            } description: {
                Text("Choose photos or any files. They land in the Inbox on your Mac.")
            } actions: {
                PhotosPicker(
                    selection: $photoItems,
                    matching: .any(of: [.images, .videos]),
                    photoLibrary: .shared()
                ) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                // Neutral keeps a mid-gray accent fill so the system white label stays readable.
                .tint(SendAccent.prominentFill)

                Button {
                    importing = true
                } label: {
                    Label("Files", systemImage: "doc")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.bordered)
                .tint(SendAccent.prominentFill)
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.item, .audio, .movie, .image, .data],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    Task {
                        for url in urls {
                            await store.sendToInbox(url: url)
                        }
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                            await store.sendToInbox(url: picked.url)
                        }
                    }
                    photoItems = []
                }
            }
        }
    }
}

/// Prominent Send buttons need a fill dark enough that the system white label stays readable.
@MainActor
private enum SendAccent {
    static var prominentFill: Color {
        let preset = AppearancePreferences.shared.preset
        if preset.id == "neutral" {
            return Color(AppearancePresets.neutralProminentFill)
        }
        let accent = preset.accent
        let luminance = 0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b
        if luminance > 0.75 {
            return Color(AppearancePresets.neutralProminentFill)
        }
        return Color(accent)
    }
}
