import Darwin
import Foundation

/// A process that currently stops the Mac from sleeping.
public struct Blocker: Equatable {
    public let pid: Int32
    public let name: String
    public let path: String
    public let reason: String
    public let isCommandLine: Bool
}

public struct SleepReport {
    /// Problems worth telling the user about before sleeping.
    public var warnings: [String] = []
    /// Command-line tools that were stopped.
    public var terminated: [String] = []
    /// Command-line tools that still hold a sleep assertion after cleanup.
    public var remainingCommandLine: [Blocker] = []
    /// Apps and system daemons that hold an assertion (informational, never killed).
    public var otherBlockers: [Blocker] = []
    public var sleepStillDisabled = false

    public init() {}

    public var needsAttention: Bool {
        !warnings.isEmpty || !remainingCommandLine.isEmpty || sleepStillDisabled
    }

    public var attentionSummary: String {
        var lines: [String] = []
        if sleepStillDisabled {
            lines.append("• System sleep is still disabled (pmset disablesleep is 1).")
        }
        for blocker in remainingCommandLine {
            lines.append("• \(blocker.name) (pid \(blocker.pid)) still keeps the Mac awake: \(blocker.reason)")
        }
        for warning in warnings {
            lines.append("• \(warning)")
        }
        return lines.joined(separator: "\n")
    }
}

public final class SleepCoordinator {
    private let dryRun: Bool
    private let log: (String) -> Void

    /// - Parameters:
    ///   - dryRun: describe what would happen without changing anything.
    ///   - log: receives progress lines (used by `--dry-run`).
    public init(dryRun: Bool = false, log: @escaping (String) -> Void = { _ in }) {
        self.dryRun = dryRun
        self.log = log
    }

    /// Runs every command in order, then verifies nothing is left that keeps the Mac awake.
    /// Blocking; call it off the main thread.
    public func prepare(commands: [SleepCommand]) -> SleepReport {
        var report = SleepReport()

        for command in commands {
            switch command.kind {
            case .shell:
                runShell(command, report: &report)
            case .terminateSleepBlockers:
                terminateBlockers(report: &report)
            case .restoreSystemSleep:
                restoreSystemSleep(report: &report)
            }
        }

        if dryRun {
            let blockers = Self.collectBlockers()
            report.otherBlockers = blockers.filter { !$0.isCommandLine }
            log("Other assertions (never touched): \(report.otherBlockers.map { "\($0.name) (pid \($0.pid))" }.joined(separator: ", "))")
            return report
        }

        // Simulators and daemons release their assertions a moment after they exit.
        Thread.sleep(forTimeInterval: 1.5)
        let blockers = Self.collectBlockers()
        report.remainingCommandLine = blockers.filter { $0.isCommandLine }
        report.otherBlockers = blockers.filter { !$0.isCommandLine }
        report.sleepStillDisabled = SleepState.isSleepDisabled()
        return report
    }

    /// Puts the Mac to sleep immediately.
    @discardableResult
    public func sleepNow() -> ShellResult {
        if dryRun {
            log("Would run: pmset sleepnow")
            return ShellResult(exitCode: 0, output: "", timedOut: false)
        }
        return ShellRunner.run("/usr/bin/pmset sleepnow", timeout: 10)
    }

    // MARK: - Steps

    private func runShell(_ command: SleepCommand, report: inout SleepReport) {
        if dryRun {
            log("Would run\(command.requiresAdmin ? " (admin)" : ""): \(command.name) -> \(command.script)")
            return
        }
        let result = command.requiresAdmin
            ? ShellRunner.runAsAdmin(command.script)
            : ShellRunner.run(command.script)
        log("\(command.name): exit \(result.exitCode)")
        // Failures of default commands are expected (no simulator running, no Xcode) and not worth a prompt.
        guard !result.succeeded, !command.isDefault else { return }
        let detail = result.timedOut ? "timed out" : "exit code \(result.exitCode)"
        let output = result.output.isEmpty ? "" : ": \(result.output)"
        report.warnings.append("Custom command “\(command.name)” failed (\(detail))\(output)")
    }

    private func terminateBlockers(report: inout SleepReport) {
        let targets = Self.collectBlockers().filter { $0.isCommandLine }
        if targets.isEmpty { log("No command-line tool is holding a sleep assertion.") }
        for target in targets {
            if dryRun {
                log("Would stop \(target.name) (pid \(target.pid)): \(target.reason)")
                continue
            }
            switch Self.terminate(pid: target.pid) {
            case .stopped:
                log("Stopped \(target.name) (pid \(target.pid))")
                report.terminated.append("\(target.name) (pid \(target.pid))")
            case .notPermitted:
                report.warnings.append("No permission to stop \(target.name) (pid \(target.pid)).")
            case .stillRunning:
                report.warnings.append("\(target.name) (pid \(target.pid)) did not stop.")
            }
        }
    }

    private func restoreSystemSleep(report: inout SleepReport) {
        guard SleepState.isSleepDisabled() else {
            log("System sleep is already enabled.")
            return
        }
        if dryRun {
            log("Would run (admin): pmset -a disablesleep 0")
            return
        }
        let result = ShellRunner.runAsAdmin("/usr/bin/pmset -a disablesleep 0")
        log("Re-enable system sleep: exit \(result.exitCode)")
        if !result.succeeded {
            let reason = result.output.isEmpty ? "" : ": \(result.output)"
            report.warnings.append("Could not turn disablesleep off\(reason)")
        }
    }

    // MARK: - Helpers

    /// Every process that currently holds a blocking assertion, one entry per process.
    static func collectBlockers() -> [Blocker] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<Int32>()
        var result: [Blocker] = []
        for assertion in AssertionScanner.current() where assertion.isBlocking {
            let pid = assertion.effectivePID
            guard pid > 1, pid != myPID, seen.insert(pid).inserted,
                  let path = ProcessInspector.executablePath(pid: pid) else { continue }
            result.append(Blocker(
                pid: pid,
                name: (path as NSString).lastPathComponent,
                path: path,
                reason: assertion.reason,
                isCommandLine: ProcessInspector.isCommandLineTool(path: path)
            ))
        }
        return result
    }

    enum TerminateOutcome { case stopped, notPermitted, stillRunning }

    /// SIGTERM first, SIGKILL if the process is still alive after two seconds.
    static func terminate(pid: Int32) -> TerminateOutcome {
        if kill(pid, SIGTERM) != 0 {
            return errno == ESRCH ? .stopped : .notPermitted
        }
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return .stopped }
            Thread.sleep(forTimeInterval: 0.1)
        }
        _ = kill(pid, SIGKILL)
        Thread.sleep(forTimeInterval: 0.3)
        return kill(pid, 0) != 0 ? .stopped : .stillRunning
    }
}
