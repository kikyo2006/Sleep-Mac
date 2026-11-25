import AppKit
import SleepMacCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = CommandStore()
    private let launchAtLogin: LaunchAtLogin
    private var statusItem: NSStatusItem?
    private var sleepItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var commandsController: CommandsWindowController?
    private var isBusy = false

    init(launchAtLogin: LaunchAtLogin = LaunchAtLogin()) {
        self.launchAtLogin = launchAtLogin
        super.init()
    }

    // Hooks for `--ui-smoke-test`.
    var statusMenuForTesting: NSMenu? { statusItem?.menu }
    func setBusyForTesting(_ busy: Bool) { setBusy(busy) }
    func toggleLaunchAtLoginForTesting() -> LaunchAtLogin.Outcome { launchAtLogin.toggle() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
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

        menu.addItem(.separator())

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

    @objc private func sleepAction() {
        guard !isBusy else { return }
        setBusy(true)

        // Snapshot on the main thread; the store is not thread safe.
        let commands = store.allCommands
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let coordinator = SleepCoordinator()
            let report = coordinator.prepare(commands: commands)
            DispatchQueue.main.async {
                self?.finishPreparing(report: report, coordinator: coordinator)
            }
        }
    }

    private func finishPreparing(report: SleepReport, coordinator: SleepCoordinator) {
        if report.needsAttention && !confirmSleepAnyway(report: report) {
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

extension AppDelegate: NSMenuItemValidation {
    /// NSMenu re-enables any item whose target responds to its action, so `isEnabled = false`
    /// alone is ignored. Validation is what really greys out "Sleep" while it is working.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === sleepItem { return !isBusy }
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
