import AppKit
import SleepMacCore

/// In-memory stand-in for the system login item service.
private final class FakeLoginItemService: LoginItemService {
    var current: LoginItemStatus = .disabled
    var status: LoginItemStatus { current }
    func register() throws { current = .enabled }
    func unregister() throws { current = .disabled }
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
        let delegate = AppDelegate(launchAtLogin: LaunchAtLogin(service: fakeLogin))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let menu = delegate.statusMenuForTesting
        check(menu?.items.map { $0.title } == ["Custom Commands…", "Sleep", "", "Launch at Login", "", "Quit Sleep Mac"],
              "menu has Custom Commands, Sleep, Launch at Login and Quit (got \(menu?.items.map { $0.title } ?? []))")
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
