import CoreGraphics
import Foundation

/// "Sleep When Idle": a fallback that does not depend on the lid sensor.
/// If nobody has touched the keyboard, mouse or trackpad for the chosen number of minutes and the Mac
/// is still awake, something is holding it awake, so `onTrigger` runs the Sleep flow.
///
/// It stays away when an app keeps the display on (a video or a presentation), and it only acts after
/// two checks in a row about a minute apart on the wall clock, so a short maintenance wake (DarkWake,
/// ~45 s, display off) never triggers it.
public final class IdleSleepGuard {
    public static let defaultsKey = "sleepWhenIdleMinutes"
    public static let defaultMinutes = 30
    /// Choices offered in the menu; 0 means off.
    public static let choices = [0, 15, 30, 60]
    public static let checkInterval: TimeInterval = 60
    /// Two positive checks must be closer than this on the wall clock to count as "awake the whole time".
    static let maxGapBetweenChecks: TimeInterval = 90

    /// Assertion types that mean "an app wants the screen on".
    static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    private let defaults: UserDefaults
    private let idleSeconds: () -> TimeInterval
    private let displayKeptOnBy: () -> [String]
    private let now: () -> Date
    private var source: DispatchSourceTimer?
    private var lastPositiveCheck: Date?
    /// Set after a trigger; cleared once someone uses the Mac again, so a Mac that refuses to sleep
    /// is not hammered every minute.
    private var firedThisIdlePeriod = false

    /// Called on the main queue when the Mac should be put to sleep.
    public var onTrigger: (() -> Void)?

    public init(defaults: UserDefaults = .standard,
                idleSeconds: @escaping () -> TimeInterval = IdleSleepGuard.systemIdleSeconds,
                displayKeptOnBy: @escaping () -> [String] = IdleSleepGuard.appsKeepingDisplayOn,
                now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.idleSeconds = idleSeconds
        self.displayKeptOnBy = displayKeptOnBy
        self.now = now
    }

    deinit { source?.cancel() }

    /// 0 = off. Defaults to 30 minutes.
    public var minutes: Int {
        get { defaults.object(forKey: Self.defaultsKey) as? Int ?? Self.defaultMinutes }
        set {
            defaults.set(max(0, newValue), forKey: Self.defaultsKey)
            lastPositiveCheck = nil
            firedThisIdlePeriod = false
        }
    }

    public var isEnabled: Bool { minutes > 0 }

    public func start() {
        guard source == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        source = timer
    }

    /// One periodic check. Internal so tests can drive it.
    func check() {
        guard isEnabled else { return }
        let idle = idleSeconds()
        let threshold = TimeInterval(minutes * 60)
        guard idle >= threshold else {
            lastPositiveCheck = nil
            firedThisIdlePeriod = false
            return
        }
        guard !firedThisIdlePeriod else { return }

        let keepers = displayKeptOnBy()
        guard keepers.isEmpty else {
            lastPositiveCheck = nil
            Log.idle.notice("Idle \(Int(idle), privacy: .public) s, but the display is kept on by \(keepers.joined(separator: ", "), privacy: .public); leaving it alone")
            return
        }

        let current = now()
        defer { lastPositiveCheck = current }
        guard let previous = lastPositiveCheck, current.timeIntervalSince(previous) <= Self.maxGapBetweenChecks else {
            Log.idle.notice("Idle \(Int(idle), privacy: .public) s and still awake; confirming on the next check")
            return
        }
        firedThisIdlePeriod = true
        Log.idle.notice("Idle \(Int(idle), privacy: .public) s and the Mac is still awake: running Sleep")
        onTrigger?()
    }

    // MARK: - System readings

    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    public static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Names of apps holding a display assertion. Command-line tools do not count: Sleep stops them anyway.
    public static func appsKeepingDisplayOn() -> [String] {
        displayKeepers(in: AssertionScanner.current()) { pid in
            guard let path = ProcessInspector.executablePath(pid: pid) else { return false }
            return ProcessInspector.isCommandLineTool(path: path)
        }
    }

    static func displayKeepers(in assertions: [SleepAssertion], isCommandLineTool: (Int32) -> Bool) -> [String] {
        let names = assertions
            .filter { displayTypes.contains($0.type) && $0.processName != "powerd" && !isCommandLineTool($0.effectivePID) }
            .map(\.processName)
        return Array(Set(names)).sorted()
    }
}
