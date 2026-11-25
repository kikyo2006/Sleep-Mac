import XCTest
@testable import SleepMacCore

final class AssertionScannerTests: XCTestCase {
    private let sample = """
    Assertion status system-wide:
       PreventUserIdleSystemSleep     1
    Listed by owning process:
       pid 68544(Claude): [0x00070b7600019ec0] 00:00:04 NoIdleSleepAssertion named: "Electron"
       pid 4304(Claude Helper (Renderer)): [0x00070b7600019ec9] 00:00:01 NoIdleSleepAssertion named: "Renderer"
       pid 173(coreaudiod): [0x0006f9c500019b4b] 01:15:33 PreventUserIdleSystemSleep named: "com.apple.audio.iOSSimulatorAudioDevice-12900-2.context.preventuseridlesleep"
    \tCreated for PID: 12900.
    \tResources: audio-out BuiltInSpeakerDevice
       pid 5150(caffeinate): [0x0000000000000001] 00:01:00 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
    \tTimeout will fire in 597 secs Action=TimeoutActionRelease
       pid 160(WindowServer): [0x00070b6300099eb5] 00:00:02 UserIsActive named: "com.apple.iohideventsystem.queue.tickle"
    Kernel Assertions: 0x100=MAGICWAKE
    """

    func testParsesAllAssertions() {
        XCTAssertEqual(AssertionScanner.parse(sample).count, 5)
    }

    func testProcessNameWithParentheses() {
        let helper = AssertionScanner.parse(sample).first { $0.pid == 4304 }
        XCTAssertEqual(helper?.processName, "Claude Helper (Renderer)")
    }

    func testOnlyBlockingTypesAreBlocking() {
        let blocking = AssertionScanner.parse(sample).filter { $0.isBlocking }.map { $0.pid }
        XCTAssertEqual(Set(blocking), [68544, 4304, 173, 5150])
    }

    func testCreatedForPidBecomesEffectivePid() {
        let audio = AssertionScanner.parse(sample).first { $0.pid == 173 }
        XCTAssertEqual(audio?.createdForPID, 12900)
        XCTAssertEqual(audio?.effectivePID, 12900)
        let caffeinate = AssertionScanner.parse(sample).first { $0.pid == 5150 }
        XCTAssertNil(caffeinate?.createdForPID)
        XCTAssertEqual(caffeinate?.effectivePID, 5150)
    }

    func testEmptyInput() {
        XCTAssertTrue(AssertionScanner.parse("").isEmpty)
    }

    func testSleepDisabledParsing() {
        XCTAssertTrue(SleepState.isSleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n"))
        XCTAssertFalse(SleepState.isSleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t0\n"))
        XCTAssertFalse(SleepState.isSleepDisabled(pmsetOutput: "Currently in use:\n sleep 1\n"))
    }

    func testCommandLineToolClassification() {
        XCTAssertTrue(ProcessInspector.isCommandLineTool(path: "/usr/bin/caffeinate"))
        XCTAssertTrue(ProcessInspector.isCommandLineTool(path: "/opt/homebrew/bin/some-tool"))
        XCTAssertFalse(ProcessInspector.isCommandLineTool(path: "/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertFalse(ProcessInspector.isCommandLineTool(path: "/usr/libexec/powerd"))
        XCTAssertFalse(ProcessInspector.isCommandLineTool(path: "/usr/sbin/coreaudiod"))
        XCTAssertFalse(ProcessInspector.isCommandLineTool(path: "/System/Library/CoreServices/WindowServer"))
        XCTAssertFalse(ProcessInspector.isCommandLineTool(
            path: "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v1/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS"
        ))
    }
}
