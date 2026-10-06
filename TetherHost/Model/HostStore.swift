import AppKit
import CryptoKit
import Foundation
import Observation
import QuickLookThumbnailing
import ServiceManagement
import SwiftData
import SwiftUI
import TetherCore

struct ShareItem: Identifiable, Equatable {
    var id: UUID
    var name: String
    var writable: Bool
    var url: URL
}

struct DeviceItem: Identifiable, Equatable {
    var id: String
    var name: String
    var pairedAt: Date
    var lastSeenAt: Date?
}

struct LiveDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var since: Date
}

struct ActivityEvent: Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var text: String
}

enum FriendlyName {
    private static let choices = [
        "Amber Desk", "Cedar Studio", "Willow Nook", "Harbor Loft", "Maple Study",
        "Copper Nest", "Bright Room", "Quiet Bench", "Silver Den", "Summit Desk",
    ]

    static func make() -> String { choices.randomElement() ?? "Tether Mac" }
}

enum RuntimeEvent: Sendable {
    case log(String)
    case paired(id: String, name: String, key: Data)
    case connected(id: String, name: String)
    case disconnected(id: String)
    case offerConsumed
    case approval(String)
}

@MainActor
@Observable
final class HostStore {
    var shares: [ShareItem] = []
    var devices: [DeviceItem] = []
    var connected: [LiveDevice] = []
    var activity: [ActivityEvent] = []
    var macName: String
    var sharingEnabled: Bool
    var requireApproval: Bool
    var launchAtLogin: Bool
    var offer: PairingOffer?
    var pairingMessage: String = L10n.pairWaiting
    var pairingSucceeded = false
    var staleMessage: String?
    var networkLine = "Starting…"

    private let context: ModelContext
    private let runtime: HostRuntime
    private let listener = TetherListener()
    private var started = false

    init(context: ModelContext) {
        self.context = context
        let defaults = UserDefaults.standard
        let name = HostStore.storedName(defaults: defaults)
        macName = name
        sharingEnabled = defaults.object(forKey: "sharingEnabled") as? Bool ?? true
        requireApproval = defaults.bool(forKey: "requireApproval")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let runtime = HostRuntime(hostId: HostStore.loadHostID(), macName: name)
        self.runtime = runtime
        runtime.restoreKey = { deviceId in
            PairingSecrets.load(service: HostStore.keychainService, account: "device.\(deviceId)")
        }
        runtime.onEvent = { event in
            Task { @MainActor in
                HostStore.shared?.apply(event)
            }
        }
        HostStore.shared = self
        reload()
        runtime.setRequireApproval(requireApproval)
        if sharingEnabled {
            startListening(peerToPeer: true)
        } else {
            networkLine = L10n.sharingPaused
        }
        startPhoneBrowser()
    }

    var nearbyPhones: [DiscoveredHost] = []
    var phoneStatus: String?
    private var seenPhones: [String: [DiscoveredHost]] = [:]
    private let sameNetworkBrowser = TetherBrowser(serviceType: TetherCoreInfo.serviceType)
    private let phoneServiceBrowser = TetherBrowser(serviceType: TetherCoreInfo.phoneServiceType)

    func useRandomName() {
        setName(FriendlyName.make())
    }

    func connect(phone: DiscoveredHost) {
        guard sharingEnabled else {
            phoneStatus = "Turn on Sharing, then connect."
            return
        }
        guard devices.contains(where: { phone.matches(savedHostId: $0.id) }) else {
            phoneStatus = "Pair \(phone.name) from the iPhone first."
            return
        }
        phoneStatus = "Connecting to \(phone.name)…"
        let runtime = runtime
        let name = macName
        let id = runtime.hostId
        Task {
            let stream = TetherLink.stream(to: phone.endpoint)
            do {
                try await stream.start()
                try await stream.send(try SessionDial.encode(hostId: id, hostName: name))
                self.phoneStatus = "\(phone.name) is opening this Mac."
                let started = Date()
                await HostConnection.serve(stream: stream, remote: phone.name, server: runtime)
                if Date().timeIntervalSince(started) < 2 {
                    self.phoneStatus = "Open Tether on \(phone.name), then try again."
                } else if self.phoneStatus == "\(phone.name) is opening this Mac." {
                    self.phoneStatus = nil
                }
            } catch {
                self.phoneStatus = "Open Tether on \(phone.name), then try again."
            }
        }
    }

