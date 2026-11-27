import AppKit
import SleepMacCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = CommandStore()
    private let launchAtLogin: LaunchAtLogin
    private let sleepTimer: SleepTimer
    private let lidGuard: LidSleepGuard
    private var lidItem: NSMenuItem?
    private let idleGuard: IdleSleepGuard
    private var idleItem: NSMenuItem?
    private var statusItem: NSStatusItem?
    private var sleepItem: NSMenuItem?
    private var timerItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var commandsController: CommandsWindowController?
    private var timePickerController: TimePickerWindowController?
    private var countdownController: CountdownWindowController?
    private var isBusy = false

    /// Quick choices in the Sleep Timer submenu.
    static let timerPresets: [(title: String, seconds: TimeInterval)] = [
        ("In 15 Minutes", 15 * 60),
        ("In 30 Minutes", 30 * 60),
        ("In 1 Hour", 3600),
        ("In 2 Hours", 2 * 3600)
    ]

    init(launchAtLogin: LaunchAtLogin = LaunchAtLogin(),
         sleepTimer: SleepTimer = SleepTimer(),
         lidGuard: LidSleepGuard = LidSleepGuard(),
         idleGuard: IdleSleepGuard = IdleSleepGuard()) {
        self.launchAtLogin = launchAtLogin
        self.sleepTimer = sleepTimer
        self.lidGuard = lidGuard
        self.idleGuard = idleGuard
        super.init()
    }

    // Hooks for `--ui-smoke-test`.
    var statusMenuForTesting: NSMenu? { statusItem?.menu }
    func setBusyForTesting(_ busy: Bool) { setBusy(busy) }
    func toggleLaunchAtLoginForTesting() -> LaunchAtLogin.Outcome { launchAtLogin.toggle() }
    var timerItemForTesting: NSMenuItem? { timerItem }
    var lidItemForTesting: NSMenuItem? { lidItem }
    func toggleLidForTesting() { toggleSleepWhenLidCloses() }
    var idleItemForTesting: NSMenuItem? { idleItem }
    var countdownForTesting: CountdownWindowController? { countdownController }
    func refreshTimerMenuForTesting() { if let menu = timerItem?.submenu { menuNeedsUpdate(menu) } }
    /// Shows the countdown without running Sleep when it ends.
    func showCountdownForTesting(start: Date) { showCountdown(start: start, present: false) { _ in } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
        installSleepTimer()
        installLidGuard()
        idleGuard.onTrigger = { [weak self] in self?.forceSleepUnattended() }
        idleGuard.start()
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Sleep Mac")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "Zz" }
            button.toolTip = "Sleep Mac"
        }

        let menu = NSMenu()

        let commands = NSMenuItem(title: "Custom Commands…", action: #selector(openCommands), keyEquivalent: "")
        commands.target = self
        menu.addItem(commands)

        let sleep = NSMenuItem(title: "Sleep", action: #selector(sleepAction), keyEquivalent: "")
        sleep.target = self
        menu.addItem(sleep)
        sleepItem = sleep

        // The submenu is rebuilt in menuNeedsUpdate each time it opens.
        let timer = NSMenuItem(title: "Sleep Timer", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu(title: "Sleep Timer")
        timerMenu.delegate = self
        timer.submenu = timerMenu
        menu.addItem(timer)
        timerItem = timer

        menu.addItem(.separator())

        // Only on a Mac with a lid. The checkmark is refreshed in validateMenuItem.
        if lidGuard.isAvailable {
            let lid = NSMenuItem(title: "Sleep When Lid Closes", action: #selector(toggleSleepWhenLidCloses), keyEquivalent: "")
            lid.target = self
            lid.toolTip = "If the Mac is still awake \(Int(LidSleepGuard.defaultDelay)) seconds after you close the lid, something is keeping it awake: run Sleep."
            menu.addItem(lid)
            lidItem = lid
        }

        // Fallback that does not need the lid sensor. Checkmarks are refreshed in validateMenuItem.
        let idle = NSMenuItem(title: "Sleep When Idle", action: nil, keyEquivalent: "")
        let idleMenu = NSMenu(title: "Sleep When Idle")
        for minutes in IdleSleepGuard.choices {
            let choice = NSMenuItem(title: minutes == 0 ? "Off" : "After \(minutes) Minutes",
                                    action: #selector(idleChoiceChosen(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = minutes
            idleMenu.addItem(choice)
        }
        idleMenu.addItem(.separator())
        let idleNote = NSMenuItem(title: "Runs Sleep when nobody has used the Mac for that long but it is still awake",
                                  action: nil, keyEquivalent: "")
        idleNote.isEnabled = false
        idleMenu.addItem(idleNote)
        idle.submenu = idleMenu
        menu.addItem(idle)
        idleItem = idle

        // The checkmark is refreshed in validateMenuItem each time the menu opens.
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Sleep Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// An accessory app has no menu bar of its own, so Cmd+C / Cmd+V would not work in text fields
    /// unless an Edit menu exists in the (hidden) main menu.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Sleep Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func openCommands() {
        if commandsController == nil {
            commandsController = CommandsWindowController(store: store)
        }
        NSApp.activate(ignoringOtherApps: true)
        commandsController?.showWindow(nil)
        commandsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        switch launchAtLogin.toggle() {
        case .enabled, .disabled:
            break   // The checkmark follows the real status the next time the menu opens.
        case .requiresApproval:
            offerLoginItemsSettings()
        case .failed(let message):
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = message
            alert.runModal()
        }
    }

    private func offerLoginItemsSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Sleep Mac in Login Items"
        alert.informativeText = "macOS needs your approval. Turn on Sleep Mac in System Settings → General → Login Items."
        alert.addButton(withTitle: "Open Login Items Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SystemLoginItemService.openSystemSettings()
        }
    }

    // MARK: - Lid

    private func installLidGuard() {
        lidGuard.onTrigger = { [weak self] in self?.forceSleepUnattended() }
        lidGuard.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }

    @objc private func systemWillSleep() { lidGuard.systemWillSleep() }

    @objc private func toggleSleepWhenLidCloses() { lidGuard.isEnabled.toggle() }

    @objc private func idleChoiceChosen(_ sender: NSMenuItem) { idleGuard.minutes = sender.tag }

    /// The lid has been closed, or nobody has used the Mac, for a while and it is still awake.
    /// Nobody is looking at the screen, so there is no countdown and no question.
    private func forceSleepUnattended() {
        // A countdown left on screen would put the Mac back to sleep right after it is woken up.
        countdownController?.dismiss()
        startSleep(unattended: true)
    }

    // MARK: - Sleep timer

    private func installSleepTimer() {
        sleepTimer.onChange = { [weak self] in self?.refreshTimerIndicator() }
        sleepTimer.onFire = { [weak self] in self?.timerFired() }
        // The dispatch timer follows the wall clock, but re-check after a wake or a clock change anyway:
        // a time that passed while the Mac slept is dropped instead of fired.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(reevaluateTimer), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reevaluateTimer), name: .NSSystemClockDidChange, object: nil)
        sleepTimer.reevaluate()   // a timer set before the app was restarted
        refreshTimerIndicator()
    }

    @objc private func reevaluateTimer() { sleepTimer.reevaluate() }

    private func refreshTimerIndicator() {
        guard let button = statusItem?.button else { return }
        let symbol = sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sleep Mac") {
            image.isTemplate = true
            button.image = image
        }
        if let date = sleepTimer.fireDate {
            button.toolTip = "Sleep Mac: sleeps at \(date.formatted(date: .omitted, time: .shortened))"
            timerItem?.title = "Sleep Timer (\(date.formatted(date: .omitted, time: .shortened)))"
        } else {
            button.toolTip = "Sleep Mac"
            timerItem?.title = "Sleep Timer"
        }
    }

    @objc private func timerPresetChosen(_ sender: NSMenuItem) {
        guard Self.timerPresets.indices.contains(sender.tag) else { return }
        sleepTimer.schedule(after: Self.timerPresets[sender.tag].seconds)
    }

    @objc private func cancelTimer() { sleepTimer.cancel() }

    @objc private func chooseTimerTime() {
        if let existing = timePickerController {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let initial = sleepTimer.fireDate ?? Self.roundedUp(Date().addingTimeInterval(3600))
        let controller = TimePickerWindowController(initial: initial) { [weak self] date in
            if let date { self?.sleepTimer.schedule(at: date) }
            self?.timePickerController = nil
        }
        timePickerController = controller
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Rounds up to the next 5 minutes, for a friendlier default in the time picker.
    private static func roundedUp(_ date: Date) -> Date {
        let step: TimeInterval = 300
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    private func timerFired() {
        // Someone is already putting the Mac to sleep, or the countdown is already up.
        guard !isBusy, countdownController == nil else { return }
        showCountdown(start: Date(), present: true) { [weak self] result in
            if result == .sleep { self?.startSleep(unattended: true) }
        }
    }

    private func showCountdown(start: Date, present: Bool, then: @escaping (CountdownWindowController.Result) -> Void) {
        let controller = CountdownWindowController(start: start) { [weak self] result in
            self?.countdownController = nil
            then(result)
        }
        countdownController = controller
        if present { controller.present() }
    }

    // MARK: - Sleep

    @objc private func sleepAction() { startSleep(unattended: false) }

    /// `unattended`: started by the sleep timer. Nobody may be at the Mac, so a warning that something
    /// still keeps it awake is not shown as a question; the countdown was the chance to cancel.
    private func startSleep(unattended: Bool) {
        guard !isBusy else { return }
        Log.sleep.notice("Sleep started (\(unattended ? "unattended" : "from the menu", privacy: .public))")
        setBusy(true)

        // Snapshot on the main thread; the store is not thread safe.
        let commands = store.allCommands
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let coordinator = SleepCoordinator { Log.sleep.notice("\($0, privacy: .public)") }
            let report = coordinator.prepare(commands: commands)
            DispatchQueue.main.async {
                self?.finishPreparing(report: report, coordinator: coordinator, unattended: unattended)
            }
        }
    }

    private func finishPreparing(report: SleepReport, coordinator: SleepCoordinator, unattended: Bool) {
        if report.needsAttention && !unattended && !confirmSleepAnyway(report: report) {
            setBusy(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            coordinator.sleepNow()
            DispatchQueue.main.async { self?.setBusy(false) }
        }
    }

    private func confirmSleepAnyway(report: SleepReport) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Something may keep the Mac awake"
        alert.informativeText = report.attentionSummary
        alert.addButton(withTitle: "Sleep Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        sleepItem?.title = busy ? "Preparing to sleep…" : "Sleep"
        sleepItem?.isEnabled = !busy
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilds the Sleep Timer submenu so it shows the current timer and time left.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === timerItem?.submenu else { return }
        menu.removeAllItems()

        if let date = sleepTimer.fireDate {
            let left = SleepSchedule.describe(remaining: date.timeIntervalSinceNow)
            let status = NSMenuItem(title: "Sleeps at \(date.formatted(date: .omitted, time: .shortened)) (in \(left))",
                                    action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            let cancel = NSMenuItem(title: "Cancel Timer", action: #selector(cancelTimer), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
            menu.addItem(.separator())
        }

        for (index, preset) in Self.timerPresets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(timerPresetChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        let custom = NSMenuItem(title: "At a Specific Time…", action: #selector(chooseTimerTime), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// NSMenu re-enables any item whose target responds to its action, so `isEnabled = false`
    /// alone is ignored. Validation is what really greys out "Sleep" while it is working.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === sleepItem { return !isBusy }
        if menuItem.action == #selector(idleChoiceChosen(_:)) {
            menuItem.state = menuItem.tag == idleGuard.minutes ? .on : .off
        }
        if menuItem === lidItem {
            menuItem.state = lidGuard.isEnabled ? .on : .off
        }
        if menuItem === loginItem {
            switch launchAtLogin.status {
            case .enabled: menuItem.state = .on
            case .requiresApproval: menuItem.state = .mixed   // registered but not yet allowed by the user
            case .disabled, .unavailable: menuItem.state = .off
            }
        }
        return true
    }
}
