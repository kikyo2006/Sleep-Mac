import XCTest
@testable import SleepMacCore

final class IdleSleepGuardTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var idle: TimeInterval = 0
    private var keepers: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var triggers = 0

    override func setUp() {
        suite = "IdleSleepGuardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        idle = 0; keepers = []; triggers = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeGuard() -> IdleSleepGuard {
        let guardian = IdleSleepGuard(defaults: defaults,
                                      idleSeconds: { [unowned self] in self.idle },
                                      displayKeptOnBy: { [unowned self] in self.keepers },
                                      now: { [unowned self] in self.clock })
        guardian.onTrigger = { [unowned self] in self.triggers += 1 }
        return guardian
    }

    /// One check a minute later, with the idle time growing by the same minute.
    private func tick(_ guardian: IdleSleepGuard, minutes: Double = 1) {
        clock = clock.addingTimeInterval(minutes * 60)
        idle += minutes * 60
        guardian.check()
    }

    func testDefaultsTo30Minutes() {
        XCTAssertEqual(makeGuard().minutes, 30)
        XCTAssertTrue(makeGuard().isEnabled)
    }

    func testIdleMacThatStaysAwakeTriggersAfterTwoChecks() {
        let guardian = makeGuard()
        idle = 29 * 60
        guardian.check()
        XCTAssertEqual(triggers, 0)
        tick(guardian)          // 30 min: first positive check only confirms
        XCTAssertEqual(triggers, 0)
        tick(guardian)          // 31 min: confirmed
        XCTAssertEqual(triggers, 1)
    }

    func testDoesNotRepeatUntilSomeoneUsesTheMac() {
        let guardian = makeGuard()
        idle = 30 * 60
        guardian.check(); tick(guardian)
        XCTAssertEqual(triggers, 1)
        tick(guardian); tick(guardian)      // the Mac refused to sleep: no hammering
        XCTAssertEqual(triggers, 1)
        idle = 0
        guardian.check()                    // someone used it
        idle = 30 * 60
        guardian.check(); tick(guardian)
        XCTAssertEqual(triggers, 2)
    }

    func testShortMaintenanceWakesNeverTrigger() {
        // Each DarkWake sees a huge idle time, but the checks are ~15 min apart on the wall clock.
        let guardian = makeGuard()
        idle = 3 * 3600
        for _ in 0..<5 { tick(guardian, minutes: 15) }
        XCTAssertEqual(triggers, 0)
    }

    func testAppKeepingTheDisplayOnIsRespected() {
        let guardian = makeGuard()
        keepers = ["IINA"]
        idle = 40 * 60
        guardian.check(); tick(guardian); tick(guardian)
        XCTAssertEqual(triggers, 0)
        keepers = []
        tick(guardian)
        XCTAssertEqual(triggers, 0, "needs a fresh confirmation")
        tick(guardian)
        XCTAssertEqual(triggers, 1)
    }

    func testOffDoesNothingAndIsRemembered() {
        let guardian = makeGuard()
        guardian.minutes = 0
        XCTAssertFalse(guardian.isEnabled)
        idle = 5 * 3600
        guardian.check(); tick(guardian); tick(guardian)
        XCTAssertEqual(triggers, 0)
        XCTAssertEqual(makeGuard().minutes, 0)
    }

    func testShorterThreshold() {
        let guardian = makeGuard()
        guardian.minutes = 15
        idle = 15 * 60
        guardian.check(); tick(guardian)
        XCTAssertEqual(triggers, 1)
    }

    func testDisplayKeepersIgnorePowerdAndCommandLineTools() {
        let assertions = [
            SleepAssertion(pid: 10, processName: "powerd", type: "PreventUserIdleDisplaySleep", reason: "x", createdForPID: nil),
            SleepAssertion(pid: 20, processName: "caffeinate", type: "PreventUserIdleDisplaySleep", reason: "x", createdForPID: nil),
            SleepAssertion(pid: 30, processName: "IINA", type: "PreventUserIdleDisplaySleep", reason: "video", createdForPID: nil),
            SleepAssertion(pid: 40, processName: "coreaudiod", type: "PreventUserIdleSystemSleep", reason: "sim", createdForPID: 99)
        ]
        XCTAssertEqual(IdleSleepGuard.displayKeepers(in: assertions) { $0 == 20 }, ["IINA"])
    }

    func testRealIdleTimeCanBeRead() {
        XCTAssertGreaterThanOrEqual(IdleSleepGuard.systemIdleSeconds(), 0)
    }
}
