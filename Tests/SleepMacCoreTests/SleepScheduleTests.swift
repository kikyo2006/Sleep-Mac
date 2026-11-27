import XCTest
@testable import SleepMacCore

final class SleepScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    // MARK: - decide

    func testFutureTimeWaits() {
        XCTAssertEqual(SleepSchedule.decide(fireDate: date(27, 23, 0), now: date(27, 22, 0)), .wait(3600))
    }

    func testDueTimeStartsCountdown() {
        XCTAssertEqual(SleepSchedule.decide(fireDate: date(27, 23, 0), now: date(27, 23, 0)), .startCountdown)
        XCTAssertEqual(SleepSchedule.decide(fireDate: date(27, 23, 0), now: date(27, 23, 1, 30)), .startCountdown)
    }

    func testLongPastTimeIsMissed() {
        // The Mac was asleep at 23:00 and woken at 07:00: do not put it back to sleep.
        XCTAssertEqual(SleepSchedule.decide(fireDate: date(27, 23, 0), now: date(28, 7, 0)), .missed)
        XCTAssertEqual(SleepSchedule.decide(fireDate: date(27, 23, 0), now: date(27, 23, 2, 1)), .missed)
    }

    // MARK: - nextOccurrence

    func testLaterTodayStaysToday() {
        XCTAssertEqual(SleepSchedule.nextOccurrence(hour: 23, minute: 30, after: date(27, 21, 0), calendar: calendar), date(27, 23, 30))
    }

    func testEarlierTimeMeansTomorrow() {
        XCTAssertEqual(SleepSchedule.nextOccurrence(hour: 1, minute: 0, after: date(27, 21, 0), calendar: calendar), date(28, 1, 0))
    }

    func testCurrentMinuteMeansTomorrow() {
        XCTAssertEqual(SleepSchedule.nextOccurrence(hour: 21, minute: 0, after: date(27, 21, 0, 10), calendar: calendar), date(28, 21, 0))
    }

    // MARK: - describe

    func testDescribe() {
        XCTAssertEqual(SleepSchedule.describe(remaining: 45), "45 s")
        XCTAssertEqual(SleepSchedule.describe(remaining: 60), "1 min")
        XCTAssertEqual(SleepSchedule.describe(remaining: 61), "2 min")
        XCTAssertEqual(SleepSchedule.describe(remaining: 3600), "1 h 00 min")
        XCTAssertEqual(SleepSchedule.describe(remaining: 3900), "1 h 05 min")
        XCTAssertEqual(SleepSchedule.describe(remaining: -5), "0 s")
    }

    // MARK: - SleepCountdown

    func testCountdown() {
        let start = date(27, 23, 0)
        let countdown = SleepCountdown(start: start, duration: 30)
        XCTAssertEqual(countdown.secondsLeft(at: start), 30)
        XCTAssertEqual(countdown.secondsLeft(at: start.addingTimeInterval(0.2)), 30)
        XCTAssertEqual(countdown.secondsLeft(at: start.addingTimeInterval(29.5)), 1)
        XCTAssertTrue(countdown.isFinished(at: start.addingTimeInterval(30)))
        // A late tick (for example after the app was busy) never goes negative.
        XCTAssertEqual(countdown.secondsLeft(at: start.addingTimeInterval(95)), 0)
        XCTAssertEqual(countdown.progress(at: start.addingTimeInterval(15)), 0.5, accuracy: 0.001)
        XCTAssertEqual(SleepSchedule.countdownSeconds, 30)
    }
}

final class SleepTimerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "SleepTimerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeTimer() -> SleepTimer {
        SleepTimer(defaults: defaults, now: { [unowned self] in self.clock })
    }

    func testScheduleIsRememberedAcrossRestarts() {
        makeTimer().schedule(after: 600)
        let restarted = makeTimer()
        XCTAssertEqual(restarted.fireDate, clock.addingTimeInterval(600))
        XCTAssertTrue(restarted.isActive)
    }

    func testCancelClearsTheTimer() {
        let timer = makeTimer()
        var changes = 0
        timer.onChange = { changes += 1 }
        timer.schedule(after: 600)
        timer.cancel()
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(makeTimer().fireDate)
        XCTAssertEqual(changes, 2)
        timer.cancel()   // cancelling nothing is not a change
        XCTAssertEqual(changes, 2)
    }

    func testDueTimerFiresOnceAndClears() {
        let timer = makeTimer()
        var fired = 0
        timer.onFire = { fired += 1 }
        timer.schedule(after: 600)
        clock = clock.addingTimeInterval(601)
        timer.reevaluate()
        timer.reevaluate()
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(timer.isActive)
    }

    func testMissedTimerIsDroppedWithoutFiring() {
        makeTimer().schedule(after: 600)
        clock = clock.addingTimeInterval(8 * 3600)   // the Mac slept through it
        let restarted = makeTimer()
        var fired = false
        restarted.onFire = { fired = true }
        restarted.reevaluate()
        XCTAssertFalse(fired)
        XCTAssertFalse(restarted.isActive)
    }

    func testRealTimerFires() {
        let timer = SleepTimer(defaults: defaults)
        let fired = expectation(description: "fired")
        timer.onFire = { fired.fulfill() }
        timer.schedule(after: 0.3)
        wait(for: [fired], timeout: 3)
    }
}
