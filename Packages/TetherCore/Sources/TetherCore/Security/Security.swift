import CryptoKit
import Foundation
import Security

public enum SessionMode: String, Sendable {
    case pair
    case session
}

/// Which bytes of the one-time pairing secret `P` both sides feed into HKDF.
///
/// The QR code carries all 32 bytes (`full`). The manual code carries only the
/// first 10 bytes, Crockford-encoded (`short`). The client says which one it
/// used in `ClientHello.material`, because the host cannot tell them apart
/// from the ciphertext alone. After pairing, both sides switch to the
/// long-term device key `K` and this choice is discarded with `P`.
public enum PairMaterial: String, Sendable {
    case full
    case short
}

public enum ChannelRole: Sendable {
    case client
    case host
}

public struct ChannelKeys: Sendable {
    public var clientToHost: SymmetricKey
    public var hostToClient: SymmetricKey

    public static func derive(secret: SymmetricKey, nonceC: Data, nonceH: Data) -> ChannelKeys {
        let salt = nonceC + nonceH
        let c2h = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret,
            salt: salt,
            info: Data("tether/v1/c2h".utf8),
            outputByteCount: 32
        )
        let h2c = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret,
            salt: salt,
            info: Data("tether/v1/h2c".utf8),
            outputByteCount: 32
        )
        return ChannelKeys(clientToHost: c2h, hostToClient: h2c)
    }
}

/// ChaChaPoly with a per-direction counter. The receiver accepts only the next counter.
public struct SecureChannel: Sendable {
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey

    public init(role: ChannelRole, secret: SymmetricKey, nonceC: Data, nonceH: Data) {
        let keys = ChannelKeys.derive(secret: secret, nonceC: nonceC, nonceH: nonceH)
        switch role {
        case .client:
            sendKey = keys.clientToHost
            receiveKey = keys.hostToClient
        case .host:
            sendKey = keys.hostToClient
            receiveKey = keys.clientToHost
        }
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let nonce = try Self.nonce(sendCounter)
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        sendCounter &+= 1
        return box.combined
    }

    public mutating func open(_ sealed: Data) throws -> Data {
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: sealed)
        } catch {
            throw ProtocolFailure(code: .unauthorized, message: "Couldn't verify the connection.")
        }
        let expected = try Self.nonce(receiveCounter)
        guard Data(box.nonce) == Data(expected) else {
            throw ProtocolFailure(code: .unauthorized, message: "Rejected an out-of-order frame.")
        }
        let plain: Data
        do {
            plain = try ChaChaPoly.open(box, using: receiveKey)
        } catch {
            throw ProtocolFailure(code: .unauthorized, message: "Couldn't verify the connection.")
        }
        receiveCounter &+= 1
        return plain
    }

    /// 96-bit nonce: 4 zero bytes followed by the big-endian counter.
    static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        let big = counter.bigEndian
        withUnsafeBytes(of: big) { raw in
            for index in 0..<8 {
                bytes[4 + index] = raw[index]
            }
        }
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }
}

public extension SymmetricKey {
    var raw: Data {
        withUnsafeBytes { Data($0) }
    }

    static func random(count: Int = 32) -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status == errSecSuccess {
            return SymmetricKey(data: Data(bytes))
        }
        return SymmetricKey(size: .bits256)
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) throws -> Data {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: padded) else {
            throw ProtocolFailure(code: .badRequest, message: "That pairing code isn't valid.")
        }
        return data
    }
}

/// Crockford Base32, used for the 16-character manual pairing code.
public enum CrockfordBase32 {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var output = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(value >> bits) & 31])
            }
        }
        if bits > 0 {
            output.append(alphabet[(value << (5 - bits)) & 31])
        }
        return output
    }

    public static func decode(_ text: String) throws -> Data {
        var bits = 0
        var value = 0
        var output = Data()
        for character in text.uppercased() {
            if character == "-" || character.isWhitespace { continue }
            guard let symbol = symbolValue(character) else {
                throw ProtocolFailure(code: .badRequest, message: "That pairing code isn't valid.")
            }
            value = (value << 5) | symbol
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((value >> bits) & 0xff))
            }
        }
        return output
    }

    public static func grouped(_ data: Data) -> String {
        let raw = encode(data)
        var groups: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(index, offsetBy: 4, limitedBy: raw.endIndex) ?? raw.endIndex
            groups.append(String(raw[index..<next]))
            index = next
        }
        return groups.joined(separator: "-")
    }

    private static func symbolValue(_ character: Character) -> Int? {
        switch character {
        case "0", "O": return 0
        case "1", "I", "L": return 1
        default:
            guard let found = alphabet.firstIndex(of: character) else { return nil }
            return alphabet.distance(from: alphabet.startIndex, to: found)
        }
    }
}

