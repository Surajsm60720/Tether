import Foundation
import Network

public struct DiscoveredHost: Identifiable, Sendable, Hashable {
    public var name: String
    public var hostId: String
    public var endpoint: NWEndpoint
    public var serviceName: String
    /// `phone` or `mac` from the TXT record. Empty when the record has not arrived.
    public var role: String

    public var id: String { hostId }

    public init(name: String, hostId: String, endpoint: NWEndpoint, serviceName: String = "", role: String = "") {
        self.name = name
        self.hostId = hostId
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.role = role
    }

    /// An iPhone advertisement. The instance name starts with `Phone-` even before the TXT record arrives.
    public var isPhone: Bool {
        role == "phone" || serviceName.hasPrefix("Phone-")
    }

    public func matches(savedHostId: String) -> Bool {
        BonjourHostID.matches(discoveredId: hostId, serviceName: serviceName, savedId: savedHostId)
    }

    /// False for raw service names such as `Tether-abcd1234`, so a missing TXT record cannot overwrite a saved Mac name.
    public var hasFriendlyName: Bool {
        if name.isEmpty { return false }
        if name.hasPrefix("Tether-") || name.hasPrefix("Phone-") { return false }
        if name == serviceName, serviceName.hasPrefix("Tether-") || serviceName.hasPrefix("Phone-") { return false }
        return true
    }
}

public enum TetherLink {
    /// Local path only. Cellular is prohibited so a file never detours onto the public internet.
    /// TCP delayed-ACK is off and the service class asks Wi-Fi for low-latency, high-throughput treatment.
    public static func parameters(peerToPeer: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        parameters.serviceClass = .responsiveData
        parameters.multipathServiceType = .disabled
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.preferNoProxies = true
        return parameters
    }

    /// Browse and advertise parameters. Unlike a file transfer, discovery must not
    /// forbid an interface: doing so keeps the iPhone from publishing itself to the Mac.
    public static func discoveryParameters(peerToPeer: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }

    public static func stream(to endpoint: NWEndpoint) -> NWByteStream {
        NWByteStream(connection: NWConnection(to: endpoint, using: parameters()))
    }
}

public final class TetherBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.tether.browser")
    private let serviceType: String
    private var browsers: [NWBrowser] = []
    private var batches: [ObjectIdentifier: [DiscoveredHost]] = [:]
    private var states: [ObjectIdentifier: String] = [:]

    public init(serviceType: String = TetherCoreInfo.serviceType) {
        self.serviceType = serviceType
    }
    public var onUpdate: (@Sendable ([DiscoveredHost]) -> Void)?
    public var onState: (@Sendable (String) -> Void)?

    /// Browses Wi-Fi and peer-to-peer separately and merges them. A peer-to-peer-only
    /// browse often stays empty on a normal access point even when the other device is there.
    public func start() {
        stop()
        browsers = [makeBrowser(peerToPeer: false), makeBrowser(peerToPeer: true)]
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        batches = [:]
        states = [:]
    }

    private func makeBrowser(peerToPeer: Bool) -> NWBrowser {
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: TetherLink.discoveryParameters(peerToPeer: peerToPeer)
        )
        let id = ObjectIdentifier(browser)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { Self.host(from: $0) }
            guard let self else { return }
            self.queue.async { [self] in
                self.batches[id] = hosts
                self.publish()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let label: String
            switch state {
            case .ready: label = "ready"
            case .failed(let error): label = "failed: \(error.localizedDescription)"
            case .waiting(let error): label = "waiting: \(error.localizedDescription)"
            default: label = "starting"
            }
            guard let self else { return }
            self.queue.async { [self] in
                self.states[id] = label
                self.publishState()
            }
        }
        browser.start(queue: queue)
        return browser
    }

    private func publish() {
        var byID: [String: DiscoveredHost] = [:]
        for hosts in batches.values {
            for host in hosts {
                if let existing = byID[host.id] {
                    byID[host.id] = preferred(existing, host)
                } else {
                    byID[host.id] = host
                }
            }
        }
        onUpdate?(Array(byID.values))
    }

    private func preferred(_ lhs: DiscoveredHost, _ rhs: DiscoveredHost) -> DiscoveredHost {
        if rhs.hasFriendlyName, !lhs.hasFriendlyName { return rhs }
        return lhs
    }

    private func publishState() {
        let values = Array(states.values)
        if values.contains("ready") {
            onState?("ready")
        } else if let failure = values.first(where: { $0.hasPrefix("failed") || $0.hasPrefix("waiting") }) {
            onState?(failure)
        } else {
            onState?("starting")
        }
    }
}

