import Foundation

/// Holds a live agent terminal while the phone is away.
/// Bytes that arrive with no listener are kept, in order, and delivered on resume.
public final class TerminalBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.tether.terminal-bridge")
    private var onData: (@Sendable (Data) -> Void)?
    private var onExit: (@Sendable (Int32) -> Void)?
    private var pending = Data()
    private var exitCode: Int32?
    private let cap: Int

    public init(cap: Int = 2 * 1024 * 1024) {
        self.cap = cap
    }

    public func push(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if exitCode != nil {
            lock.unlock()
            return
        }
        if let onData {
            lock.unlock()
            queue.async { onData(data) }
            return
        }
        pending.append(data)
        if pending.count > cap {
            pending.removeFirst(pending.count - cap)
        }
        lock.unlock()
    }

    public func finish(_ code: Int32) {
        lock.lock()
        if exitCode != nil {
            lock.unlock()
            return
        }
        exitCode = code
        let handler = onExit
        lock.unlock()
        if let handler {
            queue.async { handler(code) }
        }
    }

    /// Drops the current listener. The process keeps running and further output is saved.
    public func suspend() {
        lock.lock()
        onData = nil
        onExit = nil
        lock.unlock()
    }

    /// Attaches a listener. Saved output is delivered before anything newer, then an exit if the process already ended.
    public func resume(onData: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        let buffered = pending
        let code = exitCode
        pending.removeAll(keepingCapacity: true)
        self.onData = code == nil ? onData : nil
        self.onExit = code == nil ? onExit : nil
        lock.unlock()
        queue.async {
            if !buffered.isEmpty { onData(buffered) }
            if let code { onExit(code) }
        }
    }
}
