import CryptoKit
import Foundation
import Network
import Observation
import SwiftData
import TetherCore
import UIKit

/// The live agent screen. A class so publishing a new frame does not copy every cell.
final class AgentSurface {
    var screen: VTScreen

    init(screen: VTScreen) {
        self.screen = screen
    }
}

@MainActor
@Observable
final class ClientStore {
    var discovered: [DiscoveredHost] = []
    var paired: [PairedItem] = []
    var showPrimer = false
    var showPairing = false
    var pairPhase: PairPhase = .scanning
    var connected = false
    var hostName = ""
    var hostId = ""
    var path = "/"
    var entries: [FileEntry] = []
    var shares: [ShareInfo] = []
    var loading = false
    var offline = false
    var reconnecting = false
    var revoked = false
    var statusMessage: String?
    var localNetworkOff = false
    var discoveryDetail: String?
    var transfers: [TransferItem] = []
    var grid = false
    var sort: FileSort = .name
    var preview: FilePreview?
    var fileInfo: FileInfo?
    var pendingLarge: FileEntry?
    var largeFileWillPreview: Bool { pendingPreview }
    var readOnlyAlert = false
    /// Ordered Terminal slots (max `TerminalSlotBook.maxSlots`).
    var terminalSlots: [TerminalSlotState] = []
    var focusedSlotID = ""
    /// Bumps when slot list, focus, or virtual/fetch content changes so SwiftUI refreshes.
    var slotEpoch = 0
    var monitorProfile: SystemProfile?
    var monitorStats: SystemStats?
    var monitorDown = "0 B/s"
    var monitorUp = "0 B/s"
    var monitorMessage: String?
    /// Bumps when any live agent screen should be drawn again.
    var agentFrame = 0
    var deviceName: String
    var demoMode: Bool
    var fontSize: Double
    var cacheBytes: Int64 = 0
    var recents: [RecentRecord] = []
    /// 0 Files, 1 Send, 2 Terminal, 3 Transfers — see `SessionTabIndex`.
    var sessionTab = SessionTabIndex.files
    var connectingName: String?
    var phoneVisible = false
    var searchText = ""
    /// Global name hits across shared folders while the Files search field is non-empty.
    var fileSearchHits: [FileSearchHit] = []
    var fileSearchRunning = false
    var requestUpload = false
    var selecting = false
    var selection: Set<String> = []
    var notice: String?
    var feedbackCue: FeedbackCue = .success
    var feedbackTick = 0
    var remoteHostIDs: Set<String> = []
    /// Mirrors the Mac preference. Synced while connected; applied on the next connect if offline.
    var preventSleepWhileActive: Bool
    /// After `help`, the terminal shows a tappable command catalog until dismissed or a row is picked.
    var showCommandHelp = false

    private let context: ModelContext
    private let browser = TetherBrowser()
    private let phoneListener = TetherListener()
    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var lastPathFingerprint: String?
    private var connection: ClientConnection?
    private var demoFiles: MemoryFileProvider?
    private var lastDownload: URL?
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var intentionalDisconnect = false
    private var activeHost: PairedItem?
    private var pendingPreview = true
    private var monitorBytesIn: UInt64?
    private var monitorBytesOut: UInt64?
    private var monitorSampledAt: Date?
    private var monitorTick = 0
    private var pendingPath = "/"
    private var thumbnailCache: [String: Data] = [:]
    private let deviceID: String
    private var terminalEpoch = 0
    private var terminalBusy = false
    private var agentEarly: [String: Data] = [:]
    private var agentEarlyExit: [String: Int] = [:]
    private var completionListCache: [String: (at: ContinuousClock.Instant, names: [CompletionName])] = [:]
    private let completionListTTL: Duration = .seconds(2)
    private var fileSearchToken = 0
    private var monitorPollTask: Task<Void, Never>?

    var focusedSlot: TerminalSlotState? {
        terminalSlots.first { $0.id == focusedSlotID } ?? terminalSlots.first
    }

    var terminalLines: [TermLine] {
        get { focusedSlot?.lines ?? [] }
        set {
            focusedSlot?.lines = newValue
            bumpSlots()
        }
    }

    var terminalCWD: String {
        get { focusedSlot?.cwd ?? "/" }
        set {
            focusedSlot?.cwd = newValue
            bumpSlots()
        }
    }

    var history: [String] {
        get { focusedSlot?.history ?? [] }
        set {
            focusedSlot?.history = newValue
            bumpSlots()
        }
    }

    var historyIndex: Int {
        get { focusedSlot?.historyIndex ?? 0 }
        set {
            focusedSlot?.historyIndex = newValue
            bumpSlots()
        }
    }

    var agentProgram: String? { focusedSlot?.kind == .agent ? focusedSlot?.agentProgram : nil }
    var agentSurface: AgentSurface? { focusedSlot?.kind == .agent ? focusedSlot?.agentSurface : nil }
    var agentExited: Bool { focusedSlot?.agentExited ?? false }
    var agentExitCode: Int { focusedSlot?.agentExitCode ?? 0 }
    var agentError: String? { focusedSlot?.agentError }
    var agentReceived: Bool { focusedSlot?.agentReceived ?? false }
    var agentPaused: Bool { focusedSlot?.agentPaused ?? false }
    var fetchText: String? { focusedSlot?.kind == .fetch ? focusedSlot?.fetchText : nil }
    var hasLiveAgent: Bool { terminalSlots.contains(where: \.isLiveAgent) }
    var focusedIsLiveAgent: Bool { focusedSlot?.isLiveAgent == true }

    init(context: ModelContext, preview: Bool = false) {
        self.context = context
        let defaults = UserDefaults.standard
        deviceName = defaults.string(forKey: "deviceName") ?? UIDevice.current.name
        demoMode = defaults.bool(forKey: "demoMode")
        fontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 14
        preventSleepWhileActive = defaults.object(forKey: "preventSleepWhileActive") as? Bool ?? true
        deviceID = Self.loadDeviceID()
        let welcome = TerminalSlotState.virtualWelcome(text: L10n.termWelcome)
        terminalSlots = [welcome]
        focusedSlotID = welcome.id
        ClientStore.shared = self
        reloadPaired()
        reloadRemote()
        refreshCacheSize()
        restoreAgents()
        if preview { return }
        startPathMonitor()
        if !defaults.bool(forKey: "didAcceptPrimer") {
            showPrimer = true
        } else {
            startBrowser()
        }
    }

    static var shared: ClientStore?

    var activeTransfers: [TransferItem] { transfers.filter { $0.state == .active } }
    var finishedTransfers: [TransferItem] { transfers.filter { $0.state != .active } }

    func acceptPrimer() {
        UserDefaults.standard.set(true, forKey: "didAcceptPrimer")
        showPrimer = false
        startBrowser()
    }

    func startBrowser() {
        browser.onUpdate = { hosts in
            Task { @MainActor in
                guard let store = ClientStore.shared else { return }
                store.discovered = hosts.filter { host in
                    !host.isPhone && host.hostId != store.deviceID
                }
                store.applyDiscoveredNames(store.discovered)
            }
        }
        browser.onState = { state in
            Task { @MainActor in
                guard let store = ClientStore.shared else { return }
                if state == "ready" {
                    let shouldAdvertise = store.localNetworkOff || !store.phoneVisible
                    store.localNetworkOff = false
                    store.discoveryDetail = nil
                    if shouldAdvertise { store.startPhoneListener() }
                } else if state.hasPrefix("waiting") || state.hasPrefix("failed") {
                    store.localNetworkOff = true
                    store.discoveryDetail = "Allow Tether to find devices on your local network, then pull to refresh."
                }
            }
        }
        browser.start()
        startPhoneListener()
    }

    func startPhoneListener() {
        phoneListener.onConnection = { connection in
            let stream = NWByteStream(connection: connection)
            Task { @MainActor in
                await ClientStore.shared?.acceptDial(stream)
            }
        }
        phoneListener.onState = { state in
            Task { @MainActor in
                guard let store = ClientStore.shared else { return }
                if state == "ready" || state == "advertised" {
                    store.phoneVisible = true
                } else if state.hasPrefix("failed") {
                    store.phoneVisible = false
                }
            }
        }
        do {
            // Same service type the Mac already publishes, on infrastructure Wi-Fi.
            // A peer-to-peer-only advertisement can report ready and still be invisible
            // to a Mac that is browsing the shared network.
            try phoneListener.start(
                name: deviceName,
                hostId: deviceID,
                peerToPeer: false,
                serviceType: TetherCoreInfo.serviceType,
                namePrefix: "Phone",
                role: "phone",
                plainName: true
            )
        } catch {
            phoneVisible = false
            TetherLog.discovery.debug("phone advertisement failed")
        }
    }

    func acceptDial(_ stream: NWByteStream) async {
        do {
            try await stream.start()
            let dial = try SessionDial.decode(try await FrameReader(stream: stream).nextPayload())
            guard let keyData = PairingSecrets.load(service: ClientKeychain.service, account: "host.\(dial.hostId)") else {
                await stream.close()
                return
            }
            let session = try await ClientConnection.establish(
                stream: stream,
                deviceId: deviceID,
                deviceName: deviceName,
                mode: .session(hostId: dial.hostId, key: SymmetricKey(data: keyData))
            )
            await attach(session)
            let previousHost = hostId
            hostId = dial.hostId
            hostName = await session.hostName
            connected = true
            offline = false
            reconnecting = false
            intentionalDisconnect = false
            if let saved = paired.first(where: { $0.id == dial.hostId }) {
                activeHost = saved
                touch(saved.id)
            }
            shares = try await session.shares()
            adoptConnectedHost(dial.hostId, previousHost: previousHost, resettingPath: true)
            try await refresh()
            await resumeAgentsIfNeeded(host: dial.hostId)
        } catch {
            await stream.close()
        }
    }