public final class TetherListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.tether.listener")
    private var listener: NWListener?
    private var advertisedName = ""
    private var advertisedID = ""
    private var advertisedType = TetherCoreInfo.serviceType
    private var advertisedPrefix = "Tether"
    private var advertisedRole = "mac"
    private var usePlainName = false
    private var fellBack = false
    private var triedLegacyName = false
    public var onConnection: (@Sendable (NWConnection) -> Void)?
    public var onState: (@Sendable (String) -> Void)?

    public init() {}

    /// Advertises on the local network. The instance name carries the display name and the
    /// stable id (`Cedar Studio #abcd1234`) so the other device can show the right name even
    /// when the TXT record has not arrived. The TXT record repeats both.
    public func start(
        name: String,
        hostId: String,
        peerToPeer: Bool = true,
        serviceType: String = TetherCoreInfo.serviceType,
        namePrefix: String = "Tether",
        role: String = "mac",
        plainName: Bool = false
    ) throws {
        advertisedName = name
        advertisedID = hostId
        advertisedType = serviceType
        advertisedPrefix = namePrefix
        advertisedRole = role
        usePlainName = plainName
        fellBack = false
        triedLegacyName = false
        try begin(peerToPeer: peerToPeer, legacyName: false)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func begin(peerToPeer: Bool, legacyName: Bool) throws {
        listener?.cancel()
        let listener = try NWListener(using: TetherLink.discoveryParameters(peerToPeer: peerToPeer))
        let instance = (usePlainName || legacyName)
            ? "\(advertisedPrefix)-\(advertisedID)"
            : BonjourHostID.instanceName(displayName: advertisedName, id: advertisedID, fallbackPrefix: advertisedPrefix)
        let safeName = String(advertisedName.components(separatedBy: .controlCharacters).joined().prefix(80))
        var txt: [String: String] = [
            "v": "1",
            "id": advertisedID,
            "role": advertisedRole,
        ]
        if !safeName.isEmpty { txt["name"] = safeName }
        let record = NWTXTRecord(txt)
        listener.service = NWListener.Service(
            name: instance,
            type: advertisedType,
            domain: nil,
            txtRecord: record
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case .add = change {
                self?.onState?("advertised")
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?("ready")
            case .failed(let error):
                TetherLog.discovery.error("listener failed: \(error.localizedDescription, privacy: .public)")
                if self?.fellBack == false {
                    self?.fellBack = true
                    try? self?.begin(peerToPeer: !peerToPeer, legacyName: legacyName)
                    return
                }
                if !legacyName, self?.triedLegacyName == false {
                    self?.triedLegacyName = true
                    self?.fellBack = false
                    try? self?.begin(peerToPeer: false, legacyName: true)
                    return
                }
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
}

enum BonjourHostID {
    /// Splits a display name from the stable id inside a Bonjour instance name.
    /// ASCII on purpose: an apostrophe or other punctuation in the service name can stop the advertisement.
    static let marker = " #"

    /// Instance name that stays within Bonjour's 63-byte limit and still round-trips the id.
    public static func instanceName(displayName: String, id: String, fallbackPrefix: String) -> String {
        let clean = sanitize(displayName)
        let legacy = "\(fallbackPrefix)-\(id)"
        guard !clean.isEmpty, !id.isEmpty else { return legacy }
        let suffix = marker + id
        guard (suffix.utf8.count) < 63 else { return legacy }
        var prefix = clean
        while (prefix + suffix).utf8.count > 63, !prefix.isEmpty {
            prefix.removeLast()
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return legacy }
        return trimmed + suffix
    }

    /// The id stored at pairing time. Prefers the TXT record, then the id embedded in the instance name.
    public static func resolve(serviceName: String, txtId: String?) -> String {
        if let txtId {
            let trimmed = txtId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let parsed = parse(serviceName) { return parsed.id }
        return "name:\(serviceName)"
    }

    public static func displayName(serviceName: String, txtName: String?) -> String {
        if let txtName {
            let trimmed = txtName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("Tether-"), !trimmed.hasPrefix("Phone-") {
                return trimmed
            }
        }
        if let parsed = parse(serviceName), !parsed.display.isEmpty {
            return parsed.display
        }
        if serviceName.hasPrefix("Phone-") { return "iPhone" }
        return serviceName
    }

    public static func matches(discoveredId: String, serviceName: String, savedId: String) -> Bool {
        if discoveredId == savedId { return true }
        if let parsed = parse(serviceName), parsed.id == savedId { return true }
        if serviceName == "Tether-\(savedId)" || serviceName == "Phone-\(savedId)" { return true }
        if discoveredId == "name:\(serviceName)", serviceName == "Tether-\(savedId)" || serviceName == "Phone-\(savedId)" { return true }
        return false
    }

    static func parse(_ serviceName: String) -> (display: String, id: String)? {
        if let range = serviceName.range(of: marker, options: .backwards) {
            let display = String(serviceName[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = String(serviceName[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !display.isEmpty, isIdentity(id) { return (display, id) }
        }
        for prefix in ["Tether-", "Phone-"] where serviceName.hasPrefix(prefix) {
            let id = String(serviceName.dropFirst(prefix.count))
            if isIdentity(id) { return ("", id) }
        }
        return nil
    }

    private static func isIdentity(_ id: String) -> Bool {
        if id.count == 8, id.allSatisfy(\.isHexDigit) { return true }
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    private static func sanitize(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-"
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(separator: " ")
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var txtName: String?
        var role = ""
        if case let .bonjour(record) = result.metadata {
            if let version = record["v"], !version.isEmpty, version != "1" { return nil }
            txtId = record["id"]
            txtName = record["name"]
            role = record["role"] ?? ""
        }
        let hostId = BonjourHostID.resolve(serviceName: serviceName, txtId: txtId)
        let display = BonjourHostID.displayName(serviceName: serviceName, txtName: txtName)
        return DiscoveredHost(name: display, hostId: hostId, endpoint: result.endpoint, serviceName: serviceName, role: role)
    }
}
