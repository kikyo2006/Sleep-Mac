import Foundation
import IOKit
import IOKit.pwr_mgt

/// Lid (clamshell) state as reported by the power management root domain.
public struct LidState: Equatable {
    public var isClosed: Bool
    /// False when closing the lid does not sleep the Mac, for example with an external display and power
    /// ("clamshell mode"). Then a closed lid is the user's choice and nothing should be forced.
    public var closeCausesSleep: Bool

    public init(isClosed: Bool, closeCausesSleep: Bool) {
        self.isClosed = isClosed
        self.closeCausesSleep = closeCausesSleep
    }
}

/// Seam over IOKit so the lid logic can be tested without a real lid.
public protocol LidStateSource: AnyObject {
    /// nil on a Mac without a lid.
    var state: LidState? { get }
    /// Called on the main queue whenever the lid opens or closes.
    var onChange: ((LidState) -> Void)? { get set }
    func start()
}

/// Reads `AppleClamshellState` / `AppleClamshellCausesSleep` from IOPMrootDomain and listens for
/// `kIOPMMessageClamshellStateChange`. The registry is also polled every few seconds as a safety net,
/// so a missed notification costs at most one poll interval.
public final class IOKitLidStateSource: LidStateSource {
    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)`; the C macro is not visible from Swift.
    static let clamshellStateChangeMessage: UInt32 = 0xE003_4100

    public var onChange: ((LidState) -> Void)?
    private let rootDomain: io_service_t
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var poller: DispatchSourceTimer?
    private var lastDelivered: LidState?
    static let pollInterval: TimeInterval = 5

    public init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }

    deinit {
        poller?.cancel()
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port { IONotificationPortDestroy(port) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
    }

    public var state: LidState? {
        guard rootDomain != 0, let closed = boolProperty("AppleClamshellState") else { return nil }
        return LidState(isClosed: closed, closeCausesSleep: boolProperty("AppleClamshellCausesSleep") ?? true)
    }

    private func boolProperty(_ key: String) -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    public func start() {
        guard rootDomain != 0, port == nil, let newPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = newPort
        IONotificationPortSetDispatchQueue(newPort, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(newPort, rootDomain, kIOGeneralInterest, { context, _, messageType, _ in
            guard let context, messageType == IOKitLidStateSource.clamshellStateChangeMessage else { return }
            let source = Unmanaged<IOKitLidStateSource>.fromOpaque(context).takeUnretainedValue()
            Log.lid.notice("Clamshell notification received")
            source.deliverIfChanged()
        }, context, &notifier)
        lastDelivered = state
        Log.lid.notice("Watching the lid (notification result \(result, privacy: .public)); now \(String(describing: self.lastDelivered), privacy: .public)")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.deliverIfChanged() }
        timer.resume()
        poller = timer
    }

    private func deliverIfChanged() {
        guard let current = state, current != lastDelivered else { return }
        lastDelivered = current
        Log.lid.notice("Lid \(current.isClosed ? "closed" : "open", privacy: .public), close causes sleep: \(current.closeCausesSleep, privacy: .public)")
        onChange?(current)
    }
}

/// "Sleep When Lid Closes": if the lid has been closed for `delay` seconds of awake time and the Mac is
/// still running, something is keeping it awake, so `onTrigger` runs the Sleep flow.
public final class LidSleepGuard {
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> DispatchWorkItem

    public static let defaultDelay: TimeInterval = 20
    public static let defaultsKey = "sleepWhenLidCloses"

    private let source: LidStateSource
    private let defaults: UserDefaults
    private let delay: TimeInterval
    private let scheduler: Scheduler
    private var pending: DispatchWorkItem?

    /// Called on the main queue when the Mac should be put to sleep.
    public var onTrigger: (() -> Void)?

    /// The default scheduler uses `DispatchTime` (uptime), which stops while the Mac sleeps,
    /// so only time the Mac really spends awake with the lid closed counts.
    public init(source: LidStateSource = IOKitLidStateSource(),
                defaults: UserDefaults = .standard,
                delay: TimeInterval = LidSleepGuard.defaultDelay,
                scheduler: @escaping Scheduler = { seconds, work in
                    let item = DispatchWorkItem(block: work)
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
                    return item
                }) {
        self.source = source
        self.defaults = defaults
        self.delay = delay
        self.scheduler = scheduler
    }

    /// On by default.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.defaultsKey)
            if !newValue { cancelPending() }
        }
    }

    /// False on a Mac without a lid.
    public var isAvailable: Bool { source.state != nil }
    public var isWaiting: Bool { pending != nil }

    public func start() {
        source.onChange = { [weak self] state in self?.lidChanged(state) }
        source.start()
    }

    /// The Mac is going to sleep on its own: nothing to force.
    public func systemWillSleep() {
        if isWaiting { Log.lid.notice("The Mac is going to sleep on its own") }
        cancelPending()
    }

    func lidChanged(_ state: LidState) {
        cancelPending()
        guard isEnabled, state.isClosed, state.closeCausesSleep else { return }
        Log.lid.notice("Lid closed: checking again in \(self.delay, privacy: .public) s")
        pending = scheduler(delay) { [weak self] in self?.check() }
    }

    private func check() {
        pending = nil
        guard isEnabled, let state = source.state, state.isClosed, state.closeCausesSleep else {
            Log.lid.notice("Lid check: nothing to do (\(String(describing: self.source.state), privacy: .public))")
            return
        }
        Log.lid.notice("Lid closed and the Mac is still awake: running Sleep")
        onTrigger?()
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}
