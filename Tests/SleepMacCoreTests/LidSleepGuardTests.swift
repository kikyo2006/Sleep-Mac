import XCTest
@testable import SleepMacCore

private final class FakeLidSource: LidStateSource {
    var state: LidState?
    var onChange: ((LidState) -> Void)?
    func start() {}

    init(_ state: LidState?) { self.state = state }

    func set(closed: Bool, causesSleep: Bool = true) {
        let newState = LidState(isClosed: closed, closeCausesSleep: causesSleep)
        state = newState
        onChange?(newState)
    }
}

final class LidSleepGuardTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var scheduled: [(delay: TimeInterval, item: DispatchWorkItem)] = []

    override func setUp() {
        suite = "LidSleepGuardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        scheduled = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeGuard(_ source: FakeLidSource) -> (LidSleepGuard, () -> Int) {
        let guardian = LidSleepGuard(source: source, defaults: defaults, delay: 20) { [unowned self] delay, work in
            let item = DispatchWorkItem(block: work)
            self.scheduled.append((delay, item))
            return item
        }
        var triggers = 0
        guardian.onTrigger = { triggers += 1 }
        guardian.start()
        return (guardian, { triggers })
    }

    /// Runs whatever the fake scheduler still holds, as if the delay passed.
    private func elapse() {
        let items = scheduled
        scheduled = []
        for entry in items where !entry.item.isCancelled { entry.item.perform() }
    }

    func testClosedLidThatStaysAwakeTriggersSleep() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: true))
        let (guardian, triggers) = makeGuard(source)
        source.set(closed: true)
        XCTAssertTrue(guardian.isWaiting)
        XCTAssertEqual(scheduled.first?.delay, 20)
        elapse()
        XCTAssertEqual(triggers(), 1)
        XCTAssertFalse(guardian.isWaiting)
    }

    func testOpeningTheLidCancels() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: true))
        let (_, triggers) = makeGuard(source)
        source.set(closed: true)
        source.set(closed: false)
        elapse()
        XCTAssertEqual(triggers(), 0)
    }

    func testLidOpenedWithoutANotificationDoesNotTrigger() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: true))
        let (_, triggers) = makeGuard(source)
        source.set(closed: true)
        source.state = LidState(isClosed: false, closeCausesSleep: true)   // state re-read at check time
        elapse()
        XCTAssertEqual(triggers(), 0)
    }

    func testRealSleepCancels() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: true))
        let (guardian, triggers) = makeGuard(source)
        source.set(closed: true)
        guardian.systemWillSleep()
        elapse()
        XCTAssertEqual(triggers(), 0)
    }

    func testClamshellModeWithExternalDisplayIsLeftAlone() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: false))
        let (guardian, triggers) = makeGuard(source)
        source.set(closed: true, causesSleep: false)
        XCTAssertFalse(guardian.isWaiting)
        elapse()
        XCTAssertEqual(triggers(), 0)
    }

    func testExternalDisplayConnectedDuringTheWaitIsLeftAlone() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: true))
        let (_, triggers) = makeGuard(source)
        source.set(closed: true)
        source.state = LidState(isClosed: true, closeCausesSleep: false)
        elapse()
        XCTAssertEqual(triggers(), 0)
    }

    func testDisabledDoesNothingAndIsRemembered() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: true))
        let (guardian, triggers) = makeGuard(source)
        XCTAssertTrue(guardian.isEnabled, "on by default")
        guardian.isEnabled = false
        source.set(closed: true)
        elapse()
        XCTAssertEqual(triggers(), 0)
        XCTAssertFalse(makeGuard(source).0.isEnabled)
    }

    func testDisablingWhileWaitingCancels() {
        let source = FakeLidSource(LidState(isClosed: false, closeCausesSleep: true))
        let (guardian, triggers) = makeGuard(source)
        source.set(closed: true)
        guardian.isEnabled = false
        elapse()
        XCTAssertEqual(triggers(), 0)
    }

    func testMacWithoutALidIsUnavailable() {
        XCTAssertFalse(makeGuard(FakeLidSource(nil)).0.isAvailable)
    }

    func testRealLidStateCanBeRead() {
        // Read-only: on a MacBook this reports the open lid, on a desktop Mac it is nil.
        let state = IOKitLidStateSource().state
        if let state { XCTAssertFalse(state.isClosed, "the lid is open while the tests run") }
    }
}
