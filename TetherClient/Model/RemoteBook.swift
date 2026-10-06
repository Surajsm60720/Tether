import Foundation
import TetherCore

enum ClientKeychain {
    static let service = "app.tether.client"
}

/// Saved remote route for a paired Mac. The token lives in the Keychain. Addresses do not.
enum RemoteBook {
    static func save(hostId: String, setup: RemoteSetup) {
        let defaults = UserDefaults.standard
        if let direct = setup.direct?.description {
            defaults.set(direct, forKey: directKey(hostId))
        } else {
            defaults.removeObject(forKey: directKey(hostId))
        }
        if let relay = setup.relay?.description {
            defaults.set(relay, forKey: relayKey(hostId))
        } else {
            defaults.removeObject(forKey: relayKey(hostId))
        }
        PairingSecrets.save(service: ClientKeychain.service, account: account(hostId), data: setup.token)
    }

    static func clear(hostId: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: directKey(hostId))
        defaults.removeObject(forKey: relayKey(hostId))
        PairingSecrets.delete(service: ClientKeychain.service, account: account(hostId))
    }

    static func summary(for hostId: String) -> String? {
        guard hasRoute(for: hostId) else { return nil }
        let defaults = UserDefaults.standard
        let parts = [
            defaults.string(forKey: directKey(hostId)).map { "Address \($0)" },
            defaults.string(forKey: relayKey(hostId)).map { "Relay \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func hasRoute(for hostId: String) -> Bool {
        let defaults = UserDefaults.standard
        let direct = defaults.string(forKey: directKey(hostId))
        let relay = defaults.string(forKey: relayKey(hostId))
        let token = PairingSecrets.load(service: ClientKeychain.service, account: account(hostId))
        return token?.count == 32 && (direct != nil || relay != nil)
    }

    static func connect(hostId: String) async throws -> NWByteStream {
        guard let token = PairingSecrets.load(service: ClientKeychain.service, account: account(hostId)), token.count == 32 else {
            throw RelayError.rejected
        }
        let defaults = UserDefaults.standard
        let direct = defaults.string(forKey: directKey(hostId)).flatMap { RemoteAddress.parse($0) }
        let relay = defaults.string(forKey: relayKey(hostId)).flatMap { RemoteAddress.parse($0) }
        if let direct {
            let timeout: Duration = direct.reach == .localNetwork ? .seconds(3) : .seconds(8)
            do {
                return try await TetherLink.connect(to: direct.endpoint, allowsCellular: true, timeout: timeout)
            } catch {
                if relay == nil { throw error }
            }
        }
        guard let relay else { throw RelayError.unreachable }
        return try await RelayClient.open(role: .client, address: relay, token: token)
    }

    private static func directKey(_ hostId: String) -> String { "remote.\(hostId).direct" }
    private static func relayKey(_ hostId: String) -> String { "remote.\(hostId).relay" }
    private static func account(_ hostId: String) -> String { "remote.\(hostId)" }
}
