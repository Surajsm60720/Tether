import Foundation
import TetherCore

/// Listens on a public machine. The Mac and the iPhone both connect out to this process.
/// Usage: tether-relay [port]
@main
struct TetherRelay {
    static func main() async {
        var port = TetherPorts.relay
        if let argument = CommandLine.arguments.dropFirst().first, let parsed = UInt16(argument), parsed > 0 {
            port = parsed
        }
        do {
            let server = try await RelayServer.start(port: port)
            fputs("Tether relay listening on port \(server.port). Leave this running.\n", stderr)
            while true {
                try await Task.sleep(for: .seconds(3600))
            }
        } catch {
            fputs("Tether relay could not start.\n", stderr)
            Foundation.exit(1)
        }
    }
}
