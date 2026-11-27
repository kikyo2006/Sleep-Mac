import Foundation

/// Pure rules for the sleep timer: when it fires, when it was missed, how it is shown.
public enum SleepSchedule {
    /// How long the "Mac will sleep in …" countdown lasts before Sleep runs.
    public static let countdownSeconds = 30
    /// A timer that fires later than this was missed (for example because the Mac was already asleep)
    /// and is dropped instead of putting a Mac to sleep that someone has just woken up.
    public static let missedGrace: TimeInterval = 120

    public enum Decision: Equatable {
        /// Not yet; check again after this many seconds.
        case wait(TimeInterval)
        /// Time is up: show the countdown.
        case startCountdown
        /// The time passed long ago; forget the timer.
        case missed
    }

    public static func decide(fireDate: Date, now: Date) -> Decision {
        let remaining = fireDate.timeIntervalSince(now)
        if remaining > 0 { return .wait(remaining) }
        return -remaining <= missedGrace ? .startCountdown : .missed
    }

    /// The next moment the clock shows `hour:minute` after `now`: later today, otherwise tomorrow.
    public static func nextOccurrence(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 3600)
    }

    /// "1 h 05 min", "12 min", "45 s". Minutes are rounded up so a timer never looks closer than it is.
    public static func describe(remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }
}

/// Seconds left in the countdown, computed from the wall clock so a late tick never stretches it.
public struct SleepCountdown {
    public let start: Date
    public let duration: Int

    public init(start: Date, duration: Int = SleepSchedule.countdownSeconds) {
        self.start = start
        self.duration = duration
    }

    public func secondsLeft(at now: Date) -> Int {
        let left = Double(duration) - now.timeIntervalSince(start)
        return max(0, Int(left.rounded(.up)))
    }

    public func isFinished(at now: Date) -> Bool { secondsLeft(at: now) == 0 }

    /// 0 at the start, 1 when finished.
    public func progress(at now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(start) / Double(duration)))
    }
}

/// One pending sleep time, remembered across app restarts.
///
/// Uses a wall-clock dispatch timer, so the time is kept even while the Mac sleeps in between;
/// the owner should still call `reevaluate()` after a wake or a clock change.
public final class SleepTimer {
    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date
    private var source: DispatchSourceTimer?

    /// Called on the main queue when the time has come.
    public var onFire: (() -> Void)?
    /// Called on the main queue whenever the timer is set, cleared or dropped.
    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults = .standard, key: String = "scheduledSleepDate", now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.now = now
    }

    deinit { source?.cancel() }

    public private(set) var fireDate: Date? {
        get { defaults.object(forKey: key) as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    public var isActive: Bool { fireDate != nil }

    public func schedule(at date: Date) {
        fireDate = date
        reevaluate()
        onChange?()
    }

    public func schedule(after interval: TimeInterval) {
        schedule(at: now().addingTimeInterval(interval))
    }

    public func cancel() {
        let wasActive = isActive
        disarm()
        fireDate = nil
        if wasActive { onChange?() }
    }

    /// Re-checks the stored time against the clock: arms the timer, fires it, or drops a missed one.
    public func reevaluate() {
        disarm()
        guard let fireDate else { return }
        switch SleepSchedule.decide(fireDate: fireDate, now: now()) {
        case .wait(let remaining):
            arm(after: remaining)
        case .startCountdown:
            Log.timer.notice("Sleep timer is due")
            self.fireDate = nil
            onChange?()
            onFire?()
        case .missed:
            Log.timer.notice("Sleep timer for \(fireDate, privacy: .public) was missed; dropped")
            self.fireDate = nil
            onChange?()
        }
    }

    private func arm(after seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(wallDeadline: .now() + seconds, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.reevaluate() }
        timer.resume()
        source = timer
    }

    private func disarm() {
        source?.cancel()
        source = nil
    }
}
