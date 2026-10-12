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

struct InboxItem: Identifiable, Equatable, Hashable {
    var id: UUID
    var url: URL
    var name: String
    var size: UInt64
    var modified: Date
    var sender: String?
    /// Folder where the file was saved (shown under each row).
    var destination: String
    var batchID: UUID
}

/// Only files actually received from a phone — never a directory listing of the Inbox folder.
private struct InboxReceipt: Codable, Equatable, Identifiable {
    var id: UUID
    var fileName: String
    var path: String
    var size: UInt64
    var receivedAt: TimeInterval
    var sender: String
    var batchID: UUID?

    var date: Date { Date(timeIntervalSince1970: receivedAt) }
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
    case activityChanged
    case preventSleepChanged(Bool)
    case inboxReceived(fileName: String, path: String, deviceName: String)
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
    var preventSleepWhileActive: Bool
    /// When false, lid-closed `disablesleep` is only held on AC power (saves battery).
    var holdAwakeOnBattery: Bool
    /// Lid-closed privilege: installed, missing, or recovery agent still clearing a dead session.
    var sleepPrivilegeStatus: SleepPrivilegeStatus = .notInstalled
    /// True while Host currently holds `pmset disablesleep`.
    var lidClosedAwakeActive = false
    /// Human-readable reason when Right now is not holding (policy or pmset failure).
    var lidClosedAwakeReason: String = ""
    /// Mirrored for Lid-closed awake status UI.
    var runtimeLiveAgentCount: Int = 0
    var launchAtLogin: Bool
    var offer: PairingOffer?
    var pairingMessage: String = L10n.pairWaiting
    var pairingSucceeded = false
    var staleMessage: String?
    var networkLine = "Starting…"
    var remoteEnabled: Bool
    var listenPort: UInt16 = 0
    var reachableAddress: String
    var relayAddress: String
    var relayStatus = ""
    var machineAddresses: [MachineAddress] = []
    var inboxURL: URL?
    var inboxItems: [InboxItem] = []
    var inboxUnseenCount = 0
    var openShelfOnReceive: Bool
    var playSoundOnReceive: Bool
    /// Bumped when the Shelf should open (menu bar, auto-receive, or toolbar).
    var shelfPresentationToken = 0
    /// Files from the current receive batch only (not full Inbox history).
    var shelfItems: [InboxItem] = []
    private var inboxReceipts: [InboxReceipt] = []
    /// Active Shelf batch for this Mac session; nil until the first receive after launch.
    private var activeShelfBatchID: UUID?
    private var lastShelfReceiveAt: Date?

    private let context: ModelContext
    private let runtime: HostRuntime
    private let listener = TetherListener()
    private let sleepGuard = SleepGuard()
    private var started = false
    private var relayTask: Task<Void, Never>?
    private var relayStream: NWByteStream?
    private var relayGeneration = 0
    private var inboxAccessing = false