    private func startPhoneBrowser() {
        wire(sameNetworkBrowser, key: "lan") { $0.isPhone }
        wire(phoneServiceBrowser, key: "phone") { _ in true }
    }

    private func wire(_ browser: TetherBrowser, key: String, allow: @escaping @Sendable (DiscoveredHost) -> Bool) {
        browser.onUpdate = { hosts in
            let kept = hosts.filter(allow)
            Task { @MainActor in
                HostStore.shared?.rememberPhones(key, kept)
            }
        }
        browser.onState = { state in
            Task { @MainActor in
                guard let store = HostStore.shared else { return }
                if state == "ready" {
                    if store.phoneStatus == "Allow Tether under Local Network in System Settings, then look again."
                        || store.phoneStatus == "Looking for your iPhone…" {
                        store.phoneStatus = nil
                    }
                } else if state.hasPrefix("waiting") || state.hasPrefix("failed") {
                    store.phoneStatus = "Allow Tether under Local Network in System Settings, then look again."
                }
            }
        }
        browser.start()
    }

    private func rememberPhones(_ key: String, _ hosts: [DiscoveredHost]) {
        seenPhones[key] = hosts
        var merged: [String: DiscoveredHost] = [:]
        for list in seenPhones.values {
            for host in list where host.hostId != runtime.hostId {
                if let existing = merged[host.hostId], existing.hasFriendlyName {
                    continue
                }
                merged[host.hostId] = host
            }
        }
        nearbyPhones = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refreshPhones(announce: Bool = true) {
        if announce { phoneStatus = "Looking for your iPhone…" }
        sameNetworkBrowser.stop()
        phoneServiceBrowser.stop()
        startPhoneBrowser()
    }

    private static func storedName(defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: "macName"), !saved.isEmpty {
            return saved
        }
        let generated = FriendlyName.make()
        defaults.set(generated, forKey: "macName")
        return generated
    }

    static var shared: HostStore?

    var statusSymbol: String {
        if !sharingEnabled { return "pause.circle" }
        if shares.isEmpty || connected.isEmpty { return "link" }
        if connected.isEmpty { return "link" }
        return "link.circle.fill"
    }

    var statusText: String {
        if !sharingEnabled { return L10n.sharingPaused }
        if shares.isEmpty { return L10n.notSharing }
        return L10n.status(folders: shares.count, devices: connected.count)
    }

    var statusLabel: String { "Tether, \(statusText)" }

