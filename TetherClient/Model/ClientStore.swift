import CryptoKit
import Foundation
import Network
import Observation
import SwiftData
import TetherCore
import UIKit

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
    var previewURL: URL?
    var pendingLarge: FileEntry?
    var readOnlyAlert = false
    var terminalLines: [TermLine] = []
    var terminalCWD = "/"
    var history: [String] = []
    var historyIndex = 0
    var deviceName: String
    var demoMode: Bool
    var fontSize: Double
    var cacheBytes: Int64 = 0
    var recents: [RecentRecord] = []
    var sessionTab = 0
    var searchText = ""
    var requestUpload = false

    private let context: ModelContext
    private let browser = TetherBrowser()
    private var connection: ClientConnection?
    private var demoFiles: MemoryFileProvider?
    private var lastDownload: URL?
    private var reconnectTask: Task<Void, Never>?
    private var intentionalDisconnect = false
    private var openingSavedMac = false
    private var activeHost: PairedItem?
    private let deviceID: String

    init(context: ModelContext, preview: Bool = false) {
        self.context = context
        let defaults = UserDefaults.standard
        deviceName = defaults.string(forKey: "deviceName") ?? UIDevice.current.name
        demoMode = defaults.bool(forKey: "demoMode")
        fontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 14
        deviceID = Self.loadDeviceID()
        ClientStore.shared = self
        reloadPaired()
        refreshCacheSize()
        if preview { return }
        if !defaults.bool(forKey: "didAcceptPrimer") {
            showPrimer = true
        } else {
            startBrowser()
        }
        if demoMode { enableDemo() }
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
                store.discovered = hosts
                store.connectSavedMacIfVisible()
            }
        }
        browser.onState = { state in
            Task { @MainActor in
                guard let store = ClientStore.shared else { return }
                if state == "ready" {
                    store.localNetworkOff = false
                    store.discoveryDetail = nil
                } else if state.hasPrefix("waiting") || state.hasPrefix("failed") {
                    store.localNetworkOff = true
                    store.discoveryDetail = "Allow Tether to find devices on your local network, then pull to refresh."
                }
            }
        }
        browser.start()
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
        KeychainStore.delete(service: Self.service, account: "host.\(item.id)")
        let records = (try? context.fetch(FetchDescriptor<PairedHostRecord>())) ?? []
        if let record = records.first(where: { $0.hostId == item.id }) {
            context.delete(record)
            try? context.save()
        }
        paired.removeAll { $0.id == item.id }
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
        if demoMode { enableDemo(); return }
        guard let endpoint = await endpoint(for: item.id) else {
            offline = true
            reconnecting = false
            statusMessage = L10n.unreachable(item.name)
            return
        }
        guard let keyData = try? KeychainStore.load(service: Self.service, account: "host.\(item.id)") else {
            revoked = true
            return
        }
        reconnecting = connection != nil
        offline = false
        revoked = false
        statusMessage = nil
        let stream = TetherLink.stream(to: endpoint)
        do {
            try await stream.start()
            let session = try await ClientConnection.establish(
                stream: stream,
                deviceId: deviceID,
                deviceName: deviceName,
                mode: .session(hostId: item.id, key: SymmetricKey(data: keyData))
            )
            await session.setDisconnectHandler { [weak self] in
                Task { @MainActor in self?.handleDisconnect() }
            }
            connection = session
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
                terminalCWD = "/"
                terminalLines = [TermLine(text: L10n.termWelcome, kind: .dim)]
            }
            try await refresh()
        } catch {
            reconnecting = false
            let failure = error as? ProtocolFailure
            if failure?.message == ProtocolFailure.revoked.message {
                revoked = true
                connected = false
            } else {
                offline = true
                statusMessage = failure?.message ?? L10n.unreachable(item.name)
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
            try KeychainStore.save(service: Self.service, account: "host.\(id)", data: key)
            savePaired(id: id, name: name)
            await session.setDisconnectHandler { [weak self] in
                Task { @MainActor in self?.handleDisconnect() }
            }
            connection = session
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
        connection = nil
        connected = false
        offline = false
        reconnecting = false
        Task { await current?.close() }
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
        if entry.kind == .dir {
            path = path == "/" ? "/\(entry.name)" : path + "/" + entry.name
            entries = []
            try? await refresh()
            return
        }
        if entry.size > 100 * 1024 * 1024 {
            pendingLarge = entry
            return
        }
        await download(entry, preview: true)
    }

    func confirmLargeDownload() async {
        guard let entry = pendingLarge else { return }
        pendingLarge = nil
        await download(entry, preview: true)
    }

    func download(_ entry: FileEntry, preview: Bool) async {
        let full = joined(entry.name)
        var item = TransferItem(name: entry.name, path: full, direction: .down, total: entry.size)
        transfers.insert(item, at: 0)
        let id = item.id
        let destination = cacheURL(host: hostId, path: full, size: entry.size, mtime: entry.mtime)
        do {
            if let demoFiles {
                let chunk = try await demoFiles.read(path: VirtualPath.parse(full), offset: 0, length: Int(max(entry.size, 1)))
                try chunk.data.write(to: destination, options: .atomic)
                updateTransfer(id, sent: entry.size, total: max(entry.size, 1), state: .completed)
            } else if let connection {
                try await connection.download(path: full, to: destination) { sent, total in
                    Task { @MainActor in
                        self.updateTransfer(id, sent: sent, total: total, state: .active)
                    }
                }
                updateTransfer(id, sent: entry.size, total: max(entry.size, 1), state: .completed)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            remember(full)
            refreshCacheSize()
            lastDownload = destination
            if preview { previewURL = destination }
        } catch {
            updateTransfer(id, sent: item.sent, total: item.total, state: .failed, message: (error as? ProtocolFailure)?.message)
            _ = item
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
        } catch {
            updateTransfer(id, sent: 0, total: size, state: .failed, message: (error as? ProtocolFailure)?.message)
        }
    }

    func retry(_ item: TransferItem) async {
        guard item.retries < 2 || true else { return }
        if let index = transfers.firstIndex(where: { $0.id == item.id }) {
            transfers[index].retries += 1
            transfers[index].state = .active
        }
        if item.direction == .down, let entry = entries.first(where: { $0.name == item.name }) {
            await download(entry, preview: false)
        }
    }

    func cancel(_ item: TransferItem) {
        if let index = transfers.firstIndex(where: { $0.id == item.id }) {
            transfers[index].state = .failed
            transfers[index].message = "Cancelled"
        }
    }

    func clearCompleted() {
        transfers.removeAll { $0.state == .completed }
    }

    func goUp() async {
        guard path != "/" else { return }
        let virtual = (try? VirtualPath.parse(path)) ?? .root
        path = virtual.parent.string
        try? await refresh()
    }

    func go(to ancestor: String) async {
        path = ancestor
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
        if path == "/" { return false }
        let share = (try? VirtualPath.parse(path))?.components.first
        return shares.first { $0.name == share }?.writable ?? false
    }

    func runTerminal(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
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
        do {
            let result: TerminalResult
            if let demoFiles {
                result = await TerminalEngine().execute(line: trimmed, cwd: terminalCWD, files: demoFiles)
            } else if let connection {
                result = try await connection.exec(cwd: terminalCWD, line: trimmed)
            } else {
                terminalLines.append(TermLine(text: "Not connected.", kind: .error))
                return
            }
            terminalCWD = result.cwd
            appendOutput(result.stdout, kind: .output)
            appendOutput(result.stderr, kind: .error)
            if let action = result.action {
                await perform(action)
            }
        } catch {
            terminalLines.append(TermLine(text: (error as? ProtocolFailure)?.message ?? "Couldn't run that.", kind: .error))
        }
    }

    func thumbnail(for entry: FileEntry) async -> Data? {
        let full = joined(entry.name)
        if let demoFiles {
            guard entry.name.lowercased().hasSuffix("jpg") || entry.name.lowercased().hasSuffix("jpeg") else { return nil }
            return try? await demoFiles.read(path: VirtualPath.parse(full), offset: 0, length: 256 * 1024).data
        }
        return try? await connection?.thumbnail(path: full, maxPixel: 200)
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

    func sceneBecameActive() {
        guard connected, connection == nil, activeHost != nil, !demoMode, !intentionalDisconnect else { return }
        reconnecting = true
        scheduleReconnect()
    }

    func beginBackgroundTaskIfNeeded() -> UIBackgroundTaskIdentifier {
        guard !activeTransfers.isEmpty else { return .invalid }
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

    private func handleDisconnect() {
        connection = nil
        guard connected, !intentionalDisconnect else { return }
        offline = true
        reconnecting = true
        statusMessage = "Reconnecting to \(hostName)…"
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
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

    func connectSavedMacIfVisible() {
        guard !connected, !openingSavedMac, !showPairing, !demoMode, !intentionalDisconnect, connection == nil else { return }
        let candidate = paired
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .first { host in discovered.contains { $0.matches(savedHostId: host.id) } }
        guard let candidate else { return }
        openingSavedMac = true
        Task {
            await connect(candidate, restoring: true)
            openingSavedMac = false
        }
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

    private func perform(_ action: TerminalAction) async {
        switch action.type {
        case "clear":
            terminalLines = []
        case "exit":
            sessionTab = 0
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
            await download(FileEntry(name: name, kind: entry.kind, size: entry.size, mtime: entry.mtime), preview: action.type != "get")
            if action.type == "get", let lastDownload {
                _ = try? saveToDocuments(lastDownload)
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

    private func cacheURL(host: String, path: String, size: UInt64, mtime: TimeInterval) -> URL {
        let key = "\(host)|\(path)|\(size)|\(mtime)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension
        let name = ext.isEmpty ? digest : "\(digest).\(ext)"
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        evictIfNeeded()
        return cacheDirectory.appendingPathComponent(name)
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tether", isDirectory: true)
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Tether Downloads", isDirectory: true)
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
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private static let service = "app.tether.client"

    private static func loadDeviceID() -> String {
        if let data = try? KeychainStore.load(service: service, account: "device-id"),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        let id = UUID().uuidString
        try? KeychainStore.save(service: service, account: "device-id", data: Data(id.utf8))
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