public struct PairingOffer: Sendable {
    public var fullSecret: SymmetricKey
    public var shortSecret: SymmetricKey
    public var expiresAt: Date
    public var qr: String
    public var manualCode: String
    public var hostId: String
    public var hostName: String

    public var isExpired: Bool { Date() >= expiresAt }

    public init(hostId: String, hostName: String, now: Date = Date(), lifetime: TimeInterval = 120) {
        let secret = SymmetricKey.random()
        let raw = secret.raw
        self.fullSecret = secret
        self.shortSecret = SymmetricKey(data: raw.prefix(10))
        self.expiresAt = now.addingTimeInterval(lifetime)
        self.hostId = hostId
        self.hostName = hostName
        self.qr = PairingOffer.qrString(hostId: hostId, secret: raw, name: hostName)
        self.manualCode = CrockfordBase32.grouped(Data(raw.prefix(10)))
    }

    public func secret(for material: PairMaterial) -> SymmetricKey {
        switch material {
        case .full: fullSecret
        case .short: shortSecret
        }
    }

    public static func qrString(hostId: String, secret: Data, name: String) -> String {
        var components = URLComponents()
        components.scheme = "tether"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: hostId),
            URLQueryItem(name: "p", value: Base64URL.encode(secret)),
            URLQueryItem(name: "n", value: name),
        ]
        return components.string ?? "tether://pair"
    }
}

public struct PairingPayload: Sendable {
    public var hostId: String
    public var hostName: String
    public var secret: SymmetricKey
    public var material: PairMaterial

    public static func parseQR(_ text: String) throws -> PairingPayload {
        guard let components = URLComponents(string: text),
              components.scheme == "tether",
              components.host == "pair"
        else {
            throw ProtocolFailure(code: .badRequest, message: "That pairing code isn't valid.")
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard items["v"] == "1", let hostId = items["id"], let encoded = items["p"], !hostId.isEmpty else {
            throw ProtocolFailure(code: .badRequest, message: "That pairing code isn't valid.")
        }
        let secretData = try Base64URL.decode(encoded)
        guard secretData.count == 32 else {
            throw ProtocolFailure(code: .badRequest, message: "That pairing code isn't valid.")
        }
        return PairingPayload(
            hostId: hostId,
            hostName: items["n"] ?? "Mac",
            secret: SymmetricKey(data: secretData),
            material: .full
        )
    }

    public static func parseManual(code: String, hostId: String, hostName: String) throws -> PairingPayload {
        let data = try CrockfordBase32.decode(code)
        guard data.count == 10 else {
            throw ProtocolFailure(code: .badRequest, message: "Enter the 16-character code from your Mac.")
        }
        return PairingPayload(
            hostId: hostId,
            hostName: hostName,
            secret: SymmetricKey(data: data),
            material: .short
        )
    }
}

/// Keychain items are device-local and available after the first unlock. They are not synced.
/// On the Mac they live in the data protection keychain, so opening the app does not ask for the login keychain password.
public enum KeychainStore {
    public static func save(service: String, account: String, data: Data) throws {
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProtocolFailure(code: .internalError, message: "Couldn't save the pairing key on this device.")
        }
    }

    public static func load(service: String, account: String) throws -> Data? {
        if let data = read(baseQuery(service: service, account: account)) {
            return data
        }
        let older = legacyQuery(service: service, account: account)
        if let data = read(older) {
            try? save(service: service, account: account, data: data)
            SecItemDelete(older as CFDictionary)
            return data
        }
        return nil
    }

    public static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        SecItemDelete(legacyQuery(service: service, account: account) as CFDictionary)
    }

    private static func read(_ query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    /// Items saved before the data-protection keychain change, or without the synchronizable flag.
    private static func legacyQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

/// Five failed handshakes per minute per remote, and five failed pairing attempts lock pairing for five minutes.
public final class AbuseGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var handshakes: [String: [Date]] = [:]
    private var pairingFailures: [Date] = []
    private var pairingLockedUntil: Date?

    public init() {}

    public func isPairingLocked(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let until = pairingLockedUntil, now < until { return true }
        pairingLockedUntil = nil
        return false
    }

    @discardableResult
    public func recordHandshakeFailure(_ remote: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let recent = (handshakes[remote] ?? []).filter { now.timeIntervalSince($0) < 60 }
        let updated = recent + [now]
        handshakes[remote] = updated
        return updated.count > 5
    }

    @discardableResult
    public func recordPairingFailure(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pairingFailures = pairingFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if pairingFailures.count > 5 {
            pairingLockedUntil = now.addingTimeInterval(5 * 60)
            pairingFailures = []
            return true
        }
        return false
    }
}