    func setSharing(_ enabled: Bool) {
        sharingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "sharingEnabled")
        if enabled {
            fellBackFromPeerToPeer = false
            startListening(peerToPeer: true)
        } else {
            stopListening()
            runtime.disconnectAll()
            connected = []
            networkLine = L10n.sharingPaused
        }
    }

    func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        macName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "macName")
        runtime.setMacName(trimmed)
        if sharingEnabled { startListening(peerToPeer: true) }
    }

    func setRequireApproval(_ value: Bool) {
        requireApproval = value
        UserDefaults.standard.set(value, forKey: "requireApproval")
        runtime.setRequireApproval(value)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            note("Launch at login couldn't be changed.")
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "Choose a folder to share with paired iPhones."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url: url)
    }

    func add(url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var name = url.lastPathComponent
            var suffix = 2
            while shares.contains(where: { $0.name == name }) {
                name = "\(url.lastPathComponent) \(suffix)"
                suffix += 1
            }
            let record = ShareRecord(displayName: name, bookmark: data, writable: false)
            context.insert(record)
            try context.save()
            reload()
            if sharingEnabled { startListening(peerToPeer: true) }
        } catch {
            note("Couldn't share that folder.")
        }
    }

    func setWritable(_ share: ShareItem, _ writable: Bool) {
        let id = share.id
        let records = (try? context.fetch(FetchDescriptor<ShareRecord>())) ?? []
        guard let record = records.first(where: { $0.id == id }) else { return }
        record.writable = writable
        try? context.save()
        reload()
    }

    func remove(_ share: ShareItem) {
        let id = share.id
        if let item = shares.first(where: { $0.id == id }) {
            item.url.stopAccessingSecurityScopedResource()
        }
        let records = (try? context.fetch(FetchDescriptor<ShareRecord>())) ?? []
        if let record = records.first(where: { $0.id == id }) {
            context.delete(record)
            try? context.save()
        }
        reload()
        if shares.isEmpty { stopListening() }
    }

    func rename(_ share: ShareItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let records = (try? context.fetch(FetchDescriptor<ShareRecord>())) ?? []
        guard let record = records.first(where: { $0.id == share.id }) else { return }
        record.displayName = trimmed
        try? context.save()
        reload()
    }

    func beginPairing() {
        if !sharingEnabled { setSharing(true) }
        if !listenerReady { startListening(peerToPeer: true) }
        let created = PairingOffer(hostId: runtime.hostId, hostName: macName)
        offer = created
        pairingSucceeded = false
        pairingMessage = L10n.pairWaiting
        runtime.setOffer(created)
    }

    func revoke(_ device: DeviceItem) {
        PairingSecrets.delete(service: Self.keychainService, account: "device.\(device.id)")
        runtime.revoke(deviceId: device.id)
        let records = (try? context.fetch(FetchDescriptor<DeviceRecord>())) ?? []
        if let record = records.first(where: { $0.deviceId == device.id }) {
            context.delete(record)
            try? context.save()
        }
        devices.removeAll { $0.id == device.id }
        connected.removeAll { $0.id == device.id }
        note("Revoked \(device.name)")
    }

    func disconnect(_ device: LiveDevice) {
        runtime.disconnect(device.id)
    }

    func clearActivity() {
        activity = []
    }

    private func reload() {
        let records = (try? context.fetch(FetchDescriptor<ShareRecord>())) ?? []
        var mounted: [ShareItem] = []
        var mounts: [MountedShare] = []
        for record in records.sorted(by: { $0.createdAt < $1.createdAt }) {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                staleMessage = L10n.staleBookmark
                continue
            }
            if stale { staleMessage = L10n.staleBookmark }
            _ = url.startAccessingSecurityScopedResource()
            mounted.append(ShareItem(id: record.id, name: record.displayName, writable: record.writable, url: url))
            mounts.append(MountedShare(name: record.displayName, root: url, writable: record.writable))
        }
        shares = mounted
        runtime.setShares(mounts)

        let saved = (try? context.fetch(FetchDescriptor<DeviceRecord>())) ?? []
        devices = saved.map { DeviceItem(id: $0.deviceId, name: $0.name, pairedAt: $0.pairedAt, lastSeenAt: $0.lastSeenAt) }
            .sorted { $0.pairedAt > $1.pairedAt }
        var keys: [String: SymmetricKey] = [:]
        for device in devices {
            if let data = PairingSecrets.load(service: Self.keychainService, account: "device.\(device.id)"), data.count == 32 {
                keys[device.id] = SymmetricKey(data: data)
            }
        }
        runtime.setKeys(keys)
    }

    private var listenerReady = false
    private var fellBackFromPeerToPeer = false

    private func startListening(peerToPeer: Bool) {
        listenerReady = false
        listener.onConnection = { [runtime] connection in
            let stream = NWByteStream(connection: connection)
            Task {
                do {
                    try await stream.start()
                    await HostConnection.serve(stream: stream, remote: stream.remoteDescription, server: runtime)
                } catch {
                    TetherLog.transport.debug("incoming connection failed")
                }
            }
        }
        listener.onState = { state in
            Task { @MainActor in
                HostStore.shared?.applyNetwork(state, peerToPeer: peerToPeer)
            }
        }
        do {
            try listener.start(name: macName, hostId: runtime.hostId, peerToPeer: peerToPeer)
            started = true
            networkLine = "Looking for your iPhone…"
        } catch {
            networkLine = "Tether couldn't start sharing."
            note(networkLine)
        }
    }

    private func applyNetwork(_ state: String, peerToPeer: Bool) {
        if state.hasPrefix("failed"), peerToPeer, !fellBackFromPeerToPeer {
            fellBackFromPeerToPeer = true
            startListening(peerToPeer: false)
            return
        }
        if state == "ready" {
            listenerReady = true
            networkLine = "Visible on this Wi-Fi"
        } else if state.hasPrefix("waiting") {
            listenerReady = false
            networkLine = "Allow Tether under Local Network in System Settings."
        } else if state.hasPrefix("failed") {
            listenerReady = false
            networkLine = "Not on the network."
            note(state)
        }
    }

    private func stopListening() {
        listener.stop()
        started = false
        listenerReady = false
    }

    private func apply(_ event: RuntimeEvent) {
        switch event {
        case let .log(text):
            note(text)
        case let .paired(id, name, key):
            PairingSecrets.save(service: Self.keychainService, account: "device.\(id)", data: key)
            if PairingSecrets.load(service: Self.keychainService, account: "device.\(id)") == nil {
                note("Couldn't save the pairing key.")
            }
            let records = (try? context.fetch(FetchDescriptor<DeviceRecord>())) ?? []
            if let existing = records.first(where: { $0.deviceId == id }) {
                existing.name = name
                existing.lastSeenAt = Date()
            } else {
                context.insert(DeviceRecord(deviceId: id, name: name, lastSeenAt: Date()))
            }
            try? context.save()
            reload()
            pairingSucceeded = true
            pairingMessage = L10n.pairSuccess
            offer = nil
        case let .connected(id, name):
            if !connected.contains(where: { $0.id == id }) {
                connected.append(LiveDevice(id: id, name: name, since: Date()))
            }
            touch(id)
        case let .disconnected(id):
            connected.removeAll { $0.id == id }
        case .offerConsumed:
            offer = nil
        case let .approval(name):
            pairingMessage = L10n.wantsToConnect(name)
        }
    }

    private func touch(_ id: String) {
        let records = (try? context.fetch(FetchDescriptor<DeviceRecord>())) ?? []
        if let record = records.first(where: { $0.deviceId == id }) {
            record.lastSeenAt = Date()
            try? context.save()
        }
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].lastSeenAt = Date()
        }
    }

    private func note(_ text: String) {
        activity.insert(ActivityEvent(text: text), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    private nonisolated static let keychainService = "app.tether.host"

    private static func loadHostID() -> String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "hostId"), saved.count == 8 {
            PairingSecrets.save(service: keychainService, account: "host-id", data: Data(saved.utf8))
            return saved
        }
        if let data = PairingSecrets.load(service: keychainService, account: "host-id"),
           let text = String(data: data, encoding: .utf8), text.count == 8 {
            defaults.set(text, forKey: "hostId")
            return text
        }
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let id = String(raw)
        defaults.set(id, forKey: "hostId")
        PairingSecrets.save(service: keychainService, account: "host-id", data: Data(id.utf8))
        return id
    }
}

