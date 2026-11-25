import XCTest
@testable import SleepMacCore

final class SleepCoordinatorTests: XCTestCase {
    /// Starts a real `caffeinate` so the coordinator has something to find and stop.
    private func startCaffeinate() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-t", "600"]
        try process.run()
        // Give it a moment to register its assertion.
        Thread.sleep(forTimeInterval: 0.5)
        return process
    }

    func testDryRunFindsCaffeinateButDoesNotStopIt() throws {
        let caffeinate = try startCaffeinate()
        defer { caffeinate.terminate() }

        var lines: [String] = []
        let coordinator = SleepCoordinator(dryRun: true) { lines.append($0) }
        _ = coordinator.prepare(commands: [DefaultCommands.all[2]])

        XCTAssertTrue(lines.contains { $0.contains("Would stop caffeinate (pid \(caffeinate.processIdentifier))") }, "log: \(lines)")
        XCTAssertTrue(caffeinate.isRunning, "dry run must not stop anything")
    }

    func testPrepareStopsCaffeinate() throws {
        let caffeinate = try startCaffeinate()
        defer { if caffeinate.isRunning { caffeinate.terminate() } }

        let coordinator = SleepCoordinator()
        // Only the built-in blocker step, so the test never touches simulators or pmset settings.
        let report = coordinator.prepare(commands: [DefaultCommands.all[2]])

        XCTAssertTrue(report.terminated.contains { $0.contains("caffeinate") }, "terminated: \(report.terminated)")
        XCTAssertFalse(caffeinate.isRunning)
        XCTAssertFalse(report.remainingCommandLine.contains { $0.pid == caffeinate.processIdentifier })
    }

    func testFailingCustomCommandIsReportedButDefaultFailureIsNot() {
        let custom = SleepCommand(name: "Broken", script: "exit 7")
        let fakeDefault = SleepCommand(id: "default.fake", name: "Fake default", script: "exit 9", isDefault: true)
        let report = SleepCoordinator().prepare(commands: [fakeDefault, custom])
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].contains("Broken"))
        XCTAssertTrue(report.warnings[0].contains("exit code 7"))
    }

    func testCustomCommandsRunInOrder() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let commands = [
            SleepCommand(name: "A", script: "echo A >> '\(file.path)'"),
            SleepCommand(name: "B", script: "echo B >> '\(file.path)'"),
            SleepCommand(name: "C", script: "echo C >> '\(file.path)'")
        ]
        _ = SleepCoordinator().prepare(commands: commands)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, "A\nB\nC\n")
    }

    func testReportSummary() {
        var report = SleepReport()
        XCTAssertFalse(report.needsAttention)
        report.sleepStillDisabled = true
        report.warnings.append("Custom command “X” failed")
        XCTAssertTrue(report.needsAttention)
        XCTAssertTrue(report.attentionSummary.contains("disablesleep"))
        XCTAssertTrue(report.attentionSummary.contains("“X”"))
    }
}
