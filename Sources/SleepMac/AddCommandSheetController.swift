import AppKit

/// Sheet with Name, Command and "Run as administrator" fields for a new custom command.
final class AddCommandSheetController: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate {
    struct Input {
        let name: String
        let script: String
        let requiresAdmin: Bool
    }

    // Internal (not private) so the UI smoke test can drive them.
    let nameField = NSTextField()
    private let scriptScroll: NSScrollView
    let scriptView: NSTextView
    let adminCheck = NSButton(checkboxWithTitle: "Run as administrator (asks for your password)", target: nil, action: nil)
    let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// Set when the user pressed Add.
    private(set) var input: Input?

    init() {
        let scroll = NSTextView.scrollableTextView()
        scriptScroll = scroll
        scriptView = scroll.documentView as! NSTextView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Command"
        super.init(window: window)
        buildContent(in: window)
        updateAddButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        guard let content = window.contentView else { return }

        let nameLabel = NSTextField(labelWithString: "Name")
        nameField.placeholderString = "For example: Quit Docker"
        nameField.delegate = self

        let commandLabel = NSTextField(labelWithString: "Command")
        scriptView.isRichText = false
        scriptView.isAutomaticQuoteSubstitutionEnabled = false
        scriptView.isAutomaticDashSubstitutionEnabled = false
        scriptView.isAutomaticTextReplacementEnabled = false
        scriptView.isAutomaticSpellingCorrectionEnabled = false
        scriptView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scriptView.textContainerInset = NSSize(width: 4, height: 6)
        scriptView.delegate = self
        scriptScroll.borderType = .bezelBorder
        scriptScroll.hasVerticalScroller = true

        let note = NSTextField(wrappingLabelWithString: "Runs with /bin/zsh -c, before the Mac goes to sleep.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        addButton.target = self
        addButton.action = #selector(addPressed)
        addButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"

        for view in [nameLabel, nameField, commandLabel, scriptScroll, adminCheck, note, cancelButton, addButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            nameField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            commandLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 14),
            commandLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            scriptScroll.topAnchor.constraint(equalTo: commandLabel.bottomAnchor, constant: 6),
            scriptScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scriptScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scriptScroll.heightAnchor.constraint(equalToConstant: 110),

            note.topAnchor.constraint(equalTo: scriptScroll.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            adminCheck.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            adminCheck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            addButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
        ])

        window.initialFirstResponder = nameField
    }

    // MARK: - Validation

    private var trimmedName: String { nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedScript: String { scriptView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func updateAddButton() {
        addButton.isEnabled = !trimmedName.isEmpty && !trimmedScript.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { updateAddButton() }
    func textDidChange(_ notification: Notification) { updateAddButton() }

    // MARK: - Actions

    @objc func addPressed() {
        guard addButton.isEnabled else { return }
        input = Input(name: trimmedName, script: trimmedScript, requiresAdmin: adminCheck.state == .on)
        finish(.OK)
    }

    @objc private func cancelPressed() {
        finish(.cancel)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: response)
        window.orderOut(nil)
    }
}
