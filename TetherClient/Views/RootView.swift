import SwiftUI
import TetherCore
import UIKit

struct RootView: View {
    @Bindable var store: ClientStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.revoked {
                revoked
            } else if store.connected {
                SessionView(store: store)
            } else {
                HostsView(store: store)
            }
        }
        .fullScreenCover(isPresented: $store.showPrimer) {
            PrimerView(store: store)
        }
        .sheet(isPresented: $store.showPairing) {
            PairView(store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.sceneBecameActive() }
            if phase == .background { _ = store.beginBackgroundTaskIfNeeded() }
        }
    }

    private var revoked: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.tether.danger)
            Text("This Mac removed your iPhone. Pair again to reconnect.")
                .font(.body)
                .multilineTextAlignment(.center)
            Button("Pair again") {
                store.revoked = false
                store.showPairing = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tether.accent)
        }
        .padding(24)
    }
}

struct PrimerView: View {
    @Bindable var store: ClientStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "wifi")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.tether.accentText)
            Text(L10n.primerTitle)
                .font(.title2)
            Text(L10n.primerBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(L10n.continueButton) { store.acceptPrimer() }
                .buttonStyle(.borderedProminent)
                .tint(Color.tether.accent)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .interactiveDismissDisabled()
    }
}

struct HostsView: View {
    @Bindable var store: ClientStore

    var body: some View {
        NavigationStack {
            Group {
                if store.discovered.isEmpty && store.paired.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle(L10n.hostsTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView(store: store)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(L10n.settings)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.pair) { store.showPairing = true }
                }
            }
            .refreshable {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.refreshBrowser()
            }
        }
    }

    private var list: some View {
        List {
            if store.localNetworkOff {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(store.discoveryDetail ?? L10n.localNetworkOff, systemImage: "wifi.slash")
                            .font(.subheadline)
                        Button(L10n.openSettings) { store.openSettings() }
                    }
                    .padding(.vertical, 4)
                }
            }
            if !unpairedNearby.isEmpty {
                Section(L10n.nearby) {
                    ForEach(unpairedNearby) { host in
                        HStack {
                            Label(host.name, systemImage: "laptopcomputer")
                            Spacer()
                            Button(L10n.pair) { store.showPairing = true }
                                .buttonStyle(.bordered)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            if !store.paired.isEmpty {
                Section(L10n.paired) {
                    ForEach(store.paired) { host in
                        Button {
                            Task { await store.connect(host) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if store.connectingName == host.name {
                                        Text(L10n.connecting)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        StatusDot(title: status(for: host), color: color(for: host))
                                    }
                                }
                                Spacer()
                                if store.connectingName == host.name {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(store.connectingName != nil)
                        .frame(minHeight: 44)
                        .swipeActions {
                            Button("Forget", role: .destructive) { store.forget(host) }
                        }
                    }
                }
            }
            if let message = store.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            if store.localNetworkOff {
                Text(store.discoveryDetail ?? L10n.localNetworkOff)
                    .font(.body)
                    .multilineTextAlignment(.center)
                Button(L10n.openSettings) { store.openSettings() }
            } else {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 48))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.tether.accentText)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "iphone")
                            .font(.title2)
                    }
                Text(L10n.hostsEmptyTitle)
                    .font(.title2)
                Text(L10n.hostsEmptyBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L10n.pairWithCode) { store.showPairing = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unpairedNearby: [DiscoveredHost] {
        store.discovered.filter { host in
            !store.paired.contains { host.matches(savedHostId: $0.id) }
        }
    }

    private func status(for host: PairedItem) -> String {
        store.discovered.contains { $0.matches(savedHostId: host.id) } ? "Available" : "Not found"
    }

    private func color(for host: PairedItem) -> Color {
        store.discovered.contains { $0.matches(savedHostId: host.id) } ? Color.tether.success : Color.secondary
    }
}

struct StatusDot: View {
    var title: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

struct PairView: View {
    @Bindable var store: ClientStore
    @Environment(\.dismiss) private var dismiss
    @State private var manual = false
    @State private var code = ""
    @State private var chosenID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch store.pairPhase {
                case .connecting:
                    ProgressView()
                    Text(L10n.connecting).font(.headline)
                case .waiting:
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.tether.warning)
                    Text(L10n.pairWaiting)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Button("Cancel") { dismiss() }
                case let .success(name):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.tether.success)
                    Text(L10n.pairSuccess(name))
                        .font(.title2)
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Color.tether.danger)
                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                    Button("Try again") { store.pairPhase = .scanning }
                case .scanning:
                    scanner
                }
            }
            .padding(16)
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            store.pairPhase = .scanning
            store.refreshBrowser()
        }
        .sensoryFeedback(.success, trigger: successName)
    }

    private var successName: String {
        if case let .success(name) = store.pairPhase { return name }
        return ""
    }

    @ViewBuilder
    private var scanner: some View {
        if manual || !UIImagePickerController.isSourceTypeAvailable(.camera) {
            manualEntry
        } else {
            ZStack {
                QRScanner { value in
                    guard let payload = try? PairingPayload.parseQR(value) else {
                        store.pairPhase = .failed("That pairing code isn't valid.")
                        return
                    }
                    Task { await store.pair(payload) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 3)
                    .frame(width: 220, height: 220)
                    .allowsHitTesting(false)
            }
            .frame(height: 360)
            Text(L10n.scanTitle)
                .font(.headline)
            Button(L10n.enterCode) { manual = true }
        }
    }

    private var manualEntry: some View {
        VStack(spacing: 16) {
            if store.discovered.count > 1 {
                Picker("Mac", selection: Binding(
                    get: { chosenID ?? store.discovered.first?.hostId ?? "" },
                    set: { chosenID = $0 }
                )) {
                    ForEach(store.discovered) { host in
                        Text(host.name).tag(host.hostId)
                    }
                }
            }
            TextField("XXXX-XXXX-XXXX-XXXX", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.title3, design: .monospaced))
                .multilineTextAlignment(.center)
                .onChange(of: code) { _, newValue in
                    code = formatCode(newValue)
                }
            Button("Pair") {
                guard let host = selectedHost else { return }
                Task { await store.pair(code: code, host: host) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tether.accent)
            .disabled(cleanCode.count != 16 || selectedHost == nil)
            if store.discovered.isEmpty {
                Text(L10n.hostsEmptyBody)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var selectedHost: DiscoveredHost? {
        if let chosenID, let host = store.discovered.first(where: { $0.hostId == chosenID }) { return host }
        return store.discovered.first
    }

    private var cleanCode: String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private func formatCode(_ raw: String) -> String {
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        var groups: [String] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex && groups.count < 4 {
            let next = cleaned.index(index, offsetBy: 4, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            groups.append(String(cleaned[index..<next]))
            index = next
        }
        return groups.joined(separator: "-")
    }
}

#Preview("Hosts") {
    HostsView(store: PreviewClient.store)
}

#Preview("Primer") {
    PrimerView(store: PreviewClient.store)
}