    init(context: ModelContext) {
        self.context = context
        let defaults = UserDefaults.standard
        let name = HostStore.storedName(defaults: defaults)
        macName = name
        sharingEnabled = defaults.object(forKey: "sharingEnabled") as? Bool ?? true
        requireApproval = defaults.bool(forKey: "requireApproval")
        preventSleepWhileActive = defaults.object(forKey: "preventSleepWhileActive") as? Bool ?? true
        holdAwakeOnBattery = defaults.object(forKey: "holdAwakeOnBattery") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        remoteEnabled = defaults.bool(forKey: "remoteEnabled")
        reachableAddress = defaults.string(forKey: "reachableAddress") ?? ""
        relayAddress = defaults.string(forKey: "relayAddress") ?? ""
        openShelfOnReceive = defaults.object(forKey: "openShelfOnReceive") as? Bool ?? true
        playSoundOnReceive = defaults.bool(forKey: "playSoundOnReceive")
        machineAddresses = MachineAddresses.list()
        inboxReceipts = HostStore.loadReceipts(defaults: defaults)
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
        rebuildInboxItems()
        runtime.setRequireApproval(requireApproval)
        runtime.setPreventSleepWhileActive(preventSleepWhileActive)
        if sharingEnabled {
            startListening(peerToPeer: true)
        } else {
            networkLine = L10n.sharingPaused
        }
        startPhoneBrowser()
        sleepGuard.onClamshellChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshSleepPrivilegeStatus()
            }
        }
        // Defer sleep/pmset work so the window can appear (agent pmset must not block init).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            self.refreshSleep()
        }
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
        if shares.isEmpty && inboxURL == nil { return L10n.notSharing }
        let folderCount = shares.count + (inboxURL == nil ? 0 : 1)
        if folderCount == 0 { return L10n.notSharing }
        return L10n.status(folders: folderCount, devices: connected.count)
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

    var displayPort: UInt16 { listenPort > 0 ? listenPort : TetherPorts.direct }

    /// Code the iPhone pastes. Nil until this Mac has an address or a relay.
    var setupCode: String? {
        guard remoteEnabled else { return nil }
        let direct = RemoteAddress.preferred(override: reachableAddress, port: displayPort, interfaces: machineAddresses)
        let relay = RemoteAddress.parse(relayAddress, defaultPort: TetherPorts.relay)
        guard direct != nil || relay != nil else { return nil }
        return RemoteSetup(hostId: runtime.hostId, direct: direct, relay: relay, token: loadOrCreateToken()).encoded()
    }

    func setRemoteEnabled(_ enabled: Bool) {
        remoteEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "remoteEnabled")
        machineAddresses = MachineAddresses.list()
        refreshSleep()
        guard sharingEnabled else {
            if !enabled { stopRelay() }
            return
        }
        fellBackFromPeerToPeer = false
        startListening(peerToPeer: true)
    }

    func setReachableAddress(_ value: String) {
        reachableAddress = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(reachableAddress, forKey: "reachableAddress")
    }

    func setRelayAddress(_ value: String) {
        relayAddress = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(relayAddress, forKey: "relayAddress")
        if sharingEnabled { startRelayIfNeeded() }
    }

    func refreshRemoteAddresses() {
        machineAddresses = MachineAddresses.list()
    }

    private func loadOrCreateToken() -> Data {
        let account = "remote-token"
        if let data = PairingSecrets.load(service: Self.keychainService, account: account), data.count == 32 {
            return data
        }
        let data = SymmetricKey.random().raw
        PairingSecrets.save(service: Self.keychainService, account: account, data: data)
        return data
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

    func setPreventSleepWhileActive(_ value: Bool) {
        preventSleepWhileActive = value
        UserDefaults.standard.set(value, forKey: "preventSleepWhileActive")
        runtime.setPreventSleepWhileActive(value)
        refreshSleep()
    }

    func setHoldAwakeOnBattery(_ value: Bool) {
        holdAwakeOnBattery = value
        UserDefaults.standard.set(value, forKey: "holdAwakeOnBattery")
        refreshSleep()
    }

    func refreshSleep() {
        let privilege = sleepGuard.privilegeStatus()
        // With lid-closed privilege + Other networks, keep the Mac awake so Tailscale can
        // accept a new session after the lid is already shut (not only mid-session).
        let keepRemote = remoteEnabled && privilege == .installed
        let agents = runtime.liveAgentCount()
        runtimeLiveAgentCount = agents
        let want = SleepPolicy.shouldStayAwake(
            enabled: preventSleepWhileActive,
            connectedDevices: connected.count,
            liveAgents: agents,
            keepRemoteReachable: keepRemote
        )
        let onAC = MacPowerSource.isExternallyPowered()
        let allowLidClosed = privilege == .installed && (holdAwakeOnBattery || onAC)
        sleepGuard.setActive(want, allowLidClosed: allowLidClosed)
        lidClosedAwakeActive = sleepGuard.isClamshellHeld
        sleepPrivilegeStatus = privilege
        lidClosedAwakeReason = Self.awakeReason(
            want: want,
            holding: lidClosedAwakeActive,
            engaging: sleepGuard.isClamshellEngaging,
            preventSleep: preventSleepWhileActive,
            privilege: privilege,
            allowLidClosed: allowLidClosed,
            onAC: onAC,
            holdOnBattery: holdAwakeOnBattery,
            remoteEnabled: remoteEnabled,
            connected: connected.count,
            agents: agents,
            pmsetError: sleepGuard.clamshellError
        )
    }

    /// Clears idle assertion and `disablesleep` before quit.
    func releaseSleepGuards() {
        sleepGuard.setActive(false)
        lidClosedAwakeActive = false
        lidClosedAwakeReason = ""
        sleepPrivilegeStatus = sleepGuard.privilegeStatus()
    }

    func refreshSleepPrivilegeStatus() {
        // Recheck must re-evaluate policy and retry pmset — not only re-read flags.
        refreshSleep()
    }

    private static func awakeReason(
        want: Bool,
        holding: Bool,
        engaging: Bool,
        preventSleep: Bool,
        privilege: SleepPrivilegeStatus,
        allowLidClosed: Bool,
        onAC: Bool,
        holdOnBattery: Bool,
        remoteEnabled: Bool,
        connected: Int,
        agents: Int,
        pmsetError: String?
    ) -> String {
        if holding { return "Lid-closed sleep is disabled." }
        if !preventSleep {
            return "Turn on Prevent sleep while active."
        }
        switch privilege {
        case .notInstalled:
            return "Install setup on this Mac first."
        case .agentNotRunning:
            return "Helper isn’t loaded. Use Repair setup, then Recheck."
        case .recoveryPending:
            return "Clearing a stale awake flag… wait a moment, then Recheck."
        case .installed:
            break
        }
        if want, !allowLidClosed, !holdOnBattery, !onAC {
            return "On battery — lid-closed hold is off (Battery saver). Plug in or enable Hold awake on battery."
        }
        if engaging {
            return "Turning on…"
        }
        if !want {
            if !remoteEnabled && connected == 0 && agents == 0 {
                return "Turn on Other networks, or connect an iPhone / start an agent."
            }
            return "Waiting for a reason to stay awake."
        }
        if let pmsetError, !pmsetError.isEmpty {
            return pmsetError
        }
        return "Couldn’t stay awake. Tap Recheck."
    }

    /// Opens Terminal to install sudoers + recovery LaunchAgent (password once).
    @discardableResult
    func installSleepPrivilege() -> SleepPrivilegeInstallOutcome {
        let outcome = SleepPrivilegeInstaller.runInstallInTerminal()
        refreshSleepPrivilegeStatus()
        return outcome
    }

    /// Opens Terminal to remove sudoers + recovery LaunchAgent.
    @discardableResult
    func uninstallSleepPrivilege() -> SleepPrivilegeInstallOutcome {
        releaseSleepGuards()
        let outcome = SleepPrivilegeInstaller.runUninstallInTerminal()
        refreshSleepPrivilegeStatus()
        return outcome
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
            if InboxShare.isReservedShareName(name) {
                name = "\(url.lastPathComponent) folder"
            }
            var suffix = 2
            while shares.contains(where: { $0.name == name }) || InboxShare.isReservedShareName(name) {
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

    func setOpenShelfOnReceive(_ enabled: Bool) {
        openShelfOnReceive = enabled
        UserDefaults.standard.set(enabled, forKey: "openShelfOnReceive")
    }

    func setPlaySoundOnReceive(_ enabled: Bool) {
        playSoundOnReceive = enabled
        UserDefaults.standard.set(enabled, forKey: "playSoundOnReceive")
    }

    func presentShelf() {
        shelfPresentationToken += 1
    }

    func chooseInboxFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Inbox"
        panel.message = "Choose where files sent from your iPhone are stored."
        if let inboxURL { panel.directoryURL = inboxURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setInboxFolder(url)
    }

    func setInboxFolder(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.inboxBookmarkKey)
            reload()
            note("Inbox folder updated.")
        } catch {
            note("Couldn't set the Inbox folder.")
        }
    }

    func markInboxSeen() {
        inboxUnseenCount = 0
    }

    func refreshInbox() {
        rebuildInboxItems()
    }

    func openInboxItem(_ item: InboxItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealInboxItem(_ item: InboxItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Removes a row from Inbox / Shelf history only — the file stays on disk.
    func deleteInboxItem(_ item: InboxItem) {
        inboxReceipts.removeAll { $0.id == item.id }
        persistReceipts()
        rebuildInboxItems()
    }

    /// Clears Inbox / Shelf history in the app only — files stay in the destination folder.
    func clearInbox() {
        inboxReceipts = []
        persistReceipts()
        inboxUnseenCount = 0
        activeShelfBatchID = nil
        lastShelfReceiveAt = nil
        rebuildInboxItems()
    }

    func moveInboxItem(_ item: InboxItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a folder for \(item.name)."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let destination = directory.appendingPathComponent(item.name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: item.url, to: destination)
            if let index = inboxReceipts.firstIndex(where: { $0.id == item.id }) {
                inboxReceipts[index].path = destination.path
                inboxReceipts[index].fileName = destination.lastPathComponent
                persistReceipts()
            }
            rebuildInboxItems()
        } catch {
            note("Couldn't move \(item.name).")
        }
    }

    var inboxPathDisplay: String {
        inboxURL?.path ?? "Not set"
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
        guard !InboxShare.isReservedShareName(trimmed) else { return }
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
        if let inbox = resolveInboxURL() {
            if inboxAccessing {
                inboxURL?.stopAccessingSecurityScopedResource()
                inboxAccessing = false
            }
            inboxAccessing = inbox.startAccessingSecurityScopedResource()
            inboxURL = inbox
            mounts.append(MountedShare(name: InboxShare.name, root: inbox, writable: true))
        } else {
            inboxURL = nil
        }
        for record in records.sorted(by: { $0.createdAt < $1.createdAt }) {
            if InboxShare.isReservedShareName(record.displayName) { continue }
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
        rebuildInboxItems()

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

    private static let inboxBookmarkKey = "inboxBookmark"

    private func resolveInboxURL() -> URL? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.inboxBookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if stale { staleMessage = "The Inbox folder needs to be chosen again." }
                return url
            }
        }
        return createDefaultInbox()
    }

    private func createDefaultInbox() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(TetherCoreInfo.inboxDefaultFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.inboxBookmarkKey)
            return url
        } catch {
            // Fall back to the path without a bookmark so local testing still works.
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private static let inboxReceiptsKey = "inboxReceipts"

    private static func loadReceipts(defaults: UserDefaults) -> [InboxReceipt] {
        guard let data = defaults.data(forKey: inboxReceiptsKey) else { return [] }
        return (try? JSONDecoder().decode([InboxReceipt].self, from: data)) ?? []
    }

    private func persistReceipts() {
        if let data = try? JSONEncoder().encode(inboxReceipts) {
            UserDefaults.standard.set(data, forKey: Self.inboxReceiptsKey)
        }
    }

    private func recordReceipt(fileName: String, deviceName: String) {
        guard let root = inboxURL else { return }
        let url = root.appendingPathComponent(fileName)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let now = Date()
        // New Shelf batch when idle > 45s (or first receive this launch).
        if activeShelfBatchID == nil
            || lastShelfReceiveAt.map({ now.timeIntervalSince($0) > 45 }) == true {
            activeShelfBatchID = UUID()
        }
        lastShelfReceiveAt = now
        let batch = activeShelfBatchID ?? UUID()
        activeShelfBatchID = batch
        let receipt = InboxReceipt(
            id: UUID(),
            fileName: fileName,
            path: url.path,
            size: size,
            receivedAt: now.timeIntervalSince1970,
            sender: deviceName,
            batchID: batch
        )
        inboxReceipts.insert(receipt, at: 0)
        if inboxReceipts.count > 200 {
            inboxReceipts = Array(inboxReceipts.prefix(200))
        }
        persistReceipts()
        rebuildInboxItems()
    }

    /// Rebuilds UI lists from the receive ledger only — never scans the Inbox directory.
    private func rebuildInboxItems() {
        var kept: [InboxReceipt] = []
        var items: [InboxItem] = []
        for receipt in inboxReceipts {
            let url = URL(fileURLWithPath: receipt.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            kept.append(receipt)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? receipt.size
            items.append(
                InboxItem(
                    id: receipt.id,
                    url: url,
                    name: receipt.fileName,
                    size: size,
                    modified: receipt.date,
                    sender: receipt.sender.isEmpty ? nil : receipt.sender,
                    destination: url.deletingLastPathComponent().path,
                    batchID: receipt.batchID ?? receipt.id
                )
            )
        }
        if kept.count != inboxReceipts.count {
            inboxReceipts = kept
            persistReceipts()
        }
        inboxItems = items
        if let batch = activeShelfBatchID {
            shelfItems = items.filter { $0.batchID == batch }
        } else {
            shelfItems = []
        }
    }

    func clearShelfBatch() {
        activeShelfBatchID = nil
        lastShelfReceiveAt = nil
        shelfItems = []
    }

    private var listenerReady = false
    private var fellBackFromPeerToPeer = false

    private func startListening(peerToPeer: Bool) {
        listenerReady = false
        listener.onConnection = { [runtime] connection in
            guard runtime.tryAdmitConnection() else {
                connection.cancel()
                return
            }
            let stream = NWByteStream(connection: connection)
            Task {
                defer { runtime.releaseConnection() }
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
        listener.onReady = { port in
            Task { @MainActor in
                HostStore.shared?.listenPort = port
                HostStore.shared?.machineAddresses = MachineAddresses.list()
            }
        }
        do {
            let port = remoteEnabled ? TetherPorts.direct : nil
            try listener.start(name: macName, hostId: runtime.hostId, peerToPeer: peerToPeer, port: port)
            started = true
            networkLine = "Looking for your iPhone…"
            startRelayIfNeeded()
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
            networkLine = remoteEnabled ? "Couldn't listen for connections from other networks." : "Not on the network."
            note(state)
        }
    }

    private func stopListening() {
        listener.stop()
        started = false
        listenerReady = false
        listenPort = 0
        stopRelay()
    }

    private func startRelayIfNeeded() {
        relayGeneration += 1
        let generation = relayGeneration
        relayTask?.cancel()
        relayTask = nil
        let previous = relayStream
        relayStream = nil
        Task { await previous?.close() }
        guard sharingEnabled, remoteEnabled, let address = RemoteAddress.parse(relayAddress, defaultPort: TetherPorts.relay) else {
            relayStatus = remoteEnabled ? "Add a relay address to connect from another network." : ""
            return
        }
        let token = loadOrCreateToken()
        let runtime = runtime
        relayStatus = "Connecting to the relay…"
        relayTask = Task.detached {
            var delay = 1.0
            while !Task.isCancelled {
                do {
                    let stream = try await RelayClient.open(role: .host, address: address, token: token)
                    let kept = await MainActor.run { () -> Bool in
                        guard let store = HostStore.shared, store.relayGeneration == generation else { return false }
                        store.relayStream = stream
                        store.relayStatus = "Relay is connected."
                        return true
                    }
                    guard kept else {
                        await stream.close()
                        return
                    }
                    guard runtime.tryAdmitConnection() else {
                        await stream.close()
                        throw RelayError.unreachable
                    }
                    defer { runtime.releaseConnection() }
                    await HostConnection.serve(stream: stream, remote: "relay", server: runtime)
                    if Task.isCancelled { return }
                    let stillCurrent = await MainActor.run { HostStore.shared?.relayGeneration == generation }
                    guard stillCurrent else { return }
                    await MainActor.run {
                        guard HostStore.shared?.relayGeneration == generation else { return }
                        HostStore.shared?.relayStatus = "Relay disconnected. Trying again…"
                    }
                    delay = 1
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard HostStore.shared?.relayGeneration == generation else { return }
                        HostStore.shared?.relayStatus = "Can't reach the relay."
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                delay = min(delay * 2, 15)
            }
        }
    }

    private func stopRelay() {
        relayGeneration += 1
        relayTask?.cancel()
        relayTask = nil
        let stream = relayStream
        relayStream = nil
        if !remoteEnabled { relayStatus = "" }
        Task { await stream?.close() }
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
            refreshSleep()
        case let .disconnected(id):
            connected.removeAll { $0.id == id }
            refreshSleep()
        case .offerConsumed:
            offer = nil
        case let .approval(name):
            pairingMessage = L10n.wantsToConnect(name)
        case .activityChanged:
            refreshSleep()
        case let .preventSleepChanged(value):
            preventSleepWhileActive = value
            UserDefaults.standard.set(value, forKey: "preventSleepWhileActive")
            refreshSleep()
        case let .inboxReceived(fileName, _, deviceName):
            recordReceipt(fileName: fileName, deviceName: deviceName)
            inboxUnseenCount += 1
            note("Received \(fileName)\(deviceName.isEmpty ? "" : " from \(deviceName)")")
            if openShelfOnReceive {
                presentShelf()
            }
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
    private var closers: [String: (generation: UInt64, close: @Sendable () -> Void)] = [:]
    private var connectionGeneration: [String: UInt64] = [:]
    /// Reads a pairing key from disk when it is not in memory yet. Used after a relaunch.
    var restoreKey: (@Sendable (String) -> Data?)?
    private var macName: String
    private var requireApproval = false
    private var preventSleep = true
    private let provider = DiskFileProvider()
    private var agents: [String: LiveAgent] = [:]
    var onEvent: (@Sendable (RuntimeEvent) -> Void)?

    init(hostId: String, macName: String) {
        self.hostId = hostId
        self.macName = macName
    }

    func liveAgentCount() -> Int { sync { agents.count } }

    func hostName() -> String { sync { macName } }
    func currentOffer() -> PairingOffer? { sync { offer } }
    func takeOffer() -> PairingOffer? {
        let taken: PairingOffer? = sync {
            let value = offer
            offer = nil
            return value
        }
        if taken != nil { onEvent?(.offerConsumed) }
        return taken
    }
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
    func didReceiveUpload(path: VirtualPath, fileName: String, fromDevice deviceName: String) {
        guard InboxShare.isInbox(path) else { return }
        onEvent?(.inboxReceived(fileName: fileName, path: path.string, deviceName: deviceName))
    }
    func connected(deviceId: String, name: String) { onEvent?(.connected(id: deviceId, name: name)) }
    @discardableResult
    func disconnected(deviceId: String, generation: UInt64) -> Bool {
        let current = sync { connectionGeneration[deviceId] }
        guard current == generation else { return false }
        onEvent?(.disconnected(id: deviceId))
        return true
    }
    func files() -> any FileProvider { provider }

    func runShell(line: String, cwd: String) async -> TerminalResult? {
        _ = line
        _ = cwd
        // v1.1: no general Mac shell for paired phones. Virtual commands only.
        return nil
    }

    let admission = ConnectionAdmission()
    func tryAdmitConnection() -> Bool { admission.tryAdmit() }
    func releaseConnection() { admission.release() }

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

    func watchConnection(for deviceId: String, close: @escaping @Sendable () -> Void) -> UInt64 {
        let (previous, generation): ((@Sendable () -> Void)?, UInt64) = sync {
            let next = (connectionGeneration[deviceId] ?? 0) + 1
            connectionGeneration[deviceId] = next
            let previous = closers[deviceId]?.close
            closers[deviceId] = (next, close)
            return (previous, next)
        }
        previous?()
        return generation
    }

    func ignoreConnection(for deviceId: String, generation: UInt64) {
        sync {
            guard closers[deviceId]?.generation == generation else { return }
            closers[deviceId] = nil
        }
    }

    func setMacName(_ name: String) { sync { macName = name } }
    func setRequireApproval(_ value: Bool) { sync { requireApproval = value } }
    func setPreventSleepWhileActive(_ value: Bool) {
        sync { preventSleep = value }
        onEvent?(.preventSleepChanged(value))
    }
    func preventSleepWhileActive() -> Bool { sync { preventSleep } }
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
            return closers[deviceId]?.close
        }
        close?()
    }

    func disconnect(_ deviceId: String) {
        let close: (@Sendable () -> Void)? = sync { closers[deviceId]?.close }
        close?()
    }

    func disconnectAll() {
        let all: [@Sendable () -> Void] = sync {
            let values = closers.values.map(\.close)
            closers.removeAll()
            return values
        }
        all.forEach { $0() }
    }

    func openTerminal(
        id: String,
        deviceId: String,
        line: String,
        cwd: String,
        columns: Int,
        rows: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> UInt64 {
        // Re-validate on the host so a future caller cannot skip the Session gate.
        guard !deviceId.isEmpty, AgentPrograms.programName(in: line) != nil else {
            throw ProtocolFailure(code: .badRequest, message: "That program can't be opened from this iPhone.")
        }
        let directory = try workingDirectory(cwd)
        guard let script = AgentPrograms.shellScript(line: line, directory: directory.path) else {
            throw ProtocolFailure(code: .badRequest, message: "That program can't be opened from this iPhone.")
        }
        let scoped = directory.startAccessingSecurityScopedResource()
        let bridge = TerminalBridge()
        let generation = bridge.resume(onData: onData, onExit: { [weak self] code in
            onExit(code)
            self?.releaseAgent(id)
        })
        guard let session = PTYSession.start(
            id: id,
            argv: ["/bin/zsh", "-lic", script],
            directory: directory.path,
            environment: AgentEnvironment.make(directory: directory.path),
            columns: columns,
            rows: rows,
            onData: { bridge.push($0) },
            onExit: { bridge.finish($0) }
        ) else {
            if scoped { directory.stopAccessingSecurityScopedResource() }
            throw ProtocolFailure(code: .internalError, message: "Couldn't open a terminal on this Mac.")
        }
        let live = LiveAgent(
            session: session,
            bridge: bridge,
            folder: directory,
            scoped: scoped,
            ownerDeviceId: deviceId
        )
        // Admit under the lock after spawn so concurrent opens cannot exceed the cap.
        enum Admission {
            case accepted(replaced: LiveAgent?)
            case rejected
        }
        let admission: Admission = sync {
            if agents[id] == nil, agents.count >= TerminalSlotBook.maxAgents {
                return .rejected
            }
            let previous = agents[id]
            agents[id] = live
            return .accepted(replaced: previous)
        }
        switch admission {
        case .rejected:
            session.terminate()
            if scoped { directory.stopAccessingSecurityScopedResource() }
            throw ProtocolFailure(
                code: .internalError,
                message: "Close a terminal first. This Mac allows \(TerminalSlotBook.maxAgents) live agents at once."
            )
        case let .accepted(replaced):
            // Same session id was replaced — tear down the old PTY without removing the new entry.
            if let replaced {
                replaced.session.terminate()
                if replaced.scoped {
                    replaced.folder.stopAccessingSecurityScopedResource()
                }
            }
            onEvent?(.activityChanged)
            return generation
        }
    }

    func suspendTerminal(id: String, generation: UInt64) async {
        sync { agents[id]?.bridge.suspend(generation: generation) }
    }

    func resumeTerminal(
        id: String,
        deviceId: String,
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> UInt64? {
        let bridge: TerminalBridge? = try sync {
            guard let live = agents[id] else { return nil }
            guard live.ownerDeviceId == deviceId else {
                throw ProtocolFailure(code: .denied, message: "That terminal belongs to another iPhone.")
            }
            return live.bridge
        }
        guard let bridge else { return nil }
        return bridge.resume(onData: onData, onExit: { [weak self] code in
            onExit(code)
            self?.releaseAgent(id)
        })
    }

    func writeTerminal(id: String, deviceId: String, data: Data) async throws {
        let session: PTYSession? = try sync {
            guard let live = agents[id] else { return nil }
            guard live.ownerDeviceId == deviceId else {
                throw ProtocolFailure(code: .denied, message: "That terminal belongs to another iPhone.")
            }
            return live.session
        }
        session?.write(data)
    }

    func resizeTerminal(id: String, deviceId: String, columns: Int, rows: Int) async throws {
        let session: PTYSession? = try sync {
            guard let live = agents[id] else { return nil }
            guard live.ownerDeviceId == deviceId else {
                throw ProtocolFailure(code: .denied, message: "That terminal belongs to another iPhone.")
            }
            return live.session
        }
        session?.resize(columns: columns, rows: rows)
    }

    func closeTerminal(id: String, deviceId: String) async throws {
        let session: PTYSession? = try sync {
            guard let live = agents[id] else { return nil }
            guard live.ownerDeviceId == deviceId else {
                throw ProtocolFailure(code: .denied, message: "That terminal belongs to another iPhone.")
            }
            return live.session
        }
        session?.terminate()
    }

    private func releaseAgent(_ id: String) {
        let live = sync { agents.removeValue(forKey: id) }
        if live?.scoped == true { live?.folder.stopAccessingSecurityScopedResource() }
        onEvent?(.activityChanged)
    }

    private func workingDirectory(_ cwd: String) throws -> URL {
        let virtual = (try? VirtualPath.parse(cwd)) ?? .root
        if virtual.isRoot {
            return URL(fileURLWithPath: AgentEnvironment.home, isDirectory: true)
        }
        guard let url = try? provider.fileURL(for: virtual) else {
            throw ProtocolFailure(code: .notFound, message: "That folder isn't available.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
