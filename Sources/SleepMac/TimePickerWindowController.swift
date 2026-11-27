import AppKit
import SleepMacCore

/// "Sleep at a Specific Time" window: pick hour and minute; the next time the clock shows it, the timer fires.
final class TimePickerWindowController: NSWindowController {
    // Internal (not private) so the UI smoke test can drive them.
    let datePicker = NSDatePicker()
    let summaryLabel = NSTextField(labelWithString: "")
    let setButton = NSButton(title: "Set Timer", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private let now: () -> Date
    private var completion: ((Date?) -> Void)?

    /// `completion` gets the chosen fire date, or nil when cancelled.
    init(initial: Date, now: @escaping () -> Date = Date.init, completion: @escaping (Date?) -> Void) {
        self.now = now
        self.completion = completion
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Sleep at a Specific Time"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(in: window)
        datePicker.dateValue = initial
        updateSummary()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent(in window: NSWindow) {
        guard let content = window.contentView else { return }

        let label = NSTextField(labelWithString: "Sleep at")
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .hourMinute
        datePicker.target = self
        datePicker.action = #selector(pickerChanged)
        summaryLabel.textColor = .secondaryLabelColor

        setButton.target = self
        setButton.action = #selector(setPressed)
        setButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"

        for view in [label, datePicker, summaryLabel, cancelButton, setButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: datePicker.centerYAnchor),
            datePicker.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            datePicker.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),

            summaryLabel.topAnchor.constraint(equalTo: datePicker.bottomAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            setButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            setButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            cancelButton.trailingAnchor.constraint(equalTo: setButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: setButton.centerYAnchor)
        ])
        window.initialFirstResponder = datePicker
    }

    /// The fire date the current picker value stands for: later today, otherwise tomorrow.
    var chosenDate: Date {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: datePicker.dateValue)
        return SleepSchedule.nextOccurrence(hour: parts.hour ?? 0, minute: parts.minute ?? 0, after: now())
    }

    @objc private func pickerChanged() { updateSummary() }

    /// Internal for the smoke test.
    func updateSummary() {
        let date = chosenDate
        let day = Calendar.current.isDate(date, inSameDayAs: now()) ? "Today" : "Tomorrow"
        let time = date.formatted(date: .omitted, time: .shortened)
        summaryLabel.stringValue = "\(day) at \(time), in \(SleepSchedule.describe(remaining: date.timeIntervalSince(now())))"
    }

    @objc func setPressed() { finish(chosenDate) }
    @objc private func cancelPressed() { finish(nil) }

    private func finish(_ date: Date?) {
        guard let completion else { return }
        self.completion = nil
        window?.orderOut(nil)
        completion(date)
    }
}
