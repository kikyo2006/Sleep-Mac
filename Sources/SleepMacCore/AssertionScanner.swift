import Darwin
import Foundation

/// One power assertion reported by `pmset -g assertions`.
public struct SleepAssertion: Equatable {
    public let pid: Int32
    public let processName: String
    public let type: String
    public let reason: String
    /// Set when a system daemon (for example coreaudiod) holds the assertion on behalf of another process.
    public let createdForPID: Int32?

    /// The process that really wants the Mac to stay awake.
    public var effectivePID: Int32 { createdForPID ?? pid }

    public var isBlocking: Bool { AssertionScanner.blockingTypes.contains(type) }
}

public enum AssertionScanner {
    /// Assertion types that stop the Mac from sleeping on its own.
    public static let blockingTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
        "NoIdleSleepAssertion",
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion"
    ]

    private static let headerPattern = try! NSRegularExpression(
        pattern: #"^\s*pid (\d+)\((.+?)\): \[0x[0-9a-fA-F]+\] [\d:]+ (\w+) named: "(.*)""#
    )
    private static let createdForPattern = try! NSRegularExpression(pattern: #"Created for PID: (\d+)"#)

    public static func parse(_ text: String) -> [SleepAssertion] {
        var result: [SleepAssertion] = []
        var pending: (pid: Int32, name: String, type: String, reason: String, createdFor: Int32?)?

        func flush() {
            guard let item = pending else { return }
            result.append(SleepAssertion(
                pid: item.pid, processName: item.name, type: item.type,
                reason: item.reason, createdForPID: item.createdFor
            ))
            pending = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine as NSString
            let fullRange = NSRange(location: 0, length: line.length)

            if let match = headerPattern.firstMatch(in: rawLine, range: fullRange) {
                flush()
                guard let pid = Int32(line.substring(with: match.range(at: 1))) else { continue }
                pending = (
                    pid: pid,
                    name: line.substring(with: match.range(at: 2)),
                    type: line.substring(with: match.range(at: 3)),
                    reason: line.substring(with: match.range(at: 4)),
                    createdFor: nil
                )
            } else if pending != nil,
                      let match = createdForPattern.firstMatch(in: rawLine, range: fullRange),
                      let target = Int32(line.substring(with: match.range(at: 1))) {
                pending?.createdFor = target
            }
        }
        flush()
        return result
    }

    public static func current() -> [SleepAssertion] {
        parse(ShellRunner.run("pmset -g assertions", timeout: 10).output)
    }
}

public enum SleepState {
    /// True when `pmset disablesleep 1` is active (`SleepDisabled 1`).
    public static func isSleepDisabled() -> Bool {
        isSleepDisabled(pmsetOutput: ShellRunner.run("pmset -g", timeout: 10).output)
    }

    public static func isSleepDisabled(pmsetOutput: String) -> Bool {
        for line in pmsetOutput.components(separatedBy: .newlines) where line.contains("SleepDisabled") {
            let value = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init)
            return value == "1"
        }
        return false
    }
}

public enum ProcessInspector {
    /// Full path of the executable behind `pid`, or nil when the process is gone.
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/lib/",
        "/Library/Apple/", "/Library/Developer/", "/private/var/run/com.apple.security.cryptexd/"
    ]

    /// A "command-line tool" is any executable that is not inside an app bundle and not part of macOS itself,
    /// for example `/usr/bin/caffeinate` or a binary under `/opt/homebrew/bin`.
    public static func isCommandLineTool(path: String) -> Bool {
        if path.contains(".app/") { return false }
        for prefix in systemPrefixes where path.hasPrefix(prefix) { return false }
        return true
    }
}
