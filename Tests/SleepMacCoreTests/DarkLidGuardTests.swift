import XCTest
@testable import SleepMacCore

final class DarkLidGuardTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var lux: Double? = 100
    private var idle: TimeInterval = 0
    private var keepers: [String] = []
    private var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var triggers = 0

    override func setUp() {
        suite = "DarkLidGuardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        lux = 100
        idle = 0
        keepers = []
        clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
        triggers = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// An enabled guard whose wake grace has already passed.
    private func makeGuard(enabled: Bool = true) -> DarkLidGuard {
        let guardian = DarkLidGuard(defaults: defaults,
                                    lux: { [unowned self] in self.lux },
                                    idleSeconds: { [unowned self] in self.idle },
                                    displayKeptOnBy: { [unowned self] in self.keepers },
                                    now: { [unowned self] in self.clock })
        guardian.onTrigger = { [unowned self] in self.triggers += 1 }
        guardian.isEnabled = enabled
        guardian.systemDidWake()
        tick(DarkLidGuard.graceAfterWake + 1, guardian, checkEachSecond: false)
        return guardian
    }

    /// Moves the clock (and the idle time, as long as nobody "touches" the Mac) and checks every second.
    private func tick(_ seconds: TimeInterval, _ guardian: DarkLidGuard, checkEachSecond: Bool = true) {
        var left = seconds
        while left > 0 {
            let step = min(1, left)
            clock = clock.addingTimeInterval(step)
            idle += step
            left -= step
            if checkEachSecond { guardian.check() }
        }
    }

    private func closeLidAndWait(_ guardian: DarkLidGuard, seconds: TimeInterval = DarkLidGuard.darkSeconds + 2) {
        lux = 0.03
        tick(seconds, guardian)
    }

    func testDarkWithNoInputRunsSleep() {
        let guardian = makeGuard()
        idle = 0
        closeLidAndWait(guardian)
        XCTAssertEqual(triggers, 1)
    }

    func testNotBeforeTheDarkLastsLongEnough() {
        let guardian = makeGuard()
        idle = 0
        closeLidAndWait(guardian, seconds: DarkLidGuard.darkSeconds - 3)
        XCTAssertEqual(triggers, 0)
        XCTAssertTrue(guardian.isWaiting)
    }

    func testFiresOnlyOncePerDarkPeriod() {
        let guardian = makeGuard()
        idle = 0
        closeLidAndWait(guardian, seconds: 60)
        XCTAssertEqual(triggers, 1)
        lux = 100
        tick(DarkLidGuard.graceAfterWake, guardian)
        closeLidAndWait(guardian)
        XCTAssertEqual(triggers, 2, "a new dark period after light came back counts again")
    }

    func testFlickerRightAfterFiringDoesNotFireAgain() {
        let guardian = makeGuard()
        idle = 0
        closeLidAndWait(guardian)
        XCTAssertEqual(triggers, 1)
        // The display turns off while Sleep is on its way: one bright reading, then dark again.
        lux = 100
        tick(1, guardian)
        closeLidAndWait(guardian, seconds: DarkLidGuard.graceAfterWake - 5)
        XCTAssertEqual(triggers, 1, "Sleep is not asked for twice while the Mac is going to sleep")
        tick(DarkLidGuard.darkSeconds + 6, guardian)
        XCTAssertEqual(triggers, 2, "a Mac that never went to sleep is tried again after the quiet period")
    }

    func testInputInTheDarkMeansSomeoneIsUsingIt() {
        let guardian = makeGuard()
        lux = 0.03
        for _ in 0..<30 {
            idle = 0   // typing in a dark room
            tick(1, guardian)
        }
        XCTAssertEqual(triggers, 0)
    }

    func testBrightRoomNeverTriggers() {
        let guardian = makeGuard()
        idle = 0
        lux = 3
        tick(120, guardian)
        XCTAssertEqual(triggers, 0)
    }

    func testWaitsAfterWakeSoAStaleDarkReadingDoesNotLoop() {
        let guardian = makeGuard()
        idle = 0
        closeLidAndWait(guardian)
        XCTAssertEqual(triggers, 1)
        // Woken up; the sensor still reports the old dark value for a while.
        guardian.systemDidWake()
        idle = 0
        tick(DarkLidGuard.graceAfterWake - 1, guardian)
        XCTAssertEqual(triggers, 1, "nothing happens during the grace period")
    }

    func testStillDarkAfterTheGraceSleepsAgain() {
        let guardian = makeGuard()
        guardian.systemDidWake()
        idle = 0
        lux = 0.03
        tick(DarkLidGuard.graceAfterWake + DarkLidGuard.darkSeconds + 2, guardian)
        XCTAssertEqual(triggers, 1, "a Mac woken with the lid still shut goes back to sleep once the grace ends")
    }

    func testVideoKeepingTheDisplayOnIsLeftAlone() {
        let guardian = makeGuard()
        keepers = ["QuickTime Player"]
        idle = 0
        closeLidAndWait(guardian, seconds: 30)
        XCTAssertEqual(triggers, 0)
    }

    func testDisabledDoesNothingAndIsOffByDefault() {
        let fresh = DarkLidGuard(defaults: defaults, lux: { 0 }, idleSeconds: { 999 }, displayKeptOnBy: { [] })
        XCTAssertFalse(fresh.isEnabled)
        let guardian = makeGuard(enabled: false)
        idle = 0
        closeLidAndWait(guardian, seconds: 30)
        XCTAssertEqual(triggers, 0)
    }

    func testNoSensorIsUnavailable() {
        lux = nil
        let guardian = makeGuard()
        XCTAssertFalse(guardian.isAvailable)
        tick(30, guardian)
        XCTAssertEqual(triggers, 0)
    }

    func testFixedPointConversion() {
        XCTAssertEqual(AmbientLightSensor.lux(fromFixedPoint: 65536), 1)
        XCTAssertEqual(AmbientLightSensor.lux(fromFixedPoint: 1651), 0.025, accuracy: 0.001)
    }

    func testRealSensorCanBeRead() {
        // Read-only: on a MacBook this is a real lux value, on a Mac without a built-in display it is nil.
        if let level = AmbientLightSensor.shared.lux() { XCTAssertGreaterThanOrEqual(level, 0) }
    }
}