    func refreshBrowser() {
        localNetworkOff = false
        browser.stop()
        startBrowser()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deviceName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "deviceName")
        startPhoneListener()
    }

    func setFontSize(_ size: Double) {
        fontSize = min(20, max(11, size))
        UserDefaults.standard.set(fontSize, forKey: "terminalFontSize")
    }

    func setPreventSleepWhileActive(_ value: Bool) {
        preventSleepWhileActive = value
        UserDefaults.standard.set(value, forKey: "preventSleepWhileActive")
        guard let connection else { return }
        Task {
            if let applied = try? await connection.setHostPreventSleep(value) {
                await MainActor.run { self.preventSleepWhileActive = applied }
            }
        }
    }

    func refreshHostPrefsIfConnected() {
        guard let connection else { return }
        Task {
            guard let current = try? await connection.hostPrefs() else { return }
            await MainActor.run {
                self.preventSleepWhileActive = current
                UserDefaults.standard.set(current, forKey: "preventSleepWhileActive")
            }
        }
    }

    func setDemo(_ enabled: Bool) {
        demoMode = enabled
        UserDefaults.standard.set(enabled, forKey: "demoMode")
        if enabled {
            enableDemo()
        } else {
            demoFiles = nil
            connected = false
            hostName = ""
            entries = []
        }
    }

    func forget(_ item: PairedItem) {
        PairingSecrets.delete(service: ClientKeychain.service, account: "host.\(item.id)")
        let records = (try? context.fetch(FetchDescriptor<PairedHostRecord>())) ?? []
        if let record = records.first(where: { $0.hostId == item.id }) {
            context.delete(record)
            try? context.save()
        }
        paired.removeAll { $0.id == item.id }
        RemoteBook.clear(hostId: item.id)
        reloadRemote()
        if hostId == item.id { disconnect() }
    }

    func forgetAll() {
        for item in paired { forget(item) }
        paired = []
        disconnect()
    }

    func connect(_ item: PairedItem) async {
        await connect(item, restoring: false)
    }

    func connect(_ item: PairedItem, restoring: Bool) async {
        connectingName = item.name
        defer { connectingName = nil }
        if demoMode { enableDemo(); return }
        guard let keyData = PairingSecrets.load(service: ClientKeychain.service, account: "host.\(item.id)") else {
            offline = true
            statusMessage = "This iPhone lost the saved pairing for \(item.name). Pair once more, then it will stay saved."
            return
        }
        let stream: any ByteStream
        do {
            stream = try await openStream(for: item.id, name: item.name)
        } catch {
            reconnecting = false
            offline = true
            statusMessage = remoteFailure(item.name, error, remote: remoteHostIDs.contains(item.id))
            return
        }
        reconnecting = connection != nil
        offline = false
        revoked = false
        statusMessage = nil
        do {
            let session = try await ClientConnection.establish(
                stream: stream,
                deviceId: deviceID,
                deviceName: deviceName,
                mode: .session(hostId: item.id, key: SymmetricKey(data: keyData))
            )
            await attach(session)
            let previousHost = hostId
            hostId = item.id
            hostName = await session.hostName
            connected = true
            offline = false
            reconnecting = false
            activeHost = item
            intentionalDisconnect = false
            touch(item.id)
            shares = try await session.shares()
            adoptConnectedHost(item.id, previousHost: previousHost, resettingPath: !restoring)
            try await refresh()
            await syncPreventSleepPreference()
            await resumeAgentsIfNeeded(host: item.id)
        } catch {
            await stream.close()
            reconnecting = false
            let failure = error as? ProtocolFailure
            if failure?.message == ProtocolFailure.revoked.message {
                revoked = true
                connected = false
            } else {
                offline = true
                statusMessage = failure?.message ?? remoteFailure(item.name, error, remote: remoteHostIDs.contains(item.id))
            }
        }
    }

    func pair(_ payload: PairingPayload) async {
        pairPhase = .connecting
        guard let endpoint = await waitForEndpoint(hostId: payload.hostId) else {
            pairPhase = .failed(L10n.unreachable(payload.hostName))
            return
        }
        pairPhase = .waiting
        let stream = TetherLink.stream(to: endpoint)
        do {
            try await stream.start()
            let session = try await ClientConnection.establish(
                stream: stream,
                deviceId: deviceID,
                deviceName: deviceName,
                mode: .pair(payload)
            )
            let key = await session.receivedDeviceKey
            let name = await session.hostName
            let id = await session.hostId
            guard let key else { throw ProtocolFailure.malformed }
            PairingSecrets.save(service: ClientKeychain.service, account: "host.\(id)", data: key)
            guard PairingSecrets.load(service: ClientKeychain.service, account: "host.\(id)") != nil else {
                throw ProtocolFailure(code: .internalError, message: "Couldn't save the pairing on this iPhone.")
            }
            savePaired(id: id, name: name)
            await attach(session)
            let previousHost = hostId
            hostId = id
            hostName = name
            connected = true
            adoptConnectedHost(id, previousHost: previousHost, resettingPath: true)
            pairPhase = .success(name)
            shares = try await session.shares()
            try await refresh()
            try? await Task.sleep(for: .seconds(1.2))
            showPairing = false
        } catch {
            pairPhase = .failed((error as? ProtocolFailure)?.message ?? "Couldn't pair with that Mac. Check the code and try again.")
        }
    }

    func pair(code: String, host: DiscoveredHost) async {
        do {
            let payload = try PairingPayload.parseManual(code: code, hostId: host.hostId, hostName: host.name)
            await pair(payload)
        } catch {
            pairPhase = .failed((error as? ProtocolFailure)?.message ?? "That pairing code isn't valid.")
        }
    }

    func disconnect() {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        let current = connection
        let sessions = terminalSlots.compactMap(\.agentSessionID)
        connection = nil
        connected = false
        offline = false
        reconnecting = false
        clearAllAgents(keepSlots: false)
        Task {
            for session in sessions {
                await current?.closeTerminal(session: session)
            }
            await current?.close()
        }
    }

    func refresh() async throws {
        loading = entries.isEmpty
        defer { loading = false }
        // Inbox is send-only — never browse it from Files.
        if let virtual = try? VirtualPath.parse(path), InboxShare.isInbox(virtual) || virtual.components.first.map(InboxShare.isReservedShareName) == true {
            path = "/"
        }
        if let demoFiles {
            let virtual = try VirtualPath.parse(path)
            entries = try await demoFiles.list(path: virtual, offset: 0, limit: 1000, includeHidden: false)
            shares = await demoFiles.shares()
            if path == "/" {
                entries.removeAll { InboxShare.isReservedShareName($0.name) }
            }
            offline = false
            return
        }
        guard let connection else { return }
        entries = try await connection.list(path: path)
        if path == "/" {
            entries.removeAll { InboxShare.isReservedShareName($0.name) }
        }
        offline = false
    }

    func open(_ entry: FileEntry) async {
        if selecting {
            toggleSelection(entry)
            return
        }
        if entry.kind == .dir {
            if InboxShare.isReservedShareName(entry.name) { return }
            path = path == "/" ? "/\(entry.name)" : path + "/" + entry.name
            entries = []
            selection.removeAll()
            try? await refresh()
            return
        }
        download(entry, preview: true)
    }

    func toggleSelection(_ entry: FileEntry) {
        if selection.contains(entry.name) {
            selection.remove(entry.name)
        } else {
            selection.insert(entry.name)
        }
    }

    func downloadSelection() {
        let chosen = entries.filter { selection.contains($0.name) }
        selecting = false
        selection.removeAll()
        guard !chosen.isEmpty else { return }
        Task { await self.transfer(chosen, preview: false, announce: true) }
    }

    func confirmLargeDownload() async {
        guard let entry = pendingLarge else { return }
        let previewing = pendingPreview
        let full = pendingPath == "/" ? "/\(entry.name)" : pendingPath + "/" + entry.name
        pendingLarge = nil
        let saved = await fetch(entry: entry, virtualPath: full, relativePath: entry.name, preview: previewing, allowLarge: true)
        if saved {
            if !previewing { notice = "Saved \(entry.name) to the Files app." }
            cue(.success)
        }
    }

    /// Preview opens Quick Look from the cache. Download copies the file into the Files app and does not open it.
    func download(_ entry: FileEntry, preview: Bool) {
        if entry.kind != .dir, entry.size > 100 * 1024 * 1024 {
            pendingLarge = entry
            pendingPreview = preview
            pendingPath = path
            return
        }
        Task { await self.transfer([entry], preview: preview, announce: !preview) }
    }

    private func transfer(_ items: [FileEntry], preview: Bool, announce: Bool) async {
        var saved = 0
        var finished = false
        for entry in items {
            if entry.kind == .dir {
                let count = await walk(path: joined(entry.name), relative: entry.name)
                if count > 0 {
                    saved += count
                    finished = true
                }
            } else if await fetch(entry: entry, virtualPath: joined(entry.name), relativePath: entry.name, preview: preview, allowLarge: true) {
                finished = true
                if !preview { saved += 1 }
            }
        }
        if announce, saved > 0 {
            notice = saved == 1 ? "Saved 1 item to the Files app." : "Saved \(saved) items to the Files app."
        }
        if finished { cue(.success) }
    }

    private func walk(path: String, relative: String) async -> Int {
        let children = await listFolder(path)
        if children.isEmpty {
            let folder = documentsFile(relative: relative)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return 1
        }
        var saved = 0
        for child in children {
            let childPath = path == "/" ? "/\(child.name)" : path + "/" + child.name
            let childRelative = relative + "/" + child.name
            if child.kind == .dir {
                saved += await walk(path: childPath, relative: childRelative)
            } else if await fetch(entry: child, virtualPath: childPath, relativePath: childRelative, preview: false, allowLarge: true) {
                saved += 1
            }
        }
        return saved
    }

    private func listFolder(_ path: String, includeHidden: Bool = false) async -> [FileEntry] {
        if let demoFiles, let virtual = try? VirtualPath.parse(path) {
            return (try? await demoFiles.list(path: virtual, offset: 0, limit: 1000, includeHidden: includeHidden)) ?? []
        }
        return (try? await connection?.list(path: path, includeHidden: includeHidden)) ?? []
    }

    @discardableResult
    private func fetch(entry: FileEntry, virtualPath: String, relativePath: String, preview: Bool, allowLarge: Bool) async -> Bool {
        if !allowLarge, entry.size > 100 * 1024 * 1024 {
            pendingLarge = entry
            pendingPreview = preview
            pendingPath = path
            return false
        }
        let destination = cacheURL(host: hostId, path: virtualPath, size: entry.size, mtime: entry.mtime, fileName: entry.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            if preview {
                self.preview = FilePreview(url: destination, title: entry.name)
                return true
            }
            do {
                try copyToDocuments(from: destination, relative: relativePath)
                return true
            } catch {
                return false
            }
        }
        let item = TransferItem(name: entry.name, path: virtualPath, direction: .down, total: entry.size, localURL: destination)
        transfers.insert(item, at: 0)
        publishTransferLiveActivity(force: true)
        let id = item.id
        let ok: Bool = await withCheckedContinuation { continuation in
            let task = Task { @MainActor in
                var result = await self.performDownload(id: id, entry: entry, full: virtualPath, destination: destination)
                if result, preview {
                    self.preview = FilePreview(url: destination, title: entry.name)
                } else if result {
                    do {
                        try self.copyToDocuments(from: destination, relative: relativePath)
                        self.updateTransfer(id, sent: max(entry.size, 1), total: max(entry.size, 1), state: .completed, message: "Saved to Files")
                    } catch {
                        self.updateTransfer(id, sent: entry.size, total: max(entry.size, 1), state: .failed, message: "Couldn't save that to the Files app.")
                        result = false
                    }
                }
                self.transferTasks[id] = nil
                continuation.resume(returning: result)
            }
            self.transferTasks[id] = task
        }
        return ok
    }

    private func performDownload(id: UUID, entry: FileEntry, full: String, destination: URL) async -> Bool {
        do {
            try Task.checkCancellation()
            if let demoFiles {
                let chunk = try await demoFiles.read(path: VirtualPath.parse(full), offset: 0, length: Int(max(entry.size, 1)))
                try Task.checkCancellation()
                try chunk.data.write(to: destination, options: .atomic)
                updateTransfer(id, sent: entry.size, total: max(entry.size, 1), state: .completed)
            } else if let connection {
                try await connection.download(path: full, to: destination) { sent, total in
                    Task { @MainActor in
                        self.updateTransfer(id, sent: sent, total: total, state: .active)
                    }
                }
                try Task.checkCancellation()
                updateTransfer(id, sent: max(entry.size, 1), total: max(entry.size, 1), state: .completed)
            } else {
                updateTransfer(id, sent: 0, total: entry.size, state: .failed, message: "Not connected.")
                return false
            }
            remember(full)
            refreshCacheSize()
            lastDownload = destination
            return true
        } catch is CancellationError {
            updateTransfer(id, sent: 0, total: entry.size, state: .failed, message: "Cancelled")
            return false
        } catch {
            if Task.isCancelled {
                updateTransfer(id, sent: 0, total: entry.size, state: .failed, message: "Cancelled")
            } else {
                updateTransfer(id, sent: 0, total: entry.size, state: .failed, message: (error as? ProtocolFailure)?.message)
            }
            return false
        }
    }

    func upload(url: URL) async {
        guard currentShareWritable else {
            readOnlyAlert = true
            return
        }
        let name = url.lastPathComponent
        let full = joined(name)
        await enqueueUpload(url: url, directory: path, fileName: name, fullPath: full)
    }

    /// Send into the Mac's reserved Inbox share, independent of the Files browser path.
    func sendToInbox(url: URL) async {
        guard connected || demoMode else {
            statusMessage = "Connect to your Mac to send."
            sessionTab = SessionTabIndex.send
            return
        }
        let name = url.lastPathComponent
        let directory = "/\(InboxShare.name)"
        let full = "\(directory)/\(name)"
        await enqueueUpload(url: url, directory: directory, fileName: name, fullPath: full)
        sessionTab = SessionTabIndex.transfers
    }

    private func enqueueUpload(url: URL, directory: String, fileName: String, fullPath: String) async {
        let sizeHint = Self.fileByteCount(at: url)
        let item = TransferItem(name: fileName, path: fullPath, direction: .up, total: max(sizeHint, 1))
        transfers.insert(item, at: 0)
        publishTransferLiveActivity(force: true)
        let id = item.id
        transferTasks[id] = Task { @MainActor in
            await self.performUpload(id: id, source: url, directory: directory, name: fileName, sizeHint: sizeHint)
            self.transferTasks[id] = nil
        }
    }

    private func performUpload(id: UUID, source: URL, directory: String, name: String, sizeHint: UInt64) async {
        let full = directory == "/" ? "/\(name)" : "\(directory)/\(name)"
        var localURL = source
        var cleanup: URL?
        do {
            // Copy under a security scope first so fileImporter / iCloud URLs stay readable
            // for the whole transfer (the picker scope ends when sendToInbox returns).
            let prepared = try Self.materializeUploadFile(from: source)
            localURL = prepared.url
            cleanup = prepared.cleanup
            let size = max(Self.fileByteCount(at: localURL), sizeHint, 1)
            updateTransfer(id, sent: 0, total: size, state: .active)

            if let demoFiles {
                let data = try Data(contentsOf: localURL)
                if directory == "/\(InboxShare.name)",
                   await demoFiles.shares().contains(where: { $0.name == InboxShare.name }) == false {
                    demoFiles.addShare(name: InboxShare.name, writable: true)
                }
                try demoFiles.writeFile(path: full, data: data)
                updateTransfer(id, sent: UInt64(data.count), total: UInt64(data.count), state: .completed)
                invalidateCompletionCache()
            } else if let connection {
                let clock = UploadProgressClock()
                try await connection.upload(file: localURL, toDirectory: directory, fileName: name) { sent, total in
                    guard clock.shouldPublish(sent: sent, total: total) else { return }
                    Task { @MainActor in
                        self.updateTransfer(id, sent: sent, total: max(total, 1), state: .active)
                    }
                }
                updateTransfer(id, sent: size, total: size, state: .completed)
            } else {
                throw ProtocolFailure(code: .busy, message: "Not connected to a Mac.")
            }
            invalidateCompletionCache()
            try? await refresh()
        } catch is CancellationError {
            updateTransfer(id, sent: 0, total: max(sizeHint, 1), state: .failed, message: "Cancelled")
        } catch {
            if Task.isCancelled {
                updateTransfer(id, sent: 0, total: max(sizeHint, 1), state: .failed, message: "Cancelled")
            } else {
                updateTransfer(
                    id,
                    sent: 0,
                    total: max(sizeHint, 1),
                    state: .failed,
                    message: (error as? ProtocolFailure)?.message ?? "Couldn't send that file."
                )
            }
        }
        if let cleanup {
            try? FileManager.default.removeItem(at: cleanup)
        }
    }

    private static func fileByteCount(at url: URL) -> UInt64 {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            return UInt64(size)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let number = attrs[.size] as? NSNumber {
            return number.uint64Value
        }
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let end = try? handle.seekToEnd() { return end }
        }
        return 0
    }

    /// Copies a picker/share URL into a temp file while the security scope is held.
    private static func materializeUploadFile(from url: URL) throws -> (url: URL, cleanup: URL?) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-up-\(UUID().uuidString)-\(url.lastPathComponent)")
        if FileManager.default.fileExists(atPath: temp.path) {
            try FileManager.default.removeItem(at: temp)
        }
        try FileManager.default.copyItem(at: url, to: temp)
        return (temp, temp)
    }

    func retry(_ item: TransferItem) async {
        guard item.retries < 2 || true else { return }
        if let index = transfers.firstIndex(where: { $0.id == item.id }) {
            transfers[index].retries += 1
            transfers[index].state = .active
        }
        if item.direction == .down, let entry = entries.first(where: { $0.name == item.name }) {
            download(entry, preview: false)
        }
    }

    func cancel(_ item: TransferItem) {
        transferTasks[item.id]?.cancel()
        transferTasks[item.id] = nil
        updateTransfer(item.id, sent: item.sent, total: item.total, state: .failed, message: "Cancelled")
    }

    func showPreview(_ item: TransferItem) {
        guard let url = item.localURL, item.state == .completed else { return }
        preview = FilePreview(url: url, title: item.name)
    }

    func showInfo(_ entry: FileEntry) {
        let full = joined(entry.name)
        let canWrite = shareAllowsUploads(full)
        fileInfo = FileInfo(entry: entry, path: full, writable: canWrite)
        Task {
            let detailed: FileEntry?
            if let demoFiles, let virtual = try? VirtualPath.parse(full) {
                detailed = try? await demoFiles.stat(path: virtual)
            } else {
                detailed = try? await connection?.stat(path: full)
            }
            if let detailed, self.fileInfo?.path == full {
                self.fileInfo = FileInfo(entry: detailed, path: full, writable: canWrite)
            }
        }
    }

    func clearCompleted() {
        transfers.removeAll { $0.state != .active }
    }

    func removeTransfer(_ item: TransferItem) {
        guard item.state != .active else { return }
        transfers.removeAll { $0.id == item.id }
    }

    func removeTransfers(_ ids: Set<UUID>) {
        transfers.removeAll { ids.contains($0.id) && $0.state != .active }
    }

    func goUp() async {
        guard path != "/" else { return }
        let virtual = (try? VirtualPath.parse(path)) ?? .root
        path = virtual.parent.string
        selection.removeAll()
        try? await refresh()
    }

    func go(to ancestor: String) async {
        path = ancestor
        selection.removeAll()
        try? await refresh()
    }

    var ancestors: [String] {
        guard let virtual = try? VirtualPath.parse(path) else { return ["/"] }
        var paths = ["/"]
        var current: [String] = []
        for part in virtual.components {
            current.append(part)
            paths.append(VirtualPath(components: current).string)
        }
        return paths
    }

    var isFileSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sortedEntries: [FileEntry] {
        let filtered: [FileEntry]
        if isFileSearching {
            // While a global walk runs, keep showing local matches so the list does not go blank.
            filtered = entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        } else {
            filtered = entries
        }
        return filtered.sorted { lhs, rhs in
            if lhs.kind == .dir, rhs.kind != .dir { return true }
            if rhs.kind == .dir, lhs.kind != .dir { return false }
            switch sort {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date: return lhs.mtime > rhs.mtime
            case .size: return lhs.size > rhs.size
            case .kind: return lhs.name.split(separator: ".").last ?? "" < rhs.name.split(separator: ".").last ?? ""
            }
        }
    }

    func updateFileSearch(_ text: String) {
        searchText = text
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        fileSearchToken += 1
        let token = fileSearchToken
        guard !query.isEmpty else {
            fileSearchHits = []
            fileSearchRunning = false
            return
        }
        fileSearchRunning = true
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard token == fileSearchToken else { return }
            let hits = await searchFiles(query: query)
            guard token == fileSearchToken else { return }
            fileSearchHits = hits
            fileSearchRunning = false
        }
    }

    func openSearchHit(_ hit: FileSearchHit) async {
        if hit.entry.kind == .dir {
            clearFileSearch()
            path = hit.path
            selection.removeAll()
            try? await refresh()
            return
        }
        let parent = hit.folder
        if path != parent {
            path = parent
            try? await refresh()
        }
        download(hit.entry, preview: true)
    }

    func clearFileSearch() {
        fileSearchToken += 1
        searchText = ""
        fileSearchHits = []
        fileSearchRunning = false
    }

    private func searchFiles(query: String) async -> [FileSearchHit] {
        // Capture Sendable backends only — do not close over MainActor `self`.
        let connection = connection
        let demoFiles = demoFiles
        do {
            return try await FileSearch.find(
                pattern: query,
                root: .root,
                match: .substring,
                includeDirectories: true,
                list: { virtual in
                    if let demoFiles {
                        return (try? await demoFiles.list(
                            path: virtual,
                            offset: 0,
                            limit: 1000,
                            includeHidden: false
                        )) ?? []
                    }
                    return (try? await connection?.list(path: virtual.string, includeHidden: false)) ?? []
                }
            )
        } catch {
            return []
        }
    }

    var folderTitle: String {
        if path == "/" { return hostName.isEmpty ? L10n.files : hostName }
        return (try? VirtualPath.parse(path))?.components.last ?? hostName
    }

    var currentShareWritable: Bool {
        shareAllowsUploads(path)
    }

    private func shareAllowsUploads(_ fullPath: String) -> Bool {
        guard let share = (try? VirtualPath.parse(fullPath))?.components.first else { return false }
        return shares.first { $0.name == share }?.writable ?? false
    }

    func runTerminal(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        showCommandHelp = false
        if let program = AgentPrograms.programName(in: trimmed) {
            history.append(trimmed)
            historyIndex = history.count
            terminalLines.append(TermLine(text: prompt + trimmed, kind: .input))
            guard connection != nil, demoFiles == nil else {
                terminalLines.append(TermLine(text: L10n.agentNeedsMac(AgentPrograms.displayName(program)), kind: .error))
                return
            }
            beginAgent(line: trimmed, program: program)
            return
        }
        history.append(trimmed)
        historyIndex = history.count
        terminalLines.append(TermLine(text: prompt + trimmed, kind: .input))
        if trimmed == "clear" {
            terminalLines = []
            return
        }
        if trimmed == "exit" {
            return
        }
        if trimmed == "help" || trimmed.hasPrefix("help ") {
            showCommandHelp = true
        }
        let epoch = terminalEpoch
        terminalBusy = true
        defer { if epoch == terminalEpoch { terminalBusy = false } }
        do {
            let result: TerminalResult
            if let demoFiles {
                let profile = SystemDemo.profile(host: hostName.isEmpty ? "Demo Mac" : hostName, shares: max(shares.count, 1))
                let context = TerminalContext(user: profile.user, host: profile.host, device: deviceName, profile: profile)
                result = await TerminalEngine().execute(line: trimmed, cwd: terminalCWD, files: demoFiles, context: context)
            } else if let connection {
                result = try await connection.exec(cwd: terminalCWD, line: trimmed)
            } else {
                terminalLines.append(TermLine(text: "Not connected.", kind: .error))
                return
            }
            guard epoch == terminalEpoch else { return }
            terminalCWD = result.cwd
            if result.action?.type == "fetch" {
                openFetchSlot(text: result.stdout)
            } else if showCommandHelp {
                // Interactive catalog already shows syntax; skip the long dump on a small screen.
                appendOutput("Tap a command below for syntax and flags. Scroll the list for every command.\n", kind: .dim)
            } else {
                appendOutput(result.stdout, kind: .output)
            }
            appendOutput(result.stderr, kind: .error)
            if mutatesFolder(trimmed), result.exit == 0 {
                invalidateCompletionCache()
            }
            if let action = result.action, action.type != "fetch" {
                await perform(action)
            }
        } catch {
            guard epoch == terminalEpoch else { return }
            terminalLines.append(TermLine(text: (error as? ProtocolFailure)?.message ?? "Couldn't run that.", kind: .error))
        }
    }

    /// Tab completion: rewrites the line when possible and returns remaining choices for the dropdown.
    func completeTerminalLine(_ line: String) async -> (line: String, hint: String, suggestions: [CompletionSuggestion]) {
        let request = LineCompletion.request(line: line, cwd: terminalCWD)
        let names = await completionNames(for: request)
        let outcome = LineCompletion.complete(
            line: line,
            request: request,
            names: names,
            commands: TerminalEngine.commandNames
        )
        return (outcome.line, outcome.hint, outcome.suggestions)
    }

    /// Live suggestion list for the current draft (no rewrite unless the caller applies a pick).
    func terminalSuggestions(for line: String) async -> [CompletionSuggestion] {
        guard shouldOfferSuggestions(for: line) else { return [] }
        let request = LineCompletion.request(line: line, cwd: terminalCWD)
        let names = await completionNames(for: request)
        return LineCompletion.suggestions(
            request: request,
            names: names,
            commands: TerminalEngine.commandNames
        )
    }

    func applyTerminalSuggestion(_ suggestion: CompletionSuggestion, to line: String) -> String {
        let request = LineCompletion.request(line: line, cwd: terminalCWD)
        return LineCompletion.apply(line: line, request: request, suggestion: suggestion)
    }

    func applyCommandHelp(_ entry: CommandHelp) -> String {
        showCommandHelp = false
        return entry.insertPrefix
    }

    func dismissCommandHelp() {
        showCommandHelp = false
    }

    func shouldOfferSuggestions(for line: String) -> Bool {
        let request = LineCompletion.request(line: line, cwd: terminalCWD)
        if request.listsFiles { return true }
        return !request.prefix.isEmpty
    }

    private func completionNames(for request: CompletionRequest) async -> [CompletionName] {
        guard request.listsFiles else { return [] }
        let hidden = request.prefix.hasPrefix(".")
        let key = "\(request.directory)\0\(hidden ? "1" : "0")"
        let now = ContinuousClock.now
        if let cached = completionListCache[key], now - cached.at < completionListTTL {
            return cached.names
        }
        let entries = await listFolder(request.directory, includeHidden: hidden)
        let names = entries.map { CompletionName(name: $0.name, isDirectory: $0.kind == .dir) }
        completionListCache[key] = (now, names)
        return names
    }

    func invalidateCompletionCache() {
        completionListCache.removeAll(keepingCapacity: true)
    }

    private func mutatesFolder(_ line: String) -> Bool {
        let first = line.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        return ["mkdir", "rm", "rmdir", "mv", "cp", "touch", "put"].contains(first)
    }

    func interruptTerminal() {
        guard terminalBusy else { return }
        terminalEpoch += 1
        terminalBusy = false
        terminalLines.append(TermLine(text: "^C", kind: .dim))
    }

    func clearTerminal() {
        terminalLines = []
    }

    func noteAgentLayout(columns: Int, rows: Int) {
        guard let slot = focusedSlot, slot.kind == .agent, !slot.agentExited else { return }
        // Keep the last real size when another root tab or slot collapses the view.
        if sessionTab != SessionTabIndex.terminal { return }
        let columns = min(200, max(2, columns))
        let rows = min(80, max(2, rows))
        if slot.agentSurface != nil, columns < 10 || rows < 3 { return }
        let changed = slot.agentSurface == nil || columns != slot.agentColumns || rows != slot.agentRows
        slot.agentColumns = columns
        slot.agentRows = rows
        if let surface = slot.agentSurface {
            if changed {
                surface.screen.resize(columns: columns, rows: rows)
                agentFrame += 1
            }
        } else {
            slot.agentSurface = AgentSurface(screen: VTScreen(columns: columns, rows: rows))
            agentFrame += 1
            drainAgentPending(slot)
        }
        if let id = slot.agentSessionID {
            guard changed else { return }
            Task { try? await self.connection?.resizeTerminal(session: id, columns: columns, rows: rows) }
            return
        }
        guard slot.agentOpenTask == nil else { return }
        let slotID = slot.id
        slot.agentOpenTask = Task { await self.openAgentSession(slotID: slotID) }
    }

    func sendAgentInput(_ input: VTInput) {
        guard let slot = focusedSlot, slot.kind == .agent, !slot.agentExited else { return }
        let screen = slot.agentSurface?.screen ?? VTScreen(columns: slot.agentColumns, rows: slot.agentRows)
        let data = VTKeys.encode(input, applicationCursor: screen.applicationCursorKeys, bracketedPaste: screen.bracketedPaste)
        guard !data.isEmpty else { return }
        slot.agentWriteFailures = 0
        slot.agentOutbound.append(data)
        guard slot.agentSessionID != nil else { return }
        scheduleAgentWrite(slot)
    }

    func finishAgent() async {
        guard let slot = focusedSlot, slot.kind == .agent else { return }
        await endAgentSlot(slot, dumpToVirtual: true)
    }

    func focusSlot(id: String) {
        guard terminalSlots.contains(where: { $0.id == id }) else { return }
        focusedSlotID = id
        bumpSlots()
        syncMonitorPolling()
        publishAgentLiveActivity(force: true)
    }

    func addTerminalSlot() {
        guard TerminalSlotBook.canAdd(count: terminalSlots.count) else {
            notice = "Close a terminal first. You can keep up to \(TerminalSlotBook.maxSlots) open."
            return
        }
        let slot = TerminalSlotState.virtualWelcome(text: L10n.termWelcome)
        terminalSlots.append(slot)
        focusedSlotID = slot.id
        bumpSlots()
        syncMonitorPolling()
    }

    func reorderTerminalSlots(from: Int, to: Int) {
        guard terminalSlots.indices.contains(from), terminalSlots.indices.contains(to), from != to else { return }
        let item = terminalSlots.remove(at: from)
        terminalSlots.insert(item, at: to)
        bumpSlots()
        rememberAgents()
    }

    func closeFocusedSlot() {
        guard let slot = focusedSlot else { return }
        if slot.kind == .agent {
            if slot.isLiveAgent {
                Task { await self.endAgentSlot(slot, dumpToVirtual: true) }
            } else {
                removeSlot(id: slot.id)
            }
            return
        }
        if terminalSlots.count == 1, slot.kind == .virtual {
            sessionTab = SessionTabIndex.files
            return
        }
        removeSlot(id: slot.id)
    }

    func closeMonitorSlot() {
        guard let slot = terminalSlots.first(where: { $0.kind == .monitor }) else { return }
        removeSlot(id: slot.id)
    }

    private func bumpSlots() {
        slotEpoch += 1
    }

    private func resetTerminalSlots() {
        monitorPollTask?.cancel()
        monitorPollTask = nil
        let welcome = TerminalSlotState.virtualWelcome(text: L10n.termWelcome)
        terminalSlots = [welcome]
        focusedSlotID = welcome.id
        bumpSlots()
    }

    private func removeSlot(id: String) {
        let metas = terminalSlots.map(\.meta)
        if let result = TerminalSlotBook.close(slots: metas, focused: focusedSlotID, id: id) {
            terminalSlots.removeAll { $0.id == id }
            if terminalSlots.isEmpty {
                let welcome = TerminalSlotState.virtualWelcome(text: L10n.termWelcome)
                terminalSlots = [welcome]
                focusedSlotID = welcome.id
            } else {
                focusedSlotID = result.focused
            }
            bumpSlots()
            syncMonitorPolling()
            rememberAgents()
            return
        }
        guard terminalSlots.contains(where: { $0.id == id && $0.kind == .agent }) else { return }
        let result = TerminalSlotBook.removeAgent(slots: metas, focused: focusedSlotID, id: id)
        terminalSlots.removeAll { $0.id == id }
        if terminalSlots.isEmpty {
            let welcome = TerminalSlotState.virtualWelcome(text: L10n.termWelcome)
            terminalSlots = [welcome]
            focusedSlotID = welcome.id
        } else {
            focusedSlotID = result.focused
        }
        bumpSlots()
        syncMonitorPolling()
        rememberAgents()
    }

    private func endAgentSlot(_ slot: TerminalSlotState, dumpToVirtual: Bool) async {
        slot.agentOpenTask?.cancel()
        slot.agentOpenTask = nil
        let program = slot.agentProgram
        let text = slot.agentSurface?.screen.plainText() ?? ""
        let code = slot.agentExitCode
        let error = slot.agentError
        if let id = slot.agentSessionID {
            await connection?.closeTerminal(session: id)
        }
        slot.agentExited = true
        publishAgentLiveActivity(force: true)
        let slotID = slot.id
        clearAgentSlot(slot)
        removeSlot(id: slotID)
        guard dumpToVirtual, let program else { return }
        // Ensure a virtual slot is focused to receive the transcript dump.
        if focusedSlot?.kind != .virtual {
            if let virtual = terminalSlots.first(where: { $0.kind == .virtual }) {
                focusSlot(id: virtual.id)
            } else if TerminalSlotBook.canAdd(count: terminalSlots.count) {
                addTerminalSlot()
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { appendOutput(trimmed + "\n", kind: .output) }
        if let error {
            terminalLines.append(TermLine(text: error, kind: .error))
        }
        let suffix = code == 0 ? "" : " (\(code))"
        terminalLines.append(TermLine(text: "\(AgentPrograms.displayName(program)) ended\(suffix)", kind: .dim))
    }

    private func beginAgent(line: String, program: String) {
        guard let slot = focusedSlot, slot.kind == .virtual else {
            notice = "Switch to a shell tab to start an agent."
            return
        }
        let metas = terminalSlots.map(\.meta)
        guard TerminalSlotBook.canOpenAgent(slots: metas, convertingSlotID: slot.id) else {
            terminalLines.append(TermLine(text: "Close a terminal first. You can keep up to \(TerminalSlotBook.maxSlots) open.", kind: .error))
            return
        }
        slot.agentOpenTask?.cancel()
        slot.agentOpenTask = nil
        slot.kind = .agent
        slot.agentLine = line
        slot.agentProgram = program
        slot.agentHostID = hostId
        slot.agentSessionID = nil
        slot.agentPaused = false
        slot.agentGeneration += 1
        slot.agentFlushScheduled = false
        slot.agentLastPaint = ContinuousClock.now.advanced(by: .seconds(-5))
        slot.agentLastByteAt = ContinuousClock.now.advanced(by: .seconds(-5))
        slot.agentSurface = nil
        slot.agentExited = false
        slot.agentExitCode = 0
        slot.agentError = nil
        slot.agentReceived = false
        slot.agentPending.removeAll()
        slot.agentOutbound.removeAll()
        slot.agentColumns = 80
        slot.agentRows = 24
        slot.agentNeedsYou = false
        bumpSlots()
        rememberAgents()
        publishAgentLiveActivity(force: true)
    }

    private func openAgentSession(slotID: String) async {
        guard let slot = terminalSlots.first(where: { $0.id == slotID }) else { return }
        defer { slot.agentOpenTask = nil }
        guard let connection, let line = slot.agentLine, slot.agentSessionID == nil, slot.agentProgram != nil else { return }
        let columns = slot.agentColumns
        let rows = slot.agentRows
        let cwd = slot.cwd
        do {
            let id = try await connection.openTerminal(line: line, cwd: cwd, columns: columns, rows: rows)
            guard slot.agentProgram != nil else {
                await connection.closeTerminal(session: id)
                return
            }
            slot.agentSessionID = id
            rememberAgents()
            if let early = agentEarly.removeValue(forKey: id) {
                applyAgentBytes(early, to: slot)
            }
            if let code = agentEarlyExit.removeValue(forKey: id) {
                slot.agentExitCode = code
                slot.agentExited = true
            }
            if !slot.agentExited, (slot.agentColumns != columns || slot.agentRows != rows) {
                try? await connection.resizeTerminal(session: id, columns: slot.agentColumns, rows: slot.agentRows)
            }
            scheduleAgentWrite(slot)
        } catch {
            slot.agentExited = true
            slot.agentError = (error as? ProtocolFailure)?.message ?? "Couldn't open a terminal on this Mac."
            bumpSlots()
        }
    }

    private func handleAgentEvent(_ message: WireMessage) {
        guard let id = message.header.session else { return }
        switch message.header.op {
        case Op.termData:
            if let slot = terminalSlots.first(where: { $0.agentSessionID == id }) {
                applyAgentBytes(message.body, to: slot)
            } else if terminalSlots.contains(where: { $0.kind == .agent && $0.agentSessionID == nil && $0.agentProgram != nil }) {
                var existing = agentEarly[id] ?? Data()
                existing.append(message.body)
                agentEarly[id] = existing
            }
        case Op.termExit:
            let code = message.header.exit ?? 0
            if let slot = terminalSlots.first(where: { $0.agentSessionID == id }) {
                slot.agentExitCode = code
                slot.agentExited = true
                bumpSlots()
                publishAgentLiveActivity(force: true)
            } else if terminalSlots.contains(where: { $0.kind == .agent && $0.agentSessionID == nil && $0.agentProgram != nil }) {
                agentEarlyExit[id] = code
            }
        default:
            break
        }
    }

    private func applyAgentBytes(_ data: Data, to slot: TerminalSlotState) {
        guard !data.isEmpty else { return }
        slot.agentReceived = true
        slot.agentLastByteAt = ContinuousClock.now
        guard let surface = slot.agentSurface else {
            slot.agentPending.append(data)
            return
        }
        let replies = surface.screen.ingest(data)
        if !replies.isEmpty {
            var combined = replies
            combined.append(slot.agentOutbound)
            slot.agentOutbound = combined
            scheduleAgentWrite(slot)
        }
        let tail = AgentScreenHint.tail(from: surface.screen.plainText())
        let reading = AgentScreenHint.reading(title: surface.screen.title, screenTail: tail)
        if reading.wantsAttention {
            slot.agentNeedsYou = true
        }
        scheduleAgentPublish(slot)
    }

    private func drainAgentPending(_ slot: TerminalSlotState) {
        let chunk = slot.agentPending
        slot.agentPending.removeAll(keepingCapacity: true)
        guard !chunk.isEmpty else { return }
        applyAgentBytes(chunk, to: slot)
    }

    private func scheduleAgentPublish(_ slot: TerminalSlotState) {
        let generation = slot.agentGeneration
        let slotID = slot.id
        let now = ContinuousClock.now
        let elapsed = slot.agentLastPaint.duration(to: now)
        if !slot.agentFlushScheduled, elapsed >= .milliseconds(8) {
            slot.agentLastPaint = now
            agentFrame += 1
            publishAgentLiveActivity()
            return
        }
        guard !slot.agentFlushScheduled else { return }
        slot.agentFlushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(12))
            guard let current = self.terminalSlots.first(where: { $0.id == slotID }) else { return }
            guard generation == current.agentGeneration else { return }
            current.agentFlushScheduled = false
            guard current.agentSurface != nil else { return }
            current.agentLastPaint = ContinuousClock.now
            self.agentFrame += 1
            self.publishAgentLiveActivity()
        }
    }

    private func scheduleAgentWrite(_ slot: TerminalSlotState) {
        guard !slot.agentWriteScheduled else { return }
        slot.agentWriteScheduled = true
        let slotID = slot.id
        let previous = slot.agentWriteChain
        slot.agentWriteChain = Task { @MainActor in
            _ = await previous.value
            await Task.yield()
            guard let current = self.terminalSlots.first(where: { $0.id == slotID }) else { return }
            current.agentWriteScheduled = false
            let payload = current.agentOutbound
            current.agentOutbound.removeAll(keepingCapacity: true)
            guard !payload.isEmpty, !current.agentExited else { return }
            if let id = current.agentSessionID, let connection = self.connection {
                do {
                    try await connection.writeTerminal(session: id, data: payload)
                    current.agentWriteFailures = 0
                } catch {
                    var combined = payload
                    combined.append(current.agentOutbound)
                    current.agentOutbound = combined
                    current.agentWriteFailures += 1
                    guard current.agentWriteFailures < 4, !current.agentExited else { return }
                    try? await Task.sleep(for: .milliseconds(40))
                    if !current.agentOutbound.isEmpty { self.scheduleAgentWrite(current) }
                    return
                }
            } else if current.agentProgram != nil {
                var combined = payload
                combined.append(current.agentOutbound)
                current.agentOutbound = combined
                return
            }
            if !current.agentOutbound.isEmpty { self.scheduleAgentWrite(current) }
        }
    }

    private func clearAgentSlot(_ slot: TerminalSlotState) {
        slot.agentOpenTask?.cancel()
        slot.agentOpenTask = nil
        slot.agentIdlePublishTask?.cancel()
        slot.agentIdlePublishTask = nil
        slot.agentProgram = nil
        slot.agentLine = nil
        slot.agentSessionID = nil
        slot.agentGeneration += 1
        slot.agentFlushScheduled = false
        slot.agentLastPaint = ContinuousClock.now.advanced(by: .seconds(-5))
        slot.agentSurface = nil
        slot.agentExited = false
        slot.agentExitCode = 0
        slot.agentError = nil
        slot.agentReceived = false
        slot.agentPending.removeAll()
        slot.agentOutbound.removeAll()
        slot.agentPaused = false
        slot.agentHostID = nil
        slot.agentNeedsYou = false
        slot.kind = .virtual
    }

    private func clearAllAgents(keepSlots: Bool) {
        for slot in terminalSlots where slot.kind == .agent {
            clearAgentSlot(slot)
        }
        agentEarly.removeAll()
        agentEarlyExit.removeAll()
        UserDefaults.standard.removeObject(forKey: "agent.sessions")
        UserDefaults.standard.removeObject(forKey: "agent.session")
        if !keepSlots {
            resetTerminalSlots()
        } else {
            bumpSlots()
        }
        #if canImport(ActivityKit)
        LiveActivityCoordinator.shared.syncAgent(
            program: nil,
            displayName: nil,
            received: false,
            paused: false,
            exited: false,
            title: nil,
            recentlyWrote: false,
            hostName: hostName,
            force: true
        )
        #endif
    }

    /// Drop terminals that belong to another Mac when the connected host changes.
    private func adoptConnectedHost(_ id: String, previousHost: String, resettingPath: Bool) {
        if !previousHost.isEmpty, previousHost != id {
            clearAllAgents(keepSlots: false)
        }
        if resettingPath {
            path = "/"
            if !hasLiveAgent {
                resetTerminalSlots()
            }
        }
    }

    private func rememberAgents() {
        // Persist session ids and program names only — never the full launch line (flags / tokens).
        let payloads: [[String: String]] = terminalSlots.compactMap { slot in
            guard slot.kind == .agent,
                  let id = slot.agentSessionID,
                  let program = slot.agentProgram else { return nil }
            return [
                "id": id,
                "program": program,
                "cwd": slot.cwd,
                "host": slot.agentHostID ?? hostId,
                "slot": slot.id,
            ]
        }
        if payloads.isEmpty {
            UserDefaults.standard.removeObject(forKey: "agent.sessions")
            UserDefaults.standard.removeObject(forKey: "agent.session")
        } else {
            UserDefaults.standard.set(payloads, forKey: "agent.sessions")
            UserDefaults.standard.set(payloads[0], forKey: "agent.session")
        }
    }

    private func restoreAgents() {
        let defaults = UserDefaults.standard
        let payloads: [[String: String]]
        if let list = defaults.array(forKey: "agent.sessions") as? [[String: String]], !list.isEmpty {
            payloads = list
        } else if let single = defaults.dictionary(forKey: "agent.session") as? [String: String] {
            payloads = [single]
        } else {
            return
        }
        var restored: [TerminalSlotState] = []
        for payload in payloads.prefix(TerminalSlotBook.maxAgents) {
            guard let id = payload["id"], let program = payload["program"],
                  let host = payload["host"] else { continue }
            let slot = TerminalSlotState(id: payload["slot"] ?? UUID().uuidString, kind: .agent, cwd: payload["cwd"] ?? "/")
            slot.agentSessionID = id
            slot.agentProgram = program
            // Resume uses the session id; keep a bare program name for UI only.
            slot.agentLine = payload["line"].flatMap { AgentPrograms.programName(in: $0) } ?? program
            slot.agentHostID = host
            slot.agentPaused = true
            slot.agentReceived = true
            slot.agentSurface = AgentSurface(screen: VTScreen(columns: slot.agentColumns, rows: slot.agentRows))
            restored.append(slot)
        }
        guard !restored.isEmpty else { return }
        if TerminalSlotBook.canAdd(count: restored.count) {
            restored.insert(TerminalSlotState.virtualWelcome(text: L10n.termWelcome), at: 0)
        }
        terminalSlots = Array(restored.prefix(TerminalSlotBook.maxSlots))
        focusedSlotID = terminalSlots.first(where: { $0.kind == .agent })?.id ?? terminalSlots[0].id
        agentFrame += 1
        bumpSlots()
        publishAgentLiveActivity(force: true)
    }

    private func resumeAgentsIfNeeded(host: String) async {
        for slot in terminalSlots where slot.kind == .agent {
            await resumeAgent(slot, host: host)
        }
    }

    private func resumeAgent(_ slot: TerminalSlotState, host: String) async {
        guard slot.agentHostID == host, let connection, let id = slot.agentSessionID,
              slot.agentProgram != nil, !slot.agentExited else { return }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await connection.resumeTerminal(session: id)
                try? await connection.resizeTerminal(session: id, columns: slot.agentColumns, rows: slot.agentRows)
                slot.agentWriteFailures = 0
                slot.agentPaused = false
                rememberAgents()
                scheduleAgentWrite(slot)
                bumpSlots()
                publishAgentLiveActivity(force: true)
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
                    guard self.connection === connection, !slot.agentExited else { return }
                }
            }
        }
        slot.agentPaused = false
        slot.agentExited = true
        slot.agentSessionID = nil
        slot.agentError = (lastError as? ProtocolFailure)?.message ?? "That session on your Mac has ended."
        rememberAgents()
        bumpSlots()
        publishAgentLiveActivity(force: true)
    }

    private func openMonitorSlot() {
        let metas = terminalSlots.map(\.meta)
        guard let result = TerminalSlotBook.openOrFocus(
            slots: metas,
            focused: focusedSlotID,
            kind: .monitor,
            title: "Monitor"
        ) else {
            notice = "Close a terminal first. You can keep up to \(TerminalSlotBook.maxSlots) open."
            return
        }
        if TerminalSlotBook.first(of: .monitor, in: metas) == nil {
            let slot = TerminalSlotState(id: result.focused, kind: .monitor)
            terminalSlots.append(slot)
        }
        focusedSlotID = result.focused
        monitorProfile = nil
        monitorStats = nil
        monitorBytesIn = nil
        monitorBytesOut = nil
        monitorSampledAt = nil
        monitorMessage = nil
        bumpSlots()
        syncMonitorPolling()
    }

    private func openFetchSlot(text: String) {
        let metas = terminalSlots.map(\.meta)
        guard let result = TerminalSlotBook.openOrFocus(
            slots: metas,
            focused: focusedSlotID,
            kind: .fetch,
            title: "fetch"
        ) else {
            notice = "Close a terminal first. You can keep up to \(TerminalSlotBook.maxSlots) open."
            return
        }
        if let existing = terminalSlots.first(where: { $0.kind == .fetch }) {
            existing.fetchText = text
            focusedSlotID = existing.id
        } else {
            let slot = TerminalSlotState(id: result.focused, kind: .fetch)
            slot.fetchText = text
            terminalSlots.append(slot)
            focusedSlotID = slot.id
        }
        bumpSlots()
        syncMonitorPolling()
    }

    func syncMonitorPolling() {
        let shouldPoll = sessionTab == SessionTabIndex.terminal && focusedSlot?.kind == .monitor
        if shouldPoll {
            guard monitorPollTask == nil else { return }
            monitorPollTask = Task { @MainActor in
                while !Task.isCancelled {
                    guard self.sessionTab == SessionTabIndex.terminal, self.focusedSlot?.kind == .monitor else { break }
                    await self.refreshMonitor()
                    try? await Task.sleep(for: .seconds(1.5))
                }
                self.monitorPollTask = nil
            }
        } else {
            monitorPollTask?.cancel()
            monitorPollTask = nil
        }
    }


    func thumbnail(for entry: FileEntry) async -> Data? {
        guard entry.kind != .dir else { return nil }
        let full = joined(entry.name)
        if let cached = thumbnailCache[full] { return cached }
        let data: Data?
        if let demoFiles {
            guard entry.name.lowercased().hasSuffix("jpg") || entry.name.lowercased().hasSuffix("jpeg") else { return nil }
            data = try? await demoFiles.read(path: VirtualPath.parse(full), offset: 0, length: 256 * 1024).data
        } else {
            data = try? await connection?.thumbnail(path: full, maxPixel: 200)
        }
        if let data, !data.isEmpty {
            if thumbnailCache.count > 100 { thumbnailCache.removeAll() }
            thumbnailCache[full] = data
        }
        return data
    }

    func clearCache() {
        let folder = cacheDirectory
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cacheBytes = 0
    }

    func saveToDocuments(_ url: URL) throws -> URL {
        let folder = documentsDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func copyToDocuments(from url: URL, relative: String) throws {
        let destination = documentsFile(relative: relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
    }

    private func documentsFile(relative: String) -> URL {
        relative.split(separator: "/").reduce(documentsDirectory) { partial, part in
            partial.appendingPathComponent(String(part))
        }
    }

    func sceneBecameActive() {
        if !showPrimer { startPhoneListener() }
        guard connected, activeHost != nil, !demoMode, !intentionalDisconnect else { return }
        if let connection {
            Task { [weak self] in
                let alive = await connection.checkAlive()
                guard let self, !alive else { return }
                await MainActor.run {
                    self.handleDisconnect(from: connection)
                }
            }
            return
        }
        reconnecting = true
        scheduleReconnect()
    }

    func beginBackgroundTaskIfNeeded() -> UIBackgroundTaskIdentifier {
        guard !activeTransfers.isEmpty || hasLiveAgent else { return .invalid }
        var token: UIBackgroundTaskIdentifier = .invalid
        token = UIApplication.shared.beginBackgroundTask {
            Task { @MainActor in
                for index in self.transfers.indices where self.transfers[index].state == .active {
                    self.transfers[index].state = .failed
                    self.transfers[index].message = L10n.keepOpen
                }
                #if canImport(ActivityKit)
                LiveActivityCoordinator.shared.markBackgroundExpired(
                    transfers: &self.transfers,
                    hostName: self.hostName,
                    hasLiveAgent: self.hasLiveAgent
                )
                #endif
                UIApplication.shared.endBackgroundTask(token)
            }
        }
        return token
    }

    func openDeepLink(_ url: URL) {
        guard url.scheme == TetherDeepLink.scheme else { return }
        switch url.host {
        case "transfers":
            sessionTab = SessionTabIndex.transfers
        case "send":
            sessionTab = SessionTabIndex.send
            Task { await processPendingShareInbox() }
        case "terminal":
            sessionTab = SessionTabIndex.terminal
            if let target = TerminalSlotBook.islandAgent(
                slots: terminalSlots.map(\.meta),
                focused: focusedSlotID
            ) {
                focusSlot(id: target.id)
            }
        default:
            break
        }
    }

    /// Drains files staged by the Share Extension into the Mac Inbox.
    func processPendingShareInbox() async {
        guard ShareInboxQueue.hasPending() else { return }
        if !connected && !demoMode {
            statusMessage = "Connect to your Mac to finish sending."
            sessionTab = SessionTabIndex.send
            return
        }
        let pending: [URL]
        do {
            pending = try ShareInboxQueue.drainPending()
        } catch {
            return
        }
        for url in pending {
            await sendToInbox(url: url)
            ShareInboxQueue.remove(url)
        }
    }

    var prompt: String { "\(hostName.isEmpty ? "mac" : hostName):\(terminalCWD) $ " }

    private func attach(_ session: ClientConnection) async {
        let previous = connection
        await session.setDisconnectHandler { [weak self] in
            Task { @MainActor in self?.handleDisconnect(from: session) }
        }
        await session.setEventHandler { [weak self] message in
            Task { @MainActor in self?.handleAgentEvent(message) }
        }
        connection = session
        if let previous {
            await previous.setDisconnectHandler(nil)
            await previous.close()
        }
    }

    private func startPathMonitor() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let fingerprint = Self.pathFingerprint(path)
            Task { @MainActor in
                self?.pathDidChange(fingerprint)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.tether.path", qos: .utility))
    }

    /// Pure; safe to call from the path-monitor queue (not MainActor).
    private nonisolated static func pathFingerprint(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        return "\(path.status)==\(interfaces)"
    }

    private func pathDidChange(_ fingerprint: String) {
        let previous = lastPathFingerprint
        lastPathFingerprint = fingerprint
        guard previous != nil, previous != fingerprint else { return }
        guard connected, !intentionalDisconnect, !demoMode else { return }
        if let connection {
            Task { [weak self] in
                let alive = await connection.checkAlive(timeout: .seconds(2))
                guard let self, !alive else { return }
                await MainActor.run { self.handleDisconnect(from: connection) }
            }
        } else if reconnecting {
            scheduleReconnect()
        }
    }

    private func syncPreventSleepPreference() async {
        guard let connection else { return }
        guard let current = try? await connection.hostPrefs() else { return }
        preventSleepWhileActive = current
        UserDefaults.standard.set(current, forKey: "preventSleepWhileActive")
    }


    private func enableDemo() {
        let files = MemoryFileProvider()
        files.addShare(name: InboxShare.name, writable: true)
        files.addShare(name: "Documents", writable: true)
        files.addShare(name: "Photos", writable: false)
        try? files.writeFile(path: "/Documents/Notes.txt", data: Data("Tether demo\nThis file lives only on this iPhone.\n".utf8))
        try? files.writeFile(path: "/Documents/Overview.pdf", data: DemoBytes.pdf)
        try? files.writeFile(path: "/Photos/Sample.jpg", data: DemoBytes.jpeg)
        demoFiles = files
        hostName = "Demo Mac"
        hostId = "demo"
        connected = true
        path = "/"
        resetTerminalSlots()
        Task { try? await refresh() }
    }

    private func cue(_ kind: FeedbackCue) {
        feedbackCue = kind
        feedbackTick += 1
    }

    private func handleDisconnect(from session: ClientConnection? = nil) {
        if let session, let current = connection, current !== session { return }
        invalidateCompletionCache()
        showCommandHelp = false
        clearFileSearch()
        connection = nil
        var pausedAny = false
        for slot in terminalSlots where slot.isLiveAgent {
            slot.agentPaused = true
            pausedAny = true
        }
        if pausedAny {
            bumpSlots()
            publishAgentLiveActivity(force: true)
        }
        guard connected, !intentionalDisconnect else { return }
        offline = true
        reconnecting = true
        statusMessage = "Reconnecting to \(hostName)…"
        cue(.warning)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                guard let self else { return }
                if self.connection != nil || !self.connected || self.intentionalDisconnect { return }
                if let host = self.activeHost {
                    await self.connect(host, restoring: true)
                }
                if self.connection != nil {
                    self.offline = false
                    self.reconnecting = false
                    self.statusMessage = nil
                    return
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
        }
    }

    func saveRemote(code: String) -> String? {
        guard let setup = RemoteSetup.decode(code) else {
            return "That code isn't valid. Copy it again from the Mac."
        }
        guard paired.contains(where: { $0.id == setup.hostId }) else {
            return "That code is for a Mac this iPhone hasn't paired with. Pair on Wi-Fi first."
        }
        RemoteBook.save(hostId: setup.hostId, setup: setup)
        reloadRemote()
        return nil
    }

    func clearRemote(_ hostId: String) {
        RemoteBook.clear(hostId: hostId)
        reloadRemote()
    }

    func remoteSummary(for hostId: String) -> String? {
        RemoteBook.summary(for: hostId)
    }

    private func reloadRemote() {
        remoteHostIDs = Set(paired.map(\.id).filter { RemoteBook.hasRoute(for: $0) })
    }

    private func openStream(for id: String, name: String) async throws -> any ByteStream {
        if let endpoint = bonjourEndpoint(for: id) {
            do {
                return try await TetherLink.connect(to: endpoint, allowsCellular: false, timeout: .seconds(8))
            } catch {
                guard remoteHostIDs.contains(id) else { throw error }
                return try await RemoteBook.connect(hostId: id)
            }
        }
        if remoteHostIDs.contains(id) {
            try? await Task.sleep(for: .milliseconds(400))
            if let endpoint = bonjourEndpoint(for: id) {
                return try await TetherLink.connect(to: endpoint, allowsCellular: false, timeout: .seconds(8))
            }
            return try await RemoteBook.connect(hostId: id)
        }
        guard let endpoint = await endpoint(for: id) else {
            throw ProtocolFailure(code: .internalError, message: L10n.unreachable(name))
        }
        return try await TetherLink.connect(to: endpoint, allowsCellular: false, timeout: .seconds(8))
    }

    private func remoteFailure(_ name: String, _ error: Error, remote: Bool) -> String {
        if let failure = error as? ProtocolFailure { return failure.message }
        if let relay = error as? RelayError {
            switch relay {
            case .busy:
                return "\(name) is busy with another remote connection. Try again in a moment."
            case .rejected:
                return "\(name) refused the remote code. Copy a new code from the Mac."
            case .unreachable, .badPrelude:
                return "Couldn't reach \(name). Check that the Mac is on and the remote code is still current."
            }
        }
        if remote {
            return "Couldn't reach \(name). Check that the Mac is on and the remote code is still current."
        }
        return L10n.unreachable(name)
    }

    private func bonjourEndpoint(for id: String) -> NWEndpoint? {
        if let match = discovered.first(where: { $0.matches(savedHostId: id) }) {
            return match.endpoint
        }
        if discovered.count == 1 { return discovered[0].endpoint }
        return nil
    }

    private func endpoint(for id: String) async -> NWEndpoint? {
        func found() -> NWEndpoint? {
            if let match = discovered.first(where: { $0.matches(savedHostId: id) }) {
                return match.endpoint
            }
            if discovered.count == 1 { return discovered[0].endpoint }
            return nil
        }
        if let endpoint = found() { return endpoint }
        refreshBrowser()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(400))
            if let endpoint = found() { return endpoint }
        }
        return nil
    }

    private func waitForEndpoint(hostId: String) async -> NWEndpoint? {
        if let found = discovered.first(where: { $0.hostId == hostId })?.endpoint { return found }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            if let found = discovered.first(where: { $0.hostId == hostId })?.endpoint { return found }
        }
        return discovered.count == 1 ? discovered.first?.endpoint : nil
    }

    private func joined(_ name: String) -> String {
        path == "/" ? "/\(name)" : path + "/" + name
    }

    private func updateTransfer(_ id: UUID, sent: UInt64, total: UInt64, state: TransferState, message: String? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        if transfers[index].message == "Cancelled", state == .active { return }
        transfers[index].sent = sent
        transfers[index].total = total
        transfers[index].state = state
        transfers[index].message = message
        publishTransferLiveActivity(force: state != .active)
    }

    private func publishTransferLiveActivity(force: Bool = false) {
        #if canImport(ActivityKit)
        LiveActivityCoordinator.shared.syncTransfers(
            items: transfers,
            hostName: hostName,
            force: force
        )
        #endif
    }

    private func publishAgentLiveActivity(force: Bool = false) {
        #if canImport(ActivityKit)
        let meta = TerminalSlotBook.islandAgent(
            slots: terminalSlots.map(\.meta),
            focused: focusedSlotID
        )
        guard let meta,
              let slot = terminalSlots.first(where: { $0.id == meta.id }),
              slot.kind == .agent else {
            LiveActivityCoordinator.shared.syncAgent(
                program: nil,
                displayName: nil,
                received: false,
                paused: false,
                exited: false,
                title: nil,
                recentlyWrote: false,
                hostName: hostName,
                force: force
            )
            return
        }
        let now = ContinuousClock.now
        let idleFor = slot.agentLastByteAt.duration(to: now)
        let recentlyWrote = idleFor < .milliseconds(400)
        let screenTail = slot.agentSurface.map { AgentScreenHint.tail(from: $0.screen.plainText()) }
        LiveActivityCoordinator.shared.syncAgent(
            program: slot.agentProgram,
            displayName: slot.agentProgram.map { AgentPrograms.displayName($0) },
            received: slot.agentReceived,
            paused: slot.agentPaused,
            exited: slot.agentExited,
            title: slot.agentSurface?.screen.title,
            recentlyWrote: recentlyWrote,
            idleFor: idleFor,
            screenTail: screenTail,
            hostName: hostName,
            force: force
        )
        if idleFor < .milliseconds(1_500) {
            scheduleAgentIdlePublish(slot)
        } else {
            slot.agentIdlePublishTask?.cancel()
            slot.agentIdlePublishTask = nil
        }
        #endif
    }

    /// Flip Island to Waiting once the PTY has been quiet — paint only runs on bytes.
    private func scheduleAgentIdlePublish(_ slot: TerminalSlotState) {
        #if canImport(ActivityKit)
        slot.agentIdlePublishTask?.cancel()
        guard slot.agentProgram != nil, !slot.agentExited, !slot.agentPaused else { return }
        let generation = slot.agentGeneration
        let byteStamp = slot.agentLastByteAt
        let slotID = slot.id
        slot.agentIdlePublishTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard !Task.isCancelled else { return }
            guard let current = self.terminalSlots.first(where: { $0.id == slotID }) else { return }
            guard generation == current.agentGeneration else { return }
            guard current.agentProgram != nil, !current.agentExited else { return }
            guard current.agentLastByteAt == byteStamp else { return }
            self.publishAgentLiveActivity(force: true)
        }
        #endif
    }

    private func appendOutput(_ text: String, kind: TermLine.Kind) {
        guard !text.isEmpty else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            let resolved: TermLine.Kind = value.hasSuffix("/") ? .directory : kind
            terminalLines.append(TermLine(text: value, kind: resolved))
        }
        if terminalLines.count > 2000 {
            terminalLines.removeFirst(terminalLines.count - 2000)
        }
    }

    func refreshMonitor() async {
        if demoFiles != nil || demoMode {
            monitorTick += 1
            let host = hostName.isEmpty ? "Demo Mac" : hostName
            monitorProfile = SystemDemo.profile(host: host, shares: max(shares.count, 1))
            applyMonitor(SystemDemo.stats(tick: monitorTick))
            monitorMessage = nil
            return
        }
        guard let connection else {
            monitorMessage = "Not connected."
            return
        }
        do {
            if monitorProfile == nil {
                monitorProfile = try await connection.systemProfile()
            }
            applyMonitor(try await connection.systemStats())
            monitorMessage = nil
        } catch {
            monitorMessage = (error as? ProtocolFailure)?.message ?? "Couldn't read the Mac."
        }
    }

    private func applyMonitor(_ stats: SystemStats) {
        let now = Date()
        if let beforeIn = monitorBytesIn, let beforeOut = monitorBytesOut, let then = monitorSampledAt {
            let elapsed = now.timeIntervalSince(then)
            if elapsed > 0.2, stats.bytesIn >= beforeIn, stats.bytesOut >= beforeOut {
                monitorDown = SystemText.rate(Double(stats.bytesIn - beforeIn) / elapsed)
                monitorUp = SystemText.rate(Double(stats.bytesOut - beforeOut) / elapsed)
            }
        }
        monitorBytesIn = stats.bytesIn
        monitorBytesOut = stats.bytesOut
        monitorSampledAt = now
        monitorStats = stats
    }

    private func perform(_ action: TerminalAction) async {
        switch action.type {
        case "clear":
            terminalLines = []
        case "exit":
            sessionTab = SessionTabIndex.files
        case "monitor":
            openMonitorSlot()
        case "fetch":
            break
        case "open", "preview", "get":
            guard let path = action.path, let virtual = try? VirtualPath.parse(path) else { return }
            let name = virtual.components.last ?? "file"
            let entry: FileEntry
            if let demoFiles, let found = try? await demoFiles.stat(path: virtual) {
                entry = found
            } else if let connection, let found = try? await connection.stat(path: path) {
                entry = found
            } else {
                return
            }
            let previous = self.path
            self.path = virtual.parent.string
            let previewing = action.type != "get"
            let saved = await fetch(
                entry: FileEntry(name: name, kind: entry.kind, size: entry.size, mtime: entry.mtime, uti: entry.uti, childCount: entry.childCount, created: entry.created),
                virtualPath: path,
                relativePath: name,
                preview: previewing,
                allowLarge: entry.size <= 100 * 1024 * 1024
            )
            if saved {
                if !previewing { notice = "Saved \(name) to the Files app." }
                cue(.success)
            }
            self.path = previous
        case "put":
            requestUpload = true
        default:
            break
        }
    }

    private func reloadPaired() {
        let records = (try? context.fetch(FetchDescriptor<PairedHostRecord>())) ?? []
        paired = records.map { PairedItem(id: $0.hostId, name: $0.name, pairedAt: $0.pairedAt, lastConnectedAt: $0.lastConnectedAt) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        recents = ((try? context.fetch(FetchDescriptor<RecentRecord>())) ?? []).sorted { $0.openedAt > $1.openedAt }
    }

    private func applyDiscoveredNames(_ hosts: [DiscoveredHost]) {
        for host in hosts {
            guard host.hasFriendlyName else { continue }
            guard let match = paired.first(where: { host.matches(savedHostId: $0.id) }), match.name != host.name else { continue }
            renamePaired(id: match.id, name: host.name)
        }
    }

    private func renamePaired(id: String, name: String) {
        let records = (try? context.fetch(FetchDescriptor<PairedHostRecord>())) ?? []
        guard let existing = records.first(where: { $0.hostId == id }) else { return }
        existing.name = name
        try? context.save()
        reloadPaired()
    }

    private func savePaired(id: String, name: String) {
        let records = (try? context.fetch(FetchDescriptor<PairedHostRecord>())) ?? []
        if let existing = records.first(where: { $0.hostId == id }) {
            existing.name = name
            existing.lastConnectedAt = Date()
        } else {
            context.insert(PairedHostRecord(hostId: id, name: name, lastConnectedAt: Date()))
        }
        try? context.save()
        reloadPaired()
    }

    private func touch(_ id: String) {
        let records = (try? context.fetch(FetchDescriptor<PairedHostRecord>())) ?? []
        if let record = records.first(where: { $0.hostId == id }) {
            record.lastConnectedAt = Date()
            try? context.save()
        }
    }

    private func remember(_ path: String) {
        context.insert(RecentRecord(hostId: hostId, path: path))
        try? context.save()
        reloadPaired()
    }

    private func cacheURL(host: String, path: String, size: UInt64, mtime: TimeInterval, fileName: String) -> URL {
        let key = "\(host)|\(path)|\(size)|\(mtime)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheDirectory.appendingPathComponent(digest, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        protectAtRest(folder)
        evictIfNeeded()
        let safe = (fileName as NSString).lastPathComponent
        return folder.appendingPathComponent(safe.isEmpty ? "File" : safe)
    }

    private var cacheDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tether", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        protectAtRest(url)
        return url
    }

    private var documentsDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Tether Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        protectAtRest(url)
        return url
    }

    /// Keep cached/downloaded bytes unavailable while the device is locked.
    private func protectAtRest(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private func refreshCacheSize() {
        cacheBytes = directorySize(cacheDirectory)
    }

    private func evictIfNeeded() {
        let limit: Int64 = 1_000_000_000
        guard directorySize(cacheDirectory) > limit else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = urls.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        var total = directorySize(cacheDirectory)
        for url in sorted where total > limit {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: url)
            total -= Int64(size)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private static func loadDeviceID() -> String {
        let defaultsKey = "tether.deviceId"
        if let saved = UserDefaults.standard.string(forKey: defaultsKey), !saved.isEmpty {
            PairingSecrets.save(service: ClientKeychain.service, account: "device-id", data: Data(saved.utf8))
            return saved
        }
        if let data = PairingSecrets.load(service: ClientKeychain.service, account: "device-id"),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            UserDefaults.standard.set(text, forKey: defaultsKey)
            return text
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: defaultsKey)
        PairingSecrets.save(service: ClientKeychain.service, account: "device-id", data: Data(id.utf8))
        return id
    }
}

private extension ClientConnection {
    func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        onDisconnect = handler
    }
}

/// Throttles upload progress UI updates off the transfer hot path.
private final class UploadProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldPublish(sent: UInt64, total: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if sent >= total {
            last = Date()
            return true
        }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.12 else { return false }
        last = now
        return true
    }
}

enum DemoBytes {
    static let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGf/9k=") ?? Data()
    static let pdf = Data("""
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 144]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
    4 0 obj<</Length 44>>stream
    BT /F1 18 Tf 36 80 Td (Tether demo) Tj ET
    endstream
    endobj
    5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
    trailer<</Root 1 0 R>>
    %%EOF
    """.utf8)
}
