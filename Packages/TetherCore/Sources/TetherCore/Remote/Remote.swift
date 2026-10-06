import Darwin
import Foundation
import Network

/// Ports Tether binds when the user turns on access from another network.
public enum TetherPorts {
    /// Stable port on the Mac. Bonjour still works; the port no longer changes every launch.
    public static let direct: UInt16 = 52173
    /// Default port for `tether-relay`.
    public static let relay: UInt16 = 52174
}

/// A host and port the user typed, or one discovered on this Mac.
public struct RemoteAddress: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public enum Reach: Sendable, Equatable {
        /// RFC1918 or loopback. Only useful on that network, or after a router port forward.
        case localNetwork
        /// Carrier-grade range used by Tailscale and similar tunnels.
        case tunnel
        case publicInternet
    }

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String {
        if host.contains(":") { return "[\(host)]:\(port)" }
        return "\(host):\(port)"
    }

    public var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    public var reach: Reach {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return .publicInternet
        }
        let first = parts[0]
        let second = parts[1]
        if first == 10 || first == 127 || (first == 192 && second == 168) || (first == 172 && (16...31).contains(second)) {
            return .localNetwork
        }
        if first == 100 && (64...127).contains(second) {
            return .tunnel
        }
        return .publicInternet
    }

    /// Accepts `host:port`, `hostname`, and `[IPv6]:port`. A missing port uses `defaultPort`.
    public static func parse(_ raw: String, defaultPort: UInt16? = nil) -> RemoteAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let defaultPort, !text.hasPrefix("["), !text.contains(":") {
            text = "\(text):\(defaultPort)"
        }
        let host: String
        let portText: String
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<end])
            let rest = text[text.index(after: end)...]
            guard rest.hasPrefix(":") else { return nil }
            portText = String(rest.dropFirst())
        } else {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            host = String(text[..<colon])
            portText = String(text[text.index(after: colon)...])
        }
        guard !host.isEmpty, host.count <= 253, !host.contains(" "), !host.contains("/"), !host.contains("@"),
              let port = UInt16(portText), port > 0 else { return nil }
        return RemoteAddress(host: host, port: port)
    }

    /// The address baked into the iPhone setup code. A typed hostname wins, then a tunnel, then a public address, then Wi-Fi.
    public static func preferred(override: String, port: UInt16, interfaces: [MachineAddress]) -> RemoteAddress? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let parsed = parse(trimmed) { return parsed }
            if let parsed = parse(trimmed, defaultPort: port) { return parsed }
        }
        let ranked = interfaces.sorted { $0.kind.sort < $1.kind.sort }
        guard let best = ranked.first else { return nil }
        return RemoteAddress(host: best.address, port: port)
    }
}

/// What the Mac shows and what the iPhone pastes. The token lets the relay join the two devices.
/// It is not the file-encryption key. A stranger who has the token still cannot pass the pairing handshake.
public struct RemoteSetup: Sendable, Equatable {
    public var hostId: String
    public var direct: RemoteAddress?
    public var relay: RemoteAddress?
    public var token: Data

    public init(hostId: String, direct: RemoteAddress?, relay: RemoteAddress?, token: Data) {
        self.hostId = hostId
        self.direct = direct
        self.relay = relay
        self.token = token
    }

    public func encoded() -> String {
        var items = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "id", value: hostId)]
        if let direct { items.append(URLQueryItem(name: "d", value: direct.description)) }
        if let relay { items.append(URLQueryItem(name: "r", value: relay.description)) }
        items.append(URLQueryItem(name: "t", value: Base64URL.encode(token)))
        var components = URLComponents()
        components.scheme = "tether"
        components.host = "remote"
        components.queryItems = items
        return components.string ?? ""
    }

    public static func decode(_ raw: String) -> RemoteSetup? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "tether",
              components.host == "remote" else { return nil }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard items["v"] == "1", let hostId = items["id"], !hostId.isEmpty else { return nil }
        let direct = items["d"].flatMap { value in value.isEmpty ? nil : RemoteAddress.parse(value) }
        let relay = items["r"].flatMap { value in value.isEmpty ? nil : RemoteAddress.parse(value) }
        if items["d"] != nil, direct == nil { return nil }
        if items["r"] != nil, relay == nil { return nil }
        guard direct != nil || relay != nil else { return nil }
        guard let tokenText = items["t"], let token = try? Base64URL.decode(tokenText), token.count == 32 else { return nil }
        return RemoteSetup(hostId: hostId, direct: direct, relay: relay, token: token)
    }
}

public struct MachineAddress: Identifiable, Sendable, Equatable {
    public var interfaceName: String
    public var address: String
    public var kind: Kind

    public var id: String { address }

    public enum Kind: String, Sendable, Equatable {
        case tailscale
        case publicInternet
        case vpn
        case local

        var sort: Int {
            switch self {
            case .tailscale: 0
            case .publicInternet: 1
            case .vpn: 2
            case .local: 3
            }
        }
    }

    public init(interfaceName: String, address: String, kind: Kind) {
        self.interfaceName = interfaceName
        self.address = address
        self.kind = kind
    }
}

public enum MachineAddresses {
    /// IPv4 addresses on interfaces that are up, skipping loopback and link-local.
    public static func list() -> [MachineAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }
        var found: [String: MachineAddress] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let flags = Int32(current.pointee.ifa_flags)
            if flags & IFF_UP == 0 || flags & IFF_LOOPBACK != 0 { continue }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(address, size, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let ip = String(decoding: bytes, as: UTF8.self)
            if ip.isEmpty || ip.hasPrefix("169.254.") { continue }
            let name = String(cString: current.pointee.ifa_name)
            found[ip] = MachineAddress(interfaceName: name, address: ip, kind: kind(interfaceName: name, ip: ip))
        }
        return found.values.sorted { lhs, rhs in
            if lhs.kind.sort != rhs.kind.sort { return lhs.kind.sort < rhs.kind.sort }
            return lhs.address < rhs.address
        }
    }

    private static func kind(interfaceName: String, ip: String) -> MachineAddress.Kind {
        let tunnel = interfaceName.hasPrefix("utun") || interfaceName.localizedCaseInsensitiveContains("tailscale")
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        let carrier = parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
        if tunnel && (carrier || interfaceName.localizedCaseInsensitiveContains("tailscale")) {
            return .tailscale
        }
        if RemoteAddress(host: ip, port: 1).reach == .publicInternet { return .publicInternet }
        if tunnel { return .vpn }
        return .local
    }
}
