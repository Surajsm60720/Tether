import PhotosUI
import SwiftUI
import TetherCore
import UIKit
import UniformTypeIdentifiers

struct SessionView: View {
    @Bindable var store: ClientStore
    @State private var savedMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.reconnecting || store.offline {
                HStack(spacing: 8) {
                    Image(systemName: store.reconnecting ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                        .symbolRenderingMode(.hierarchical)
                    Text(store.reconnecting ? "Reconnecting…" : (store.statusMessage ?? "Connection lost. Reconnecting…"))
                        .font(.footnote)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            TabView(selection: $store.sessionTab) {
                FilesView(store: store)
                    .tag(0)
                    .tabItem { Label(L10n.files, systemImage: "folder.fill") }
                TerminalScreen(store: store)
                    .tag(1)
                    .tabItem { Label(L10n.terminal, systemImage: "terminal") }
                TransfersView(store: store)
                    .tag(2)
                    .tabItem { Label(L10n.transfers, systemImage: "arrow.up.arrow.down.circle") }
            }
        }
        .sheet(item: $store.preview) { item in
            NavigationStack {
                QuickLookPreview(url: item.url, title: item.title)
                    .ignoresSafeArea()
                    .navigationTitle(item.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            ShareLink(item: item.url)
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { store.preview = nil }
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button("Save to Files") {
                                if (try? store.saveToDocuments(item.url)) != nil {
                                    savedMessage = "Saved \(item.title) to the Files app."
                                }
                            }
                        }
                    }
            }
        }
        .alert("Saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(savedMessage ?? "")
        }
    }
}

struct FilesView: View {
    @Bindable var store: ClientStore
    @State private var picker: PhotosPickerItem?
    @State private var importing = false
    @State private var savedMessage: String?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.loading && store.entries.isEmpty {
                    skeleton
                } else if store.sortedEntries.isEmpty {
                    ContentUnavailableView(L10n.filesEmpty, systemImage: "folder")
                } else if store.grid {
                    grid
                } else {
                    listing
                }
            }
            .navigationTitle(store.folderTitle)
            .navigationBarTitleDisplayMode(store.path == "/" ? .large : .inline)
            .searchable(text: $store.searchText, prompt: "Filter")
            .toolbar { toolbar }
            .refreshable { try? await store.refresh() }
        }
        .sheet(item: $store.fileInfo) { info in
            NavigationStack {
                FileInfoView(info: info)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { store.fileInfo = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(store: store) }
        }
        .alert("Saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(savedMessage ?? "")
        }
        .alert(L10n.downloadConfirm(Format.bytes(store.pendingLarge?.size ?? 0)), isPresented: Binding(
            get: { store.pendingLarge != nil },
            set: { if !$0 { store.pendingLarge = nil } }
        )) {
            Button("Download") { Task { await store.confirmLargeDownload() } }
            Button("Cancel", role: .cancel) { store.pendingLarge = nil }
        }
        .alert(L10n.readOnly, isPresented: $store.readOnlyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This folder is read-only. Choose a folder that allows uploads.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                let accessing = url.startAccessingSecurityScopedResource()
                Task {
                    await store.upload(url: url)
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .onChange(of: picker) { _, item in
            guard let item else { return }
            Task {
                if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                    await store.upload(url: picked.url)
                }
                picker = nil
            }
        }
    }

    private var listing: some View {
        List(store.sortedEntries) { entry in
            FileRow(store: store, entry: entry)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                ForEach(store.sortedEntries) { entry in
                    FileGridItem(store: store, entry: entry)
                }
            }
            .padding(16)
        }
    }

    private var skeleton: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary).frame(width: 40, height: 40)
                    VStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 120, height: 10)
                    }
                }
                .redacted(reason: .placeholder)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(store.ancestors, id: \.self) { ancestor in
                    Button(ancestor == "/" ? store.hostName : ancestor) {
                        Task { await store.go(to: ancestor) }
                    }
                }
            } label: {
                Text(store.folderTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if store.path != "/" {
                Button("Back", systemImage: "chevron.left") { Task { await store.goUp() } }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button(store.grid ? "List" : "Icons", systemImage: store.grid ? "list.bullet" : "square.grid.2x2") {
                    store.grid.toggle()
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                Picker("Sort", selection: $store.sort) {
                    ForEach(FileSort.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                if store.demoMode {
                    Text(L10n.demo)
                }
                Divider()
                Button(L10n.settings) { showSettings = true }
                Button("Disconnect") { store.disconnect() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            Menu {
                PhotosPicker(selection: $picker, matching: .any(of: [.images, .videos])) {
                    Label("Photos", systemImage: "photo")
                }
                Button("Files", systemImage: "doc") { importing = true }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Upload")
        }
    }

}

struct FileRow: View {
    @Bindable var store: ClientStore
    var entry: FileEntry

    var body: some View {
        Button {
            Task { await store.open(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Format.symbol(for: entry))
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(entry.kind == .dir ? Color.tether.accentText : Color.primary)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Format.subtitle(entry))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if let transfer = store.transfers.first(where: { $0.name == entry.name && $0.state == .active }) {
                    ProgressView(value: transfer.fraction)
                        .frame(width: 28, height: 28)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityLabel(accessibilityText)
        .swipeActions(edge: .leading) {
            if entry.kind != .dir {
                Button("Download") { store.download(entry, preview: false) }
                    .tint(Color.tether.accent)
            }
        }
        .contextMenu {
            Button("Get Info") { store.showInfo(entry) }
            if entry.kind != .dir {
                Button("Preview") { store.download(entry, preview: true) }
                Button("Download") { store.download(entry, preview: false) }
            }
        }
    }

    private var accessibilityText: String {
        if entry.kind == .dir {
            return "\(entry.name), folder, \(entry.childCount.map(String.init) ?? "") items"
        }
        return "\(entry.name), \(Format.kind(entry)), \(Format.bytes(entry.size)), modified \(Format.when(entry.modified, includeTime: true))"
    }
}

struct FileGridItem: View {
    var store: ClientStore
    var entry: FileEntry
    @State private var image: Image?

    var body: some View {
        Button {
            Task { await store.open(entry) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: Format.symbol(for: entry))
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .task {
            guard entry.kind != .dir, let data = await store.thumbnail(for: entry), let uiImage = UIImage(data: data) else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                image = Image(uiImage: uiImage)
            }
        }
    }
}

struct FileInfoView: View {
    var info: FileInfo

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: info.entry.name)
                LabeledContent("Kind", value: Format.kind(info.entry))
                LabeledContent("Size", value: info.entry.kind == .dir ? (info.entry.childCount.map { "\($0) items" } ?? "Folder") : Format.bytes(info.entry.size))
                LabeledContent("Modified", value: Format.when(info.entry.modified, includeTime: true))
            }
            Section {
                Text(info.path)
                    .font(.body)
                    .textSelection(.enabled)
            } header: {
                Text("Where")
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedFile(url: destination)
        }
    }
}
