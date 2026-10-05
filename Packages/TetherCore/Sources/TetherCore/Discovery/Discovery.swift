import Foundation
import Network

public struct DiscoveredHost: Identifiable, Sendable, Hashable {
    public var name: String
    public var hostId: String
    public var endpoint: NWEndpoint
    public var serviceName: String

    public var id: String { hostId }

    public init(name: String, hostId: String, endpoint: NWEndpoint, serviceName: String = "") {
        self.name = name
        self.hostId = hostId
        self.endpoint = endpoint
        self.serviceName = serviceName
    }

    public func matches(savedHostId: String) -> Bool {
        BonjourHostID.matches(discoveredId: hostId, serviceName: serviceName, savedId: savedHostId)
    }
}

public enum TetherLink {
    public static func parameters(peerToPeer: Bool = true) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }

    public static func stream(to endpoint: NWEndpoint) -> NWByteStream {
        NWByteStream(connection: NWConnection(to: endpoint, using: parameters()))
    }
}

public final class TetherBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.tether.browser")
    private var browser: NWBrowser?
    public var onUpdate: (@Sendable ([DiscoveredHost]) -> Void)?
    public var onState: (@Sendable (String) -> Void)?

    public init() {}

    public func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: TetherCoreInfo.serviceType, domain: "local."), using: TetherLink.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { Self.host(from: $0) }
            self?.onUpdate?(hosts)
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?("ready")
            case .failed(let error):
                self?.onState?("failed: \(error.localizedDescription)")
            case .waiting(let error):
                self?.onState?("waiting: \(error.localizedDescription)")
            default:
                self?.onState?("starting")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

public final class TetherListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.tether.listener")
    private var listener: NWListener?
    public var onConnection: (@Sendable (NWConnection) -> Void)?
    public var onState: (@Sendable (String) -> Void)?

    public init() {}

    /// Advertises on the local network. The Bonjour name is ASCII (`Tether-` plus the host id)
    /// so a Mac name with an apostrophe cannot make the advertisement fail. The display name
    /// travels in the TXT record.
    public func start(name: String, hostId: String, peerToPeer: Bool = true) throws {
        stop()
        let listener = try NWListener(using: TetherLink.parameters(peerToPeer: peerToPeer))
        var record = NWTXTRecord()
        record["v"] = "1"
        record["id"] = hostId
        record["name"] = String(name.prefix(80))
        listener.service = NWListener.Service(
            name: "Tether-\(hostId)",
            type: TetherCoreInfo.serviceType,
            domain: "local.",
            txtRecord: record
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?("ready")
            case .failed(let error):
                TetherLog.discovery.error("listener failed: \(error.localizedDescription, privacy: .public)")
                self?.onState?("failed: \(error.localizedDescription)")
            case .waiting(let error):
                self?.onState?("waiting: \(error.localizedDescription)")
            case .cancelled:
                self?.onState?("cancelled")
            default:
                self?.onState?("starting")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

enum BonjourHostID {
    /// The id stored at pairing time. The Bonjour name is `Tether-<id>` even when the TXT record has not arrived yet.
    public static func resolve(serviceName: String, txtId: String?) -> String {
        if let txtId {
            let trimmed = txtId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let prefix = "Tether-"
        if serviceName.hasPrefix(prefix) {
            let rest = String(serviceName.dropFirst(prefix.count))
            if !rest.isEmpty { return rest }
        }
        return "name:\(serviceName)"
    }

    public static func matches(discoveredId: String, serviceName: String, savedId: String) -> Bool {
        if discoveredId == savedId { return true }
        if serviceName == "Tether-\(savedId)" { return true }
        if discoveredId == "name:\(serviceName)", serviceName == "Tether-\(savedId)" { return true }
        return false
    }
}

extension TetherBrowser {
    static func host(from result: NWBrowser.Result) -> DiscoveredHost? {
        let serviceName: String
        if case let .service(name, _, _, _) = result.endpoint {
            serviceName = name
        } else {
            serviceName = "Mac"
        }
        var txtId: String?
        var display = serviceName
        if case let .bonjour(record) = result.metadata {
            if let version = record["v"], !version.isEmpty, version != "1" { return nil }
            txtId = record["id"]
            if let name = record["name"], !name.isEmpty { display = name }
        }
        let hostId = BonjourHostID.resolve(serviceName: serviceName, txtId: txtId)
        return DiscoveredHost(name: display, hostId: hostId, endpoint: result.endpoint, serviceName: serviceName)
    }
}
