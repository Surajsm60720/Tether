import Foundation

#if os(macOS)
import Darwin

/// Real login-home paths. Sandboxed apps remap `FileManager` home/Application Support
/// into the container; LaunchAgents and Terminal need the un-remapped locations.
public enum RealUserHome: Sendable {
    public static var directory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var applicationSupport: URL {
        directory.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static var launchAgents: URL {
        directory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
}
#endif
