import AppKit
import SleepMacCore

/// In-memory stand-in for the system login item service.
private final class FakeLoginItemService: LoginItemService {
    var current: LoginItemStatus = .disabled
    var status: LoginItemStatus { current }
    func register() throws { current = .enabled }
    func unregister() throws { current = .disabled }
}

/// Fake lid for the smoke test.
private final class SmokeLidSource: LidStateSource {
    var state: LidState? = LidState(isClosed: false, closeCausesSleep: true)
    var onChange: ((LidState) -> Void)?
    func start() {}
    func set(closed: Bool) {
        let newState = LidState(isClosed: closed, closeCausesSleep: true)
        state = newState
        onChange?(newState)
    }
}

/// Developer aid: `SleepMac --ui-smoke-test <dir>` builds the windows against a throw-away store,
/// checks their behaviour and writes PNG snapshots to `<dir>`. It never touches the real command list.
enum UISmokeTest {
    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ok   \(message)" : "  FAIL \(message)")
        if !condition { failures.append(message) }
    }

    private static func spin(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func snapshot(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("  wrote \(path)")
    }

    static func run(outputDirectory: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        let storeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepMacUI-\(UUID().uuidString)/commands.json")
        let store = CommandStore(fileURL: storeFile)

        // Commands window ------------------------------------------------------------------
        print("Commands window")
        let controller = CommandsWindowController(store: store)
        guard let window = controller.window else { return 2 }
        window.alphaValue = 0   // render without flashing a window on screen
        window.orderFrontRegardless()
        spin()

        let defaults = DefaultCommands.all.count
        check(controller.tableView.numberOfRows == defaults, "table shows \(defaults) default rows")
        check(!controller.removeButton.isEnabled, "minus is disabled with no selection")

        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        spin(0.1)
        check(!controller.removeButton.isEnabled, "minus is disabled for a default row")
        snapshot(window.contentView!, to: "\(outputDirectory)/commands-defaults.png")

        _ = try? store.addCommand(name: "Stop Docker", script: "osascript -e 'quit app \"Docker\"'", requiresAdmin: false)
        _ = try? store.addCommand(name: "Flush DNS", script: "dscacheutil -flushcache\nkillall -HUP mDNSResponder", requiresAdmin: true)
        // Recreate the controller so it reads the updated store, as the real "+" flow does via reload().
        let second = CommandsWindowController(store: store)
        guard let secondWindow = second.window else { return 2 }
        secondWindow.alphaValue = 0
        secondWindow.orderFrontRegardless()
        spin()
        check(second.tableView.numberOfRows == defaults + 2, "table shows defaults plus 2 custom rows")
        second.tableView.selectRowIndexes(IndexSet(integer: defaults), byExtendingSelection: false)
        spin(0.1)
        check(second.removeButton.isEnabled, "minus is enabled for a custom row")
        snapshot(secondWindow.contentView!, to: "\(outputDirectory)/commands-with-custom.png")
        window.orderOut(nil)
        secondWindow.orderOut(nil)

        // Menu ------------------------------------------------------------------------------
        print("Status menu")
        // A fake service, so the test never touches the real Login Items.
        let fakeLogin = FakeLoginItemService()
        // A throw-away defaults suite, so the test never sets or clears the user's real sleep timer.
        let timerSuite = "SleepMacUI-\(UUID().uuidString)"
        let timerDefaults = UserDefaults(suiteName: timerSuite)!
        defer { timerDefaults.removePersistentDomain(forName: timerSuite) }
        let sleepTimer = SleepTimer(defaults: timerDefaults)
        // A fake lid with its own defaults, so the test never changes the user's real setting.
        let lidSource = SmokeLidSource()
        let lidGuard = LidSleepGuard(source: lidSource, defaults: timerDefaults)
        let idleGuard = IdleSleepGuard(defaults: timerDefaults, idleSeconds: { 0 }, displayKeptOnBy: { [] })
        let delegate = AppDelegate(launchAtLogin: LaunchAtLogin(service: fakeLogin), sleepTimer: sleepTimer,
                                   lidGuard: lidGuard, idleGuard: idleGuard)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let menu = delegate.statusMenuForTesting
        check(menu?.items.map { $0.title } == ["Custom Commands…", "Sleep", "Sleep Timer", "", "Sleep When Lid Closes", "Sleep When Idle", "Launch at Login", "", "Quit Sleep Mac"],
              "menu has Custom Commands, Sleep, Sleep Timer, Sleep When Lid Closes, Sleep When Idle, Launch at Login and Quit (got \(menu?.items.map { $0.title } ?? []))")
        if let loginItem = menu?.items.first(where: { $0.title == "Launch at Login" }) {
            _ = delegate.validateMenuItem(loginItem)
            check(loginItem.state == .off, "Launch at Login starts unchecked")
            check(delegate.toggleLaunchAtLoginForTesting() == .enabled, "first click enables it")
            _ = delegate.validateMenuItem(loginItem)
            check(loginItem.state == .on, "Launch at Login is checked after the first click")
            check(delegate.toggleLaunchAtLoginForTesting() == .disabled, "second click disables it")
            _ = delegate.validateMenuItem(loginItem)
            check(loginItem.state == .off, "Launch at Login is unchecked after the second click")
            fakeLogin.current = .requiresApproval
            _ = delegate.validateMenuItem(loginItem)
            check(loginItem.state == .mixed, "Launch at Login shows a dash while it awaits approval")
        }
        if let sleepItem = menu?.items.first(where: { $0.title == "Sleep" }) {
            check(delegate.validateMenuItem(sleepItem), "Sleep is enabled when idle")
            delegate.setBusyForTesting(true)
            check(!delegate.validateMenuItem(sleepItem), "Sleep is disabled while preparing")
            check(sleepItem.title == "Preparing to sleep…", "Sleep shows progress while preparing")
            delegate.setBusyForTesting(false)
            check(delegate.validateMenuItem(sleepItem) && sleepItem.title == "Sleep", "Sleep returns to normal afterwards")
        }

        if let lidItem = delegate.lidItemForTesting {
            _ = delegate.validateMenuItem(lidItem)
            check(lidItem.state == .on, "Sleep When Lid Closes is on by default")
            delegate.toggleLidForTesting()
            _ = delegate.validateMenuItem(lidItem)
            check(lidItem.state == .off && !lidGuard.isEnabled, "one click turns Sleep When Lid Closes off")
            lidSource.set(closed: true)
            check(!lidGuard.isWaiting, "a closed lid is ignored while it is off")
            lidSource.set(closed: false)
            delegate.toggleLidForTesting()
            _ = delegate.validateMenuItem(lidItem)
            check(lidItem.state == .on, "the next click turns it back on")
            lidSource.set(closed: true)
            check(lidGuard.isWaiting, "closing the lid starts the wait")
            lidSource.set(closed: false)
            check(!lidGuard.isWaiting, "opening the lid cancels it")
        } else {
            check(false, "Sleep When Lid Closes is in the menu")
        }

        if let idleMenu = delegate.idleItemForTesting?.submenu {
            let choices = idleMenu.items.filter { $0.action != nil }
            check(choices.map { $0.title } == ["Off", "After 15 Minutes", "After 30 Minutes", "After 60 Minutes"],
                  "idle submenu offers Off, 15, 30 and 60 minutes (got \(choices.map { $0.title }))")
            choices.forEach { _ = delegate.validateMenuItem($0) }
            check(choices.filter { $0.state == .on }.map { $0.tag } == [30], "30 minutes is checked by default")
            if let index = idleMenu.items.firstIndex(where: { $0.title == "After 60 Minutes" }) {
                idleMenu.performActionForItem(at: index)
            }
            choices.forEach { _ = delegate.validateMenuItem($0) }
            check(idleGuard.minutes == 60 && choices.filter { $0.state == .on }.map { $0.tag } == [60], "choosing 60 minutes moves the checkmark")
            if let index = idleMenu.items.firstIndex(where: { $0.title == "Off" }) { idleMenu.performActionForItem(at: index) }
            check(!idleGuard.isEnabled, "Off turns it off")
        } else {
            check(false, "Sleep When Idle is in the menu")
        }

        // Sleep timer -----------------------------------------------------------------------
        print("Sleep timer")
        if let timerItem = delegate.timerItemForTesting, let timerMenu = timerItem.submenu {
            delegate.refreshTimerMenuForTesting()
            check(timerMenu.items.map { $0.title } == ["In 15 Minutes", "In 30 Minutes", "In 1 Hour", "In 2 Hours", "At a Specific Time…"],
                  "timer submenu offers presets and a specific time (got \(timerMenu.items.map { $0.title }))")
            timerMenu.performActionForItem(at: 2)   // In 1 Hour
            spin(0.1)
            check(sleepTimer.isActive, "choosing In 1 Hour sets the timer")
            if let fire = sleepTimer.fireDate {
                check(abs(fire.timeIntervalSinceNow - 3600) < 5, "timer fires in about an hour")
            }
            check(timerItem.title.hasPrefix("Sleep Timer ("), "menu item shows the sleep time (got \(timerItem.title))")
            delegate.refreshTimerMenuForTesting()
            check(timerMenu.items.first?.title.hasPrefix("Sleeps at") == true && timerMenu.items.first?.isEnabled == false,
                  "submenu starts with the pending time (got \(timerMenu.items.first?.title ?? "-"))")
            if let cancelIndex = timerMenu.items.firstIndex(where: { $0.title == "Cancel Timer" }) {
                timerMenu.performActionForItem(at: cancelIndex)
                spin(0.1)
            }
            check(!sleepTimer.isActive && timerItem.title == "Sleep Timer", "Cancel Timer clears it")
        }

        print("Countdown")
        let start = Date()
        delegate.showCountdownForTesting(start: start)
        if let countdown = delegate.countdownForTesting, let countdownWindow = countdown.window {
            check(countdown.titleLabel.stringValue == "Mac will sleep in 30 seconds", "countdown starts at 30 seconds")
            countdown.update(at: start.addingTimeInterval(10.2))
            check(countdown.titleLabel.stringValue == "Mac will sleep in 20 seconds", "countdown counts down (got \(countdown.titleLabel.stringValue))")
            check(countdown.cancelButton.keyEquivalent == "\r", "Cancel is the default button")
            countdownWindow.alphaValue = 0
            countdownWindow.orderFrontRegardless()
            spin()
            snapshot(countdownWindow.contentView!, to: "\(outputDirectory)/countdown.png")
            countdown.cancelPressed()
            check(delegate.countdownForTesting == nil && !countdownWindow.isVisible, "Cancel closes the countdown")
        } else {
            check(false, "countdown window is created")
        }
        delegate.showCountdownForTesting(start: start)
        delegate.countdownForTesting?.update(at: start.addingTimeInterval(31))
        check(delegate.countdownForTesting == nil, "countdown finishes on its own after 30 seconds")

        print("Time picker")
        var calendarDay = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        calendarDay.hour = 21
        let fakeNow = Calendar.current.date(from: calendarDay)!
        var picked: Date?
        let picker = TimePickerWindowController(initial: fakeNow.addingTimeInterval(9000), now: { fakeNow }) { picked = $0 }
        if let pickerWindow = picker.window {
            check(picker.summaryLabel.stringValue.hasPrefix("Today at") && picker.summaryLabel.stringValue.hasSuffix("in 2 h 30 min"),
                  "21:00 → 23:30 is today, in 2 h 30 min (got \(picker.summaryLabel.stringValue))")
            pickerWindow.alphaValue = 0
            pickerWindow.orderFrontRegardless()
            spin()
            snapshot(pickerWindow.contentView!, to: "\(outputDirectory)/time-picker.png")
            picker.datePicker.dateValue = fakeNow.addingTimeInterval(-3600)   // 20:00
            picker.updateSummary()
            check(picker.summaryLabel.stringValue.hasPrefix("Tomorrow at"), "an earlier time means tomorrow (got \(picker.summaryLabel.stringValue))")
            picker.setPressed()
            check(picked == fakeNow.addingTimeInterval(23 * 3600), "Set Timer returns tomorrow 20:00")
            pickerWindow.orderOut(nil)
        }

        // Add sheet ------------------------------------------------------------------------
        print("Add sheet")
        let sheet = AddCommandSheetController()
        guard let sheetWindow = sheet.window else { return 2 }
        sheetWindow.alphaValue = 0
        sheetWindow.orderFrontRegardless()
        spin()
        check(!sheet.addButton.isEnabled, "Add is disabled when the form is empty")
        sheet.nameField.stringValue = "Stop Docker"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(!sheet.addButton.isEnabled, "Add is disabled with a name but no command")
        sheet.scriptView.string = "osascript -e 'quit app \"Docker\"'"
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        check(sheet.addButton.isEnabled, "Add is enabled once name and command are filled")
        sheet.adminCheck.state = .on
        snapshot(sheetWindow.contentView!, to: "\(outputDirectory)/add-sheet.png")
        sheet.addPressed()
        check(sheet.input?.name == "Stop Docker" && sheet.input?.requiresAdmin == true, "Add returns the entered values")
        check(sheet.scriptView.isAutomaticQuoteSubstitutionEnabled == false, "smart quotes are off in the command field")
        sheetWindow.orderOut(nil)

        try? FileManager.default.removeItem(at: storeFile.deletingLastPathComponent())
        print(failures.isEmpty ? "\nUI smoke test passed." : "\nUI smoke test FAILED: \(failures.count) check(s).")
        return failures.isEmpty ? 0 : 1
    }
}
