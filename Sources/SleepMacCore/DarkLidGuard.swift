import Foundation
import IOKit

/// "Sleep When Lid Closes (Light Sensor)": for a MacBook whose lid sensor never reports a closed lid.
///
/// The ambient light sensor sits in the display bezel, so with the lid shut it reads almost total
/// darkness. When it has been that dark for `darkSeconds` and nobody has touched the keyboard or
/// trackpad in that time, the lid is taken as closed and `onTrigger` runs the Sleep flow.
///
/// Safety catches, so it does not put a Mac to sleep that someone is using in a dark room:
/// - any keyboard, mouse or trackpad input resets it;
/// - it waits `graceAfterWake` after a wake or a launch (the sensor can report the old dark value
///   for a moment after waking, which would otherwise send the Mac straight back to sleep);
/// - it stays away while a video player keeps the display on;
/// - it fires at most once per dark period.
public final class DarkLidGuard {
    public static let defaultsKey = "sleepWhenDarkLid"
    /// Lux below which the lid is taken as closed. A closed lid reads about 0.03, a dim room about 1.
    public static let darkLux: Double = 0.5
    /// How long it must stay dark, with no input, before Sleep runs.
    public static let darkSeconds: TimeInterval = 10
    public static let graceAfterWake: TimeInterval = 60
    public static let checkInterval: TimeInterval = 1

    private let defaults: UserDefaults
    private let lux: () -> Double?
    private let idleSeconds: () -> TimeInterval
    private let displayKeptOnBy: () -> [String]
    private let now: () -> Date
    private var source: DispatchSourceTimer?
    private var started = false
    private var quietUntil: Date?
    private var darkSince: Date?
    private var firedThisDarkPeriod = false
    private var loggedKeepers = false

    /// Called on the main queue when the Mac should be put to sleep.
    public var onTrigger: (() -> Void)?

    public init(defaults: UserDefaults = .standard,
                lux: @escaping () -> Double? = AmbientLightSensor.shared.lux,
                idleSeconds: @escaping () -> TimeInterval = IdleSleepGuard.systemIdleSeconds,
                displayKeptOnBy: @escaping () -> [String] = DarkLidGuard.videoKeepingDisplayOn,
                now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.lux = lux
        self.idleSeconds = idleSeconds
        self.displayKeptOnBy = displayKeptOnBy
        self.now = now
    }

    deinit { source?.cancel() }

    /// Off by default: on a Mac whose lid sensor works, the normal lid sleep already does this.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.defaultsKey) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Self.defaultsKey)
            reset()
            updateTimer()
        }
    }

    /// False on a Mac without a built-in light sensor.
    public var isAvailable: Bool { lux() != nil }

    /// True while the sensor reads dark and the countdown to Sleep is running.
    public var isWaiting: Bool { darkSince != nil && !firedThisDarkPeriod }

    public func start() {
        started = true
        quietUntil = now().addingTimeInterval(Self.graceAfterWake)
        updateTimer()
    }

    public func systemDidWake() {
        quietUntil = now().addingTimeInterval(Self.graceAfterWake)
        reset()
    }

    public func systemWillSleep() { reset() }

    /// One check. Internal so tests can drive it.
    func check() {
        guard isEnabled, let level = lux() else { reset(); return }
        let current = now()

        guard level < Self.darkLux else { reset(); return }
        if let quietUntil, current < quietUntil { darkSince = nil; return }
        // Someone is using the Mac: a dark room, not a closed lid.
        guard idleSeconds() >= 2 else { reset(); return }

        guard let since = darkSince else {
            darkSince = current
            Log.light.notice("Dark (\(level, privacy: .public) lux) with no input: sleeping in \(Int(Self.darkSeconds), privacy: .public) s unless it changes")
            return
        }
        guard !firedThisDarkPeriod,
              current.timeIntervalSince(since) >= Self.darkSeconds,
              idleSeconds() >= Self.darkSeconds else { return }

        let keepers = displayKeptOnBy()
        guard keepers.isEmpty else {
            if !loggedKeepers {
                loggedKeepers = true
                Log.light.notice("Dark, but the display is kept on by \(keepers.joined(separator: ", "), privacy: .public); leaving it alone")
            }
            return
        }
        firedThisDarkPeriod = true
        // Sleep takes a few seconds to happen, and the reading can flicker as the display turns off
        // (which would start a new dark period); stay quiet meanwhile so it is not asked for twice.
        quietUntil = current.addingTimeInterval(Self.graceAfterWake)
        Log.light.notice("Dark for \(Int(current.timeIntervalSince(since)), privacy: .public) s with no input: the lid looks closed, running Sleep")
        onTrigger?()
    }

    private func reset() {
        darkSince = nil
        firedThisDarkPeriod = false
        loggedKeepers = false
    }

    private func updateTimer() {
        if started && isEnabled {
            guard source == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            source = timer
        } else {
            source?.cancel()
            source = nil
        }
    }

    /// Apps keeping the display on, minus coreaudiod: music playing with the lid shut should not keep
    /// the Mac awake, while a video player (which holds its own assertion) should.
    public static func videoKeepingDisplayOn() -> [String] {
        IdleSleepGuard.appsKeepingDisplayOn().filter { $0 != "coreaudiod" }
    }
}

/// Reads `AmbientBrightness` (16.16 fixed point, in lux) from the built-in display's AppleCLCD2 entry.
public final class AmbientLightSensor {
    public static let shared = AmbientLightSensor()
    private var service: io_service_t = 0

    deinit { if service != 0 { IOObjectRelease(service) } }

    public func lux() -> Double? {
        if service == 0 { service = Self.findBuiltInDisplay() }
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, "AmbientBrightness" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { return nil }
        return Self.lux(fromFixedPoint: value.int64Value)
    }

    static func lux(fromFixedPoint raw: Int64) -> Double { Double(raw) / 65536 }

    private static func findBuiltInDisplay() -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLCD2"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let external = IORegistryEntryCreateCFProperty(entry, "external" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool ?? false
            let hasSensor = IORegistryEntryCreateCFProperty(entry, "AmbientBrightness" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() != nil
            if !external && hasSensor { return entry }
            IOObjectRelease(entry)
        }
        return 0
    }
}
