import Foundation

public struct ShellResult: Equatable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    public init(exitCode: Int32, output: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
    }
}

/// Thread-safe accumulator for process output.
private final class OutputBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        let string = String(decoding: data, as: UTF8.self)
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the tail only; error messages are at the end.
        return trimmed.count > 2000 ? String(trimmed.suffix(2000)) : trimmed
    }
}

public enum ShellRunner {
    /// GUI apps start with a minimal PATH, so add the usual Homebrew and system locations.
    public static let extraPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Runs `script` with `/bin/zsh -c`.
    public static func run(_ script: String, timeout: TimeInterval = 30) -> ShellResult {
        launch(executable: "/bin/zsh", arguments: ["-c", script], timeout: timeout)
    }

    /// Runs `script` as root through the standard macOS authorization dialog.
    public static func runAsAdmin(_ script: String, timeout: TimeInterval = 120) -> ShellResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        return launch(executable: "/usr/bin/osascript", arguments: ["-e", appleScript], timeout: timeout)
    }

    static func launch(executable: String, arguments: [String], timeout: TimeInterval) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? ""
        environment["PATH"] = existing.isEmpty ? extraPath : extraPath + ":" + existing
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { buffer.append(chunk) }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ShellResult(exitCode: -1, output: "Could not start \(executable): \(error.localizedDescription)", timedOut: false)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        // Drain whatever is left in the pipe after the process ended.
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { buffer.append(rest) }

        return ShellResult(exitCode: timedOut ? -1 : process.terminationStatus, output: buffer.text, timedOut: timedOut)
    }
}
