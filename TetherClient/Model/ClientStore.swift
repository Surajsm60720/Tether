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
    var terminalLines: [TermLine] = []
    var terminalCWD = "/"
    var showMonitor = false
    var monitorProfile: SystemProfile?
    var monitorStats: SystemStats?
    var monitorDown = "0 B/s"
    var monitorUp = "0 B/s"
    var monitorMessage: String?
    var history: [String] = []
    var historyIndex = 0
    var agentProgram: String?
    /// Bumps when the live screen should be drawn again. The screen itself stays in `agentSurface` so SwiftUI does not copy it on every update.
    var agentFrame = 0
    var agentSurface: AgentSurface?
    var agentExited = false
    var agentExitCode = 0
    var agentError: String?
    var agentReceived = false
    var agentPaused = false
    var deviceName: String
    var demoMode: Bool
    var fontSize: Double
    var cacheBytes: Int64 = 0
    var recents: [RecentRecord] = []
    var sessionTab = 0
    var connectingName: String?
    var phoneVisible = false
    var searchText = ""
    var requestUpload = false
    var selecting = false
    var selection: Set<String> = []
    var notice: String?
    var feedbackCue: FeedbackCue = .success
    var feedbackTick = 0
    var remoteHostIDs: Set<String> = []

    private let context: ModelContext
    private let browser = TetherBrowser()
    private let phoneListener = TetherListener()
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
    private var agentLine: String?
    private var agentSessionID: String?
    private var agentColumns = 80
    private var agentRows = 24
    private var agentOpenTask: Task<Void, Never>?
    private var terminalEpoch = 0
    private var terminalBusy = false
    private var agentPending = Data()
    private var agentGeneration = 0
    private var agentFlushScheduled = false
    private var agentLastPaint = ContinuousClock.now.advanced(by: .seconds(-5))
    private var agentWriteFailures = 0
    private var agentEarly: [String: Data] = [:]
    private var agentEarlyExit: [String: Int] = [:]
    private var agentOutbound = Data()
    private var agentWriteScheduled = false
    private var agentWriteChain: Task<Void, Never> = Task {}
    private var agentHostID: String?

    init(context: ModelContext, preview: Bool = false) {
        self.context = context
        let defaults = UserDefaults.standard
        deviceName = defaults.string(forKey: "deviceName") ?? UIDevice.current.name
        demoMode = defaults.bool(forKey: "demoMode")
        fontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 14
        deviceID = Self.loadDeviceID()
        ClientStore.shared = self
        reloadPaired()
        reloadRemote()
        refreshCacheSize()
        restoreAgent()
        if preview { return }
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
            if agentProgram == nil {
                path = "/"
                terminalCWD = "/"
                terminalLines = [TermLine(text: L10n.termWelcome, kind: .dim)]
            }
            try await refresh()
            await resumeAgentIfNeeded(host: dial.hostId)
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
            hostId = item.id
            hostName = await session.hostName
            connected = true
            offline = false
            reconnecting = false
            activeHost = item
            intentionalDisconnect = false
            touch(item.id)
            shares = try await session.shares()
            if !restoring {
                path = "/"
                if agentProgram == nil { terminalCWD = "/" }
                terminalLines = [TermLine(text: L10n.termWelcome, kind: .dim)]
            }
            try await refresh()
            await resumeAgentIfNeeded(host: item.id)
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
            hostId = id
            hostName = name
            connected = true
            path = "/"
            terminalCWD = "/"
            terminalLines = [TermLine(text: L10n.termWelcome, kind: .dim)]
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
        let session = agentSessionID
        connection = nil
        connected = false
        offline = false
        reconnecting = false
        clearAgent()
        Task {
            if let session {
                await current?.closeTerminal(session: session)
            }
            await current?.close()
        }
    }

    func refresh() async throws {
        loading = entries.isEmpty
        defer { loading = false }
        if let demoFiles {
            let virtual = try VirtualPath.parse(path)
            entries = try await demoFiles.list(path: virtual, offset: 0, limit: 1000, includeHidden: false)
            shares = await demoFiles.shares()
            offline = false
            return
        }
        guard let connection else { return }
        entries = try await connection.list(path: path)
        offline = false
    }

    func open(_ entry: FileEntry) async {
        if selecting {
            toggleSelection(entry)
            return
        }
        if entry.kind == .dir {
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
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let item = TransferItem(name: name, path: full, direction: .up, total: size)
        transfers.insert(item, at: 0)
        let id = item.id
        transferTasks[id] = Task { @MainActor in
            await self.performUpload(id: id, url: url, full: full, name: name, size: size)
            self.transferTasks[id] = nil
        }
    }

    private func performUpload(id: UUID, url: URL, full: String, name: String, size: UInt64) async {
        do {
            if let demoFiles {
                let data = try Data(contentsOf: url)
                try demoFiles.writeFile(path: full, data: data)
                updateTransfer(id, sent: UInt64(data.count), total: UInt64(data.count), state: .completed)
            } else if let connection {
                try await connection.upload(file: url, toDirectory: path, fileName: name) { sent, total in
                    Task { @MainActor in
                        self.updateTransfer(id, sent: sent, total: total, state: .active)
                    }
                }
                updateTransfer(id, sent: size, total: max(size, 1), state: .completed)
            }
            try? await refresh()
        } catch is CancellationError {
            updateTransfer(id, sent: 0, total: size, state: .failed, message: "Cancelled")
        } catch {
            if Task.isCancelled {
                updateTransfer(id, sent: 0, total: size, state: .failed, message: "Cancelled")
            } else {
                updateTransfer(id, sent: 0, total: size, state: .failed, message: (error as? ProtocolFailure)?.message)
            }
        }
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

    var sortedEntries: [FileEntry] {
        let filtered = entries.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
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
            appendOutput(result.stdout, kind: .output)
            appendOutput(result.stderr, kind: .error)
            if let action = result.action {
                await perform(action)
            }
        } catch {
            guard epoch == terminalEpoch else { return }
            terminalLines.append(TermLine(text: (error as? ProtocolFailure)?.message ?? "Couldn't run that.", kind: .error))
        }
    }

    func completeTerminalLine(_ line: String) async -> (line: String, hint: String) {
        let request = LineCompletion.request(line: line, cwd: terminalCWD)
        let names: [CompletionName]
        if request.listsFiles {
            let entries = await listFolder(request.directory, includeHidden: request.prefix.hasPrefix("."))
            names = entries.map { CompletionName(name: $0.name, isDirectory: $0.kind == .dir) }
        } else {
            names = []
        }
        let outcome = LineCompletion.complete(
            line: line,
            request: request,
            names: names,
            commands: TerminalEngine.commandNames
        )
        return (outcome.line, outcome.hint)
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
        guard agentProgram != nil, !agentExited else { return }
        let columns = min(200, max(2, columns))
        let rows = min(80, max(2, rows))
        let changed = agentSurface == nil || columns != agentColumns || rows != agentRows
        agentColumns = columns
        agentRows = rows
        if let surface = agentSurface {
            if changed {
                surface.screen.resize(columns: columns, rows: rows)
                agentFrame += 1
            }
        } else {
            agentSurface = AgentSurface(screen: VTScreen(columns: columns, rows: rows))
            agentFrame += 1
            drainAgentPending()
        }
        if let id = agentSessionID {
            guard changed else { return }
            Task { try? await self.connection?.resizeTerminal(session: id, columns: columns, rows: rows) }
            return
        }
        guard agentOpenTask == nil else { return }
        agentOpenTask = Task { await self.openAgentSession() }
    }

    func sendAgentInput(_ input: VTInput) {
        guard !agentExited else { return }
        let screen = agentSurface?.screen ?? VTScreen(columns: agentColumns, rows: agentRows)
        let data = VTKeys.encode(input, applicationCursor: screen.applicationCursorKeys, bracketedPaste: screen.bracketedPaste)
        guard !data.isEmpty else { return }
        agentWriteFailures = 0
        agentOutbound.append(data)
        guard agentSessionID != nil else { return }
        scheduleAgentWrite()
    }

    func finishAgent() async {
        agentOpenTask?.cancel()
        agentOpenTask = nil
        let program = agentProgram
        let text = agentSurface?.screen.plainText() ?? ""
        let code = agentExitCode
        let error = agentError
        if let id = agentSessionID {
            await connection?.closeTerminal(session: id)
        }
        clearAgent()
        guard let program else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { appendOutput(trimmed + "\n", kind: .output) }
        if let error {
            terminalLines.append(TermLine(text: error, kind: .error))
        }
        let suffix = code == 0 ? "" : " (\(code))"
        terminalLines.append(TermLine(text: "\(AgentPrograms.displayName(program)) ended\(suffix)", kind: .dim))
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
                    self.handleDisconnect()
                }
            }
            return
        }
        reconnecting = true
        scheduleReconnect()
    }

    func beginBackgroundTaskIfNeeded() -> UIBackgroundTaskIdentifier {
        guard !activeTransfers.isEmpty || (agentProgram != nil && !agentExited) else { return .invalid }
        var token: UIBackgroundTaskIdentifier = .invalid
        token = UIApplication.shared.beginBackgroundTask {
            Task { @MainActor in
                for index in self.transfers.indices where self.transfers[index].state == .active {
                    self.transfers[index].state = .failed
                    self.transfers[index].message = L10n.keepOpen
                }
                UIApplication.shared.endBackgroundTask(token)
            }
        }
        return token
    }

    var prompt: String { "\(hostName.isEmpty ? "mac" : hostName):\(terminalCWD) $ " }

    private func attach(_ session: ClientConnection) async {
        await session.setDisconnectHandler { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        await session.setEventHandler { [weak self] message in
            Task { @MainActor in self?.handleAgentEvent(message) }
        }
        connection = session
    }

    private func beginAgent(line: String, program: String) {
        agentOpenTask?.cancel()
        agentOpenTask = nil
        agentLine = line
        agentProgram = program
        agentHostID = hostId
        agentSessionID = nil
        agentPaused = false
        UserDefaults.standard.removeObject(forKey: "agent.session")
        agentGeneration += 1
        agentFlushScheduled = false
        agentLastPaint = ContinuousClock.now.advanced(by: .seconds(-5))
        agentSurface = nil
        agentExited = false
        agentExitCode = 0
        agentError = nil
        agentReceived = false
        agentPending.removeAll()
        agentEarly.removeAll()
        agentEarlyExit.removeAll()
        agentOutbound.removeAll()
        agentColumns = 80
        agentRows = 24
    }

    private func openAgentSession() async {
        defer { agentOpenTask = nil }
        guard let connection, let line = agentLine, agentSessionID == nil, agentProgram != nil else { return }
        let columns = agentColumns
        let rows = agentRows
        do {
            let id = try await connection.openTerminal(line: line, cwd: terminalCWD, columns: columns, rows: rows)
            guard agentProgram != nil else {
                await connection.closeTerminal(session: id)
                return
            }
            agentSessionID = id
            rememberAgent()
            if let early = agentEarly.removeValue(forKey: id) {
                applyAgentBytes(early)
            }
            if let code = agentEarlyExit.removeValue(forKey: id) {
                agentExitCode = code
                agentExited = true
            }
            if !agentExited, (agentColumns != columns || agentRows != rows) {
                try? await connection.resizeTerminal(session: id, columns: agentColumns, rows: agentRows)
            }
            scheduleAgentWrite()
        } catch {
            agentExited = true
            agentError = (error as? ProtocolFailure)?.message ?? "Couldn't open a terminal on this Mac."
        }
    }

    private func handleAgentEvent(_ message: WireMessage) {
        guard let id = message.header.session else { return }
        switch message.header.op {
        case Op.termData:
            if id == agentSessionID {
                applyAgentBytes(message.body)
            } else if agentSessionID == nil, agentProgram != nil {
                var existing = agentEarly[id] ?? Data()
                existing.append(message.body)
                agentEarly[id] = existing
            }
        case Op.termExit:
            let code = message.header.exit ?? 0
            if id == agentSessionID {
                agentExitCode = code
                agentExited = true
            } else if agentSessionID == nil, agentProgram != nil {
                agentEarlyExit[id] = code
            }
        default:
            break
        }
    }

    private func applyAgentBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        agentReceived = true
        guard let surface = agentSurface else {
            agentPending.append(data)
            return
        }
        // Answer cursor queries before keystrokes that arrive while this chunk is on screen.
        // Programs ask where the cursor is before they accept a Tab completion.
        let replies = surface.screen.ingest(data)
        if !replies.isEmpty {
            var combined = replies
            combined.append(agentOutbound)
            agentOutbound = combined
            scheduleAgentWrite()
        }
        scheduleAgentPublish()
    }

    private func drainAgentPending() {
        let chunk = agentPending
        agentPending.removeAll(keepingCapacity: true)
        guard !chunk.isEmpty else { return }
        applyAgentBytes(chunk)
    }

    private func scheduleAgentPublish() {
        guard !agentFlushScheduled else { return }
        agentFlushScheduled = true
        let generation = agentGeneration
        let burst = self.agentLastPaint.duration(to: ContinuousClock.now) < .milliseconds(35)
        let delay: Duration = burst ? .milliseconds(40) : .milliseconds(10)
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard generation == self.agentGeneration else { return }
            self.agentFlushScheduled = false
            guard self.agentSurface != nil else { return }
            self.agentLastPaint = ContinuousClock.now
            self.agentFrame += 1
        }
    }

    private func scheduleAgentWrite() {
        guard !agentWriteScheduled else { return }
        agentWriteScheduled = true
        let previous = agentWriteChain
        agentWriteChain = Task { @MainActor in
            _ = await previous.value
            try? await Task.sleep(for: .milliseconds(2))
            self.agentWriteScheduled = false
            let payload = self.agentOutbound
            self.agentOutbound.removeAll(keepingCapacity: true)
            guard !payload.isEmpty, !self.agentExited else { return }
            if let id = self.agentSessionID, let connection = self.connection {
                do {
                    try await connection.writeTerminal(session: id, data: payload)
                    self.agentWriteFailures = 0
                } catch {
                    var combined = payload
                    combined.append(self.agentOutbound)
                    self.agentOutbound = combined
                    self.agentWriteFailures += 1
                    guard self.agentWriteFailures < 4, !self.agentExited else { return }
                    try? await Task.sleep(for: .milliseconds(40))
                    if !self.agentOutbound.isEmpty { self.scheduleAgentWrite() }
                    return
                }
            } else if self.agentProgram != nil {
                var combined = payload
                combined.append(self.agentOutbound)
                self.agentOutbound = combined
                return
            }
            if !self.agentOutbound.isEmpty { self.scheduleAgentWrite() }
        }
    }

    private func clearAgent() {
        agentOpenTask?.cancel()
        agentOpenTask = nil
        agentProgram = nil
        agentLine = nil
        agentSessionID = nil
        agentGeneration += 1
        agentFlushScheduled = false
        agentLastPaint = ContinuousClock.now.advanced(by: .seconds(-5))
        agentSurface = nil
        agentExited = false
        agentExitCode = 0
        agentError = nil
        agentReceived = false
        agentPending.removeAll()
        agentEarly.removeAll()
        agentEarlyExit.removeAll()
        agentOutbound.removeAll()
        agentPaused = false
        agentHostID = nil
        UserDefaults.standard.removeObject(forKey: "agent.session")
    }

    private func rememberAgent() {
        guard let id = agentSessionID, let program = agentProgram, let line = agentLine else { return }
        UserDefaults.standard.set(
            ["id": id, "program": program, "line": line, "cwd": terminalCWD, "host": agentHostID ?? hostId],
            forKey: "agent.session"
        )
    }

    private func restoreAgent() {
        guard let payload = UserDefaults.standard.dictionary(forKey: "agent.session") as? [String: String],
              let id = payload["id"], let program = payload["program"], let line = payload["line"],
              let host = payload["host"] else { return }
        agentSessionID = id
        agentProgram = program
        agentLine = line
        agentHostID = host
        agentPaused = true
        agentReceived = true
        if let cwd = payload["cwd"], !cwd.isEmpty { terminalCWD = cwd }
        agentSurface = AgentSurface(screen: VTScreen(columns: agentColumns, rows: agentRows))
        agentFrame += 1
    }

    private func resumeAgentIfNeeded(host: String) async {
        guard agentHostID == host, let connection, let id = agentSessionID, agentProgram != nil, !agentExited else { return }
        do {
            try await connection.resumeTerminal(session: id)
            try? await connection.resizeTerminal(session: id, columns: agentColumns, rows: agentRows)
            agentPaused = false
            rememberAgent()
            scheduleAgentWrite()
        } catch {
            agentPaused = false
            agentExited = true
            agentSessionID = nil
            UserDefaults.standard.removeObject(forKey: "agent.session")
            agentError = (error as? ProtocolFailure)?.message ?? "That session on your Mac has ended."
        }
    }

    private func enableDemo() {
        let files = MemoryFileProvider()
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
        terminalCWD = "/"
        terminalLines = [TermLine(text: L10n.termWelcome, kind: .dim)]
        Task { try? await refresh() }
    }

    private func cue(_ kind: FeedbackCue) {
        feedbackCue = kind
        feedbackTick += 1
    }

    private func handleDisconnect() {
        connection = nil
        if agentProgram != nil, !agentExited { agentPaused = true }
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
            sessionTab = 0
        case "monitor":
            monitorProfile = nil
            monitorStats = nil
            monitorBytesIn = nil
            monitorBytesOut = nil
            monitorSampledAt = nil
            monitorMessage = nil
            showMonitor = true
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
    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        onDisconnect = handler
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