final class HostRuntime: HostServing, @unchecked Sendable {
    let hostId: String
    let abuse = AbuseGuard()
    private let lock = NSLock()
    private var offer: PairingOffer?
    private var keys: [String: SymmetricKey] = [:]
    private var revoked: Set<String> = []
    private var closers: [String: @Sendable () -> Void] = [:]
    /// Reads a pairing key from disk when it is not in memory yet. Used after a relaunch.
    var restoreKey: (@Sendable (String) -> Data?)?
    private var macName: String
    private var requireApproval = false
    private let provider = DiskFileProvider()
    var onEvent: (@Sendable (RuntimeEvent) -> Void)?

    init(hostId: String, macName: String) {
        self.hostId = hostId
        self.macName = macName
    }

    func hostName() -> String { sync { macName } }
    func currentOffer() -> PairingOffer? { sync { offer } }
    func consumeOffer() {
        sync { offer = nil }
        onEvent?(.offerConsumed)
    }

    func deviceKey(for deviceId: String) -> SymmetricKey? {
        if let key = sync({ keys[deviceId] }) { return key }
        if sync({ revoked.contains(deviceId) }) { return nil }
        guard let data = restoreKey?(deviceId), data.count == 32 else { return nil }
        let key = SymmetricKey(data: data)
        sync { keys[deviceId] = key }
        return key
    }

