import PhotosUI
import SwiftUI
import TetherCore
import UIKit
import UniformTypeIdentifiers

struct SessionView: View {
    @Bindable var store: ClientStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.reconnecting || store.offline {
                HStack(spacing: 8) {
                    Image(systemName: store.reconnecting ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(store.reconnecting ? Color.tether.warning : Color.tether.danger)
                        .symbolEffect(.pulse, options: .repeating, isActive: store.reconnecting && !reduceMotion)
                    Text(store.reconnecting ? "Reconnecting…" : (store.statusMessage ?? "Connection lost. Reconnecting…"))
                        .font(TetherType.footnote)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            TabView(selection: $store.sessionTab) {
                FilesView(store: store)
                    .tag(0)
                    .tabItem { Label(L10n.files, systemImage: "folder.fill") }
                TerminalScreen(store: store)
                    .tag(1)
                    .tabItem { Label(L10n.terminal, systemImage: "terminal") }
                    .badge(store.agentProgram != nil && !store.agentExited ? "Live" : nil)
                TransfersView(store: store)
                    .tag(2)
                    .tabItem { Label(L10n.transfers, systemImage: "arrow.up.arrow.down.circle") }
            }
        }
        .animation(TetherMotion.spring(reduceMotion), value: store.reconnecting || store.offline)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .animation(TetherMotion.fade(reduceMotion), value: store.path)
            .animation(TetherMotion.fade(reduceMotion), value: store.grid)
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
        .alert("Saved", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notice ?? "")
        }
        .alert(
            store.largeFileWillPreview
                ? "Preview \(Format.bytes(store.pendingLarge?.size ?? 0))?"
                : L10n.downloadConfirm(Format.bytes(store.pendingLarge?.size ?? 0)),
            isPresented: Binding(
                get: { store.pendingLarge != nil },
                set: { if !$0 { store.pendingLarge = nil } }
            )
        ) {
            Button(store.largeFileWillPreview ? "Preview" : "Download") { Task { await store.confirmLargeDownload() } }
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
        if store.path != "/" {
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
                        .minimumScaleFactor(0.7)
                        .truncationMode(.tail)
                }
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if store.path != "/" {
                Button("Back", systemImage: "chevron.left") { Task { await store.goUp() } }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(store.selecting ? "Done" : "Select") {
                store.selecting.toggle()
                if !store.selecting { store.selection.removeAll() }
            }
            if store.selecting {
                Button("Download", systemImage: "arrow.down.circle") {
                    store.downloadSelection()
                }
                .disabled(store.selection.isEmpty)
            }
            Menu {
                Button(store.grid ? "List" : "Icons", systemImage: store.grid ? "list.bullet" : "square.grid.2x2") {
                    store.grid.toggle()
                }
                Picker("Sort", selection: $store.sort) {
                    ForEach(FileSort.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Divider()
                Button(L10n.settings) { showSettings = true }
                Button("Disconnect") { store.disconnect() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .sensoryFeedback(.selection, trigger: store.grid)
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
                if store.selecting {
                    Image(systemName: store.selection.contains(entry.name) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(store.selection.contains(entry.name) ? Color.tether.accent : Color.secondary)
                        .frame(width: 28, height: 44)
                }
                FileArtwork(store: store, entry: entry, side: 40)
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
                Spacer(minLength: 8)
                if let transfer = store.transfers.first(where: { $0.name == entry.name && $0.state == .active }) {
                    ProgressView(value: transfer.fraction)
                        .frame(width: 28, height: 28)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityLabel(accessibilityText)
        .swipeActions(edge: .leading) {
            Button("Download") { store.download(entry, preview: false) }
                .tint(Color.tether.accent)
        }
        .contextMenu {
            Button("Get Info") { store.showInfo(entry) }
            if entry.kind != .dir {
                Button("Preview") { store.download(entry, preview: true) }
            }
            Button("Download") { store.download(entry, preview: false) }
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
    @Bindable var store: ClientStore
    var entry: FileEntry

    private var selected: Bool { store.selection.contains(entry.name) }

    var body: some View {
        Button {
            Task { await store.open(entry) }
        } label: {
            VStack(spacing: 8) {
                FileArtwork(store: store, entry: entry, side: nil)
                    .overlay(alignment: .topTrailing) {
                        if store.selecting {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected ? Color.tether.accent : Color.secondary)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(6)
                        }
                    }
                Text(entry.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Get Info") { store.showInfo(entry) }
            if entry.kind != .dir {
                Button("Preview") { store.download(entry, preview: true) }
            }
            Button("Download") { store.download(entry, preview: false) }
        }
    }
}

struct FileArtwork: View {
    @Bindable var store: ClientStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var entry: FileEntry
    /// Fixed side length for list rows. Nil fills a square cell in the icon grid.
    var side: CGFloat?
    @State private var image: Image?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side == 40 ? 8 : 10, style: .continuous)
        Color(.secondarySystemGroupedBackground)
            .modifier(ArtworkFrame(side: side))
            .overlay {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: Format.symbol(for: entry))
                        .font(side == 40 ? .title2 : .title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(entry.kind == .dir ? Color.tether.accentText : Color.primary)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.quaternary, lineWidth: 1)
            }
            .task(id: taskID) {
                image = nil
                guard entry.kind != .dir else { return }
                guard let data = await store.thumbnail(for: entry), let uiImage = UIImage(data: data) else { return }
                withAnimation(TetherMotion.fade(reduceMotion)) {
                    image = Image(uiImage: uiImage)
                }
            }
    }

    private var taskID: String { "\(store.path)/\(entry.name)/\(entry.size)/\(entry.mtime)" }
}

private struct ArtworkFrame: ViewModifier {
    var side: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let side {
            content.frame(width: side, height: side)
        } else {
            content.aspectRatio(1, contentMode: .fit)
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
                if let typeName = typeDescription {
                    LabeledContent("Type", value: typeName)
                }
                if !fileExtension.isEmpty {
                    LabeledContent("Extension", value: fileExtension)
                }
                LabeledContent("Size", value: Format.bytes(info.entry.size))
                LabeledContent("Exact size", value: Format.exactBytes(info.entry.size))
                if info.entry.kind == .dir, let count = info.entry.childCount {
                    LabeledContent("Contents", value: "\(count) \(count == 1 ? "item" : "items")")
                }
                if let created = info.entry.created {
                    LabeledContent("Created", value: Format.when(Date(timeIntervalSince1970: created), includeTime: true))
                }
                LabeledContent("Modified", value: Format.when(info.entry.modified, includeTime: true))
                LabeledContent("Access", value: info.writable ? "Can add files" : "Read only")
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

    private var fileExtension: String {
        (info.entry.name as NSString).pathExtension
    }

    private var typeDescription: String? {
        guard let uti = info.entry.uti, let type = UTType(uti) else { return info.entry.uti }
        let title = type.localizedDescription ?? uti
        if title.caseInsensitiveCompare(Format.kind(info.entry)) == .orderedSame { return uti }
        return title
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
