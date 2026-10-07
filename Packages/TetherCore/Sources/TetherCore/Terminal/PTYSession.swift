import Foundation
#if os(macOS)
import Darwin

/// A real terminal on this Mac. The child is started with `posix_spawn` so a
/// multithreaded host never has to call `fork`. The slave side is the program's
/// stdin, stdout, and stderr; this object owns the master side.
public final class PTYSession: @unchecked Sendable {
    public let id: String
    private let queue: DispatchQueue
    private var master: Int32 = -1
    private var pid: pid_t = -1
    private var finished = false
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private var pendingOut = Data()
    private var flushScheduled = false
    private var lastFlush: DispatchTime?
    private let onData: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void

    public static func start(
        id: String,
        argv: [String],
        directory: String,
        environment: [String: String],
        columns: Int,
        rows: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> PTYSession? {
        guard !argv.isEmpty, let program = argv.first else { return nil }
        let columns = min(500, max(2, columns))
        let rows = min(200, max(2, rows))
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            TetherLog.terminal.error("openpty failed")
            return nil
        }
        // Software flow control would swallow Ctrl-S / Ctrl-Q and freeze the screen,
        // which looks exactly like Tab did nothing.
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 {
            attributes.c_iflag &= ~tcflag_t(IXON | IXOFF)
            _ = tcsetattr(slave, TCSANOW, &attributes)
        }

        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)
        _ = directory.withCString { path in
            posix_spawn_file_actions_addchdir_np(&actions, path)
        }

        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, flags)

        let argvC = cStrings(argv)
        let envC = cStrings(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            argvC.forEach { free($0) }
            envC.forEach { free($0) }
        }
        var child: pid_t = 0
        let spawned = argvC.withUnsafeBufferPointer { argvBuf in
            envC.withUnsafeBufferPointer { envBuf in
                program.withCString { path in
                    posix_spawn(&child, path, &actions, &attr, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
        }
        close(slave)
        guard spawned == 0, child > 0 else {
            close(master)
            TetherLog.terminal.error("pty spawn failed")
            return nil
        }
        let descriptor = fcntl(master, F_GETFD)
        _ = fcntl(master, F_SETFD, descriptor | FD_CLOEXEC)
        let statusFlags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, statusFlags | O_NONBLOCK)

        let session = PTYSession(id: id, master: master, pid: child, onData: onData, onExit: onExit)
        session.arm()
        return session
    }

    private init(id: String, master: Int32, pid: pid_t, onData: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        self.id = id
        self.master = master
        self.pid = pid
        self.onData = onData
        self.onExit = onExit
        queue = DispatchQueue(label: "app.tether.pty.\(id)")
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let copy = data
        queue.async { [weak self] in
            self?.writeNow(copy)
        }
    }

    public func resize(columns: Int, rows: Int) {
        let columns = min(500, max(2, columns))
        let rows = min(200, max(2, rows))
        queue.async { [weak self] in
            guard let self, self.master >= 0 else { return }
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.master, TIOCSWINSZ, &size)
        }
    }

    /// Asks the program to quit. Closing the master also hangs up the terminal.
    public func terminate() {
        queue.async { [weak self] in
            guard let self, !self.finished, self.pid > 0 else { return }
            kill(-self.pid, SIGHUP)
            kill(self.pid, SIGHUP)
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.finished, self.pid > 0 else { return }
            kill(self.pid, SIGKILL)
        }
    }

    private func arm() {
        let fd = master
        let process = pid
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        let proc = DispatchSource.makeProcessSource(identifier: process, eventMask: .exit, queue: queue)
        proc.setEventHandler { [weak self] in self?.finish() }
        readSource = read
        procSource = proc
        read.resume()
        proc.resume()
        queue.async { [weak self] in self?.drain() }
    }

    private func writeNow(_ data: Data) {
        guard master >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            var waits = 0
            while sent < raw.count && waits < 40 {
                let count = Darwin.write(master, base.advanced(by: sent), raw.count - sent)
                if count > 0 {
                    sent += count
                    waits = 0
                    continue
                }
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    waits += 1
                    usleep(5_000)
                    continue
                }
                break
            }
        }
    }

    private func drain() {
        guard master >= 0, !finished else { return }
        readAvailable()
    }

    private func readAvailable() {
        guard master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                emit(Data(buffer.prefix(count)))
                continue
            }
            break
        }
    }

    /// Groups terminal output. A keystroke echo goes out quickly. A long run is
    /// batched so the phone is not asked to redraw on every read.
    private func emit(_ data: Data) {
        pendingOut.append(data)
        let streaming = lastFlush.map { DispatchTime.now() < $0 + .milliseconds(35) } ?? false
        let cap = streaming ? 64 * 1024 : 12 * 1024
        if pendingOut.count >= cap {
            flushOut()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        let delay: DispatchTimeInterval = streaming ? .milliseconds(40) : .milliseconds(10)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushOut()
        }
    }

    private func flushOut() {
        guard !pendingOut.isEmpty else { return }
        lastFlush = .now()
        let data = pendingOut
        pendingOut.removeAll(keepingCapacity: true)
        onData(data)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        readAvailable()
        flushOut()
        readSource?.cancel()
        readSource = nil
        var status: Int32 = 0
        if pid > 0 {
            if waitpid(pid, &status, WNOHANG) == 0 {
                _ = waitpid(pid, &status, 0)
            }
        }
        if master >= 0 {
            close(master)
            master = -1
        }
        procSource?.cancel()
        procSource = nil
        onExit(Self.exitCode(status))
        pid = 0
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    private static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        values.map { strdup($0) } + [nil]
    }
}
#endif