    func rememberDevice(id: String, name: String, key: SymmetricKey) {
        sync {
            revoked.remove(id)
            keys[id] = key
        }
        onEvent?(.paired(id: id, name: name, key: key.raw))
    }

    func sessionApprovalRequired() -> Bool { sync { requireApproval } }

    func decide(_ request: ApprovalRequest) async -> Bool {
        onEvent?(.approval(request.deviceName))
        let shares = request.shares.map(\.name).joined(separator: ", ")
        let uploads = request.shares.filter(\.writable).map(\.name).joined(separator: ", ")
        return await MainActor.run {
            let alert = NSAlert()
            alert.messageText = String(format: L10n.allowTitle, request.deviceName)
            var body = L10n.allowBody(shares: shares.isEmpty ? "the folders you share" : shares)
            if !uploads.isEmpty {
                body += "\n\n" + L10n.allowUpload(shares: uploads)
            }
            alert.informativeText = body
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    func note(_ event: String) { onEvent?(.log(event)) }
    func connected(deviceId: String, name: String) { onEvent?(.connected(id: deviceId, name: name)) }
    func disconnected(deviceId: String) { onEvent?(.disconnected(id: deviceId)) }
    func files() -> any FileProvider { provider }

    func runShell(line: String, cwd: String) async -> TerminalResult? {
        let virtual = (try? VirtualPath.parse(cwd)) ?? .root
        let directory: URL
        if virtual.isRoot {
            directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        } else if let url = try? provider.fileURL(for: virtual) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directory = url
            } else {
                directory = url.deletingLastPathComponent()
            }
        } else {
            return TerminalResult(stderr: "tether: that folder isn't available.\n", cwd: cwd, exit: 1)
        }
        _ = directory.startAccessingSecurityScopedResource()
        return await ShellRunner.run(line: line, directory: directory, cwd: cwd)
    }

    func thumbnail(virtualPath: String, maxPixel: Int) async -> Data? {
        guard let path = try? VirtualPath.parse(virtualPath), let url = try? provider.fileURL(for: path) else { return nil }
        let size = CGFloat(min(max(maxPixel, 64), 512))
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let nsImage = NSImage(cgImage: image.cgImage, size: NSSize(width: image.cgImage.width, height: image.cgImage.height))
        guard let tiff = nsImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return jpeg.count <= 256 * 1024 ? jpeg : nil
    }

    func watchConnection(for deviceId: String, close: @escaping @Sendable () -> Void) {
        sync { closers[deviceId] = close }
    }

    func ignoreConnection(for deviceId: String) {
        sync { closers[deviceId] = nil }
    }

    func setMacName(_ name: String) { sync { macName = name } }
    func setRequireApproval(_ value: Bool) { sync { requireApproval = value } }
    func setOffer(_ offer: PairingOffer?) { sync { self.offer = offer } }
    func setShares(_ shares: [MountedShare]) { provider.setShares(shares) }
    func setKeys(_ keys: [String: SymmetricKey]) {
        sync {
            var next = keys
            for (id, key) in self.keys where next[id] == nil && !revoked.contains(id) {
                next[id] = key
            }
            self.keys = next
        }
    }

    func revoke(deviceId: String) {
        let close: (@Sendable () -> Void)? = sync {
            revoked.insert(deviceId)
            keys[deviceId] = nil
            return closers[deviceId]
        }
        close?()
    }

    func disconnect(_ deviceId: String) {
        let close: (@Sendable () -> Void)? = sync { closers[deviceId] }
        close?()
    }

    func disconnectAll() {
        let all: [@Sendable () -> Void] = sync {
            let values = Array(closers.values)
            closers.removeAll()
            return values
        }
        all.forEach { $0() }
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
