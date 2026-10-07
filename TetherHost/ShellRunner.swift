import Foundation
import TetherCore

/// Hardened host shell helper. v1.1 does not expose a general shell to the phone;
/// `HostRuntime.runShell` returns nil. This type remains for local tooling tests
/// and refuses to buffer unbounded output or leave orphan process groups.
enum ShellRunner {
    static func run(line: String, directory: URL, cwd: String) async -> TerminalResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: execute(line: line, directory: directory, cwd: cwd))
            }
        }
    }

    private static func execute(line: String, directory: URL, cwd: String) -> TerminalResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return TerminalResult(stderr: "tether: couldn't run that command.\n", cwd: cwd, exit: 127)
        }

        let group = DispatchGroup()
        let stdoutCap = cappedReader(handle: output.fileHandleForReading, group: group)
        let stderrCap = cappedReader(handle: error.fileHandleForReading, group: group)

        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            forceStop(process)
            _ = group.wait(timeout: .now() + 2)
            return TerminalResult(stderr: "tether: command timed out.\n", cwd: cwd, exit: 124)
        }
        group.wait()
        let stdoutData = stdoutCap.data
        let stderrData = stderrCap.data
        var result = TerminalResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            cwd: cwd,
            exit: Int(process.terminationStatus)
        )
        if stdoutCap.truncated || stderrCap.truncated {
            result.stderr += "tether: output truncated.\n"
        }
        return clip(result)
    }

    private static func cappedReader(handle: FileHandle, group: DispatchGroup) -> OutputCap {
        let cap = OutputCap()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            let limit = TetherCoreInfo.shellOutputCap
            while true {
                let chunk = handle.readData(ofLength: 16 * 1024)
                if chunk.isEmpty { break }
                cap.lock.lock()
                if cap.data.count < limit {
                    let room = limit - cap.data.count
                    cap.data.append(chunk.prefix(room))
                    if chunk.count > room { cap.truncated = true }
                } else {
                    cap.truncated = true
                }
                let stop = cap.truncated && cap.data.count >= limit
                cap.lock.unlock()
                if stop {
                    // Drain remainder so the child does not block on a full pipe forever.
                    while handle.readData(ofLength: 64 * 1024).count == 64 * 1024 {}
                    break
                }
            }
        }
        return cap
    }

    private static func forceStop(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 { kill(pid, SIGKILL) }
        }
    }

    private static func clip(_ result: TerminalResult) -> TerminalResult {
        var copy = result
        let cap = TetherCoreInfo.shellOutputCap
        if copy.stdout.utf8.count > cap {
            copy.stdout = String(copy.stdout.prefix(cap)) + "\n… output truncated\n"
        }
        if copy.stderr.utf8.count > cap {
            copy.stderr = String(copy.stderr.prefix(cap))
        }
        return copy
    }
}

private final class OutputCap: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var truncated = false
}
