import AppKit
import SleepMacCore

/// Floating "Mac will sleep in 30 seconds" panel shown when the sleep timer fires.
/// Cancel keeps the Mac awake; Sleep Now or the end of the countdown runs Sleep.
final class CountdownWindowController: NSWindowController {
    enum Result { case sleep, cancelled }

    // Internal (not private) so the UI smoke test can drive them.
    let titleLabel = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let sleepButton = NSButton(title: "Sleep Now", target: nil, action: nil)

    private var countdown: SleepCountdown
    private var ticker: Timer?
    private var completion: ((Result) -> Void)?

    init(start: Date = Date(), completion: @escaping (Result) -> Void) {
        countdown = SleepCountdown(start: start)
        self.completion = completion
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sleep Timer"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildContent(in: panel)
        update(at: start)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent(in window: NSWindow) {
        guard let content = window.contentView else { return }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "The sleep timer is up. Choose Cancel to keep the Mac awake.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\r"   // the safe choice is the default one
        sleepButton.target = self
        sleepButton.action = #selector(sleepPressed)
        cancelButton.bezelColor = .controlAccentColor

        for view in [icon, titleLabel, note, progress, cancelButton, sleepButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 40),

            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            note.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            progress.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            sleepButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
            sleepButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor)
        ])
    }

    /// Shows the panel on top of everything and starts ticking.
    func present() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSSound(named: "Glass")?.play()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.update(at: Date()) }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while a menu is open
        ticker = timer
    }

    /// Refreshes the text and the bar; finishes when the time is up. Internal for the smoke test.
    func update(at now: Date) {
        let left = countdown.secondsLeft(at: now)
        titleLabel.stringValue = "Mac will sleep in \(left) second\(left == 1 ? "" : "s")"
        progress.doubleValue = countdown.progress(at: now)
        if countdown.isFinished(at: now) { finish(.sleep) }
    }

    @objc func cancelPressed() { finish(.cancelled) }
    /// Closes the panel without sleeping, as if cancelled.
    func dismiss() { finish(.cancelled) }
    @objc func sleepPressed() { finish(.sleep) }

    private func finish(_ result: Result) {
        guard let completion else { return }   // only once
        self.completion = nil
        ticker?.invalidate()
        ticker = nil
        window?.orderOut(nil)
        completion(result)
    }
}
