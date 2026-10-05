import Foundation
import TetherCore

enum ShellRunner {
    /// Runs a command with zsh on the Mac. The working directory is the shared folder when there is one.
    static func run(line: String, directory: URL, cwd: String) async -> TerminalResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: TerminalResult(
                        stderr: "tether: couldn't run that command.\n",
                        cwd: cwd,
                        exit: 127
                    ))
                    return
                }
                let collected = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()
                collected.enter()
                DispatchQueue.global().async {
                    stdoutData = output.fileHandleForReading.readDataToEndOfFile()
                    collected.leave()
                }
                collected.enter()
                DispatchQueue.global().async {
                    stderrData = error.fileHandleForReading.readDataToEndOfFile()
                    collected.leave()
                }
                let deadline = Date().addingTimeInterval(20)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    collected.wait()
                    continuation.resume(returning: TerminalResult(
                        stderr: "tether: command timed out.\n",
                        cwd: cwd,
                        exit: 124
                    ))
                    return
                }
                collected.wait()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: clip(TerminalResult(
                    stdout: stdout,
                    stderr: stderr,
                    cwd: cwd,
                    exit: Int(process.terminationStatus)
                )))
            }
        }
    }

    private static func clip(_ result: TerminalResult) -> TerminalResult {
        var copy = result
        let cap = 256 * 1024
        if copy.stdout.utf8.count > cap { copy.stdout = String(copy.stdout.prefix(cap)) + "\n… output truncated\n" }
        if copy.stderr.utf8.count > cap { copy.stderr = String(copy.stderr.prefix(cap)) }
        return copy
    }
}
