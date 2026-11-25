import XCTest
@testable import SleepMacCore

final class ShellRunnerTests: XCTestCase {
    func testCapturesOutputAndExitCode() {
        let ok = ShellRunner.run("echo hello")
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.output, "hello")

        let failed = ShellRunner.run("echo oops >&2; exit 3")
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.exitCode, 3)
        XCTAssertEqual(failed.output, "oops")
    }

    func testTimeoutStopsLongCommand() {
        let started = Date()
        let result = ShellRunner.run("sleep 30", timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testPathIncludesHomebrewAndSystemDirectories() {
        let result = ShellRunner.run("echo $PATH")
        XCTAssertTrue(result.output.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.output.contains("/usr/bin"))
    }

    func testLargeOutputDoesNotDeadlock() {
        let result = ShellRunner.run("yes line | head -n 200000", timeout: 10)
        XCTAssertTrue(result.succeeded)
        XCTAssertLessThanOrEqual(result.output.count, 2000)
    }

    func testMissingCommandReportsNonZeroExit() {
        let result = ShellRunner.run("definitely-not-a-real-command-xyz")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 127)
    }
}
