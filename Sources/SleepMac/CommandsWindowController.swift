import AppKit
import SleepMacCore

/// The "Custom Commands" window: a table of default (locked) and custom commands with + and − buttons.
final class CommandsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: CommandStore
    // Internal (not private) so the UI smoke test can drive them.
    let tableView = NSTableView()
    let addButton = NSButton()
    let removeButton = NSButton()
    private var rows: [SleepCommand] = []
    private var sheetController: AddCommandSheetController?

    init(store: CommandStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Custom Commands"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 340)
        window.center()
        super.init(window: window)
        buildContent(in: window)
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        guard let content = window.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            "These commands run in order each time you choose Sleep. Default commands always run first and cannot be removed.")
        intro.textColor = .secondaryLabelColor
        intro.translatesAutoresizingMaskIntoConstraints = false

        let columns: [(id: String, title: String, width: CGFloat, minWidth: CGFloat, flexible: Bool)] = [
            ("name", "Name", 270, 140, false),
            ("command", "Command", 380, 160, true),
            ("type", "Type", 120, 90, false)
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.resizingMask = spec.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configure(addButton, symbol: "plus", tooltip: "Add a custom command", action: #selector(addCommand))
        configure(removeButton, symbol: "minus", tooltip: "Remove the selected custom command", action: #selector(removeCommand))

        let hint = NSTextField(labelWithString: "Select a custom command, then press − to remove it.")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.translatesAutoresizingMaskIntoConstraints = false

        [intro, scroll, addButton, removeButton, hint].forEach { content.addSubview($0) }

        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),

            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            addButton.widthAnchor.constraint(equalToConstant: 30),
            addButton.heightAnchor.constraint(equalToConstant: 24),

            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: -1),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 30),
            removeButton.heightAnchor.constraint(equalToConstant: 24),

            hint.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .smallSquare
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Data

    private func reload(selecting id: String? = nil) {
        rows = store.allCommands
        tableView.reloadData()
        if let id, let index = rows.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        updateButtons()
    }

    private func updateButtons() {
        let row = tableView.selectedRow
        let removable = row >= 0 && row < rows.count && !rows[row].isDefault
        removeButton.isEnabled = removable
    }

    // MARK: - Actions

    @objc private func addCommand() {
        guard let window else { return }
        let controller = AddCommandSheetController()
        sheetController = controller
        guard let sheetWindow = controller.window else { return }
        window.beginSheet(sheetWindow) { [weak self] response in
            guard let self else { return }
            defer { self.sheetController = nil }
            guard response == .OK, let input = controller.input else { return }
            do {
                let added = try self.store.addCommand(name: input.name, script: input.script, requiresAdmin: input.requiresAdmin)
                self.reload(selecting: added.id)
            } catch {
                self.show(error)
            }
        }
    }

    @objc private func removeCommand() {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, !rows[row].isDefault, let window else { return }
        let command = rows[row]

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(command.name)”?"
        alert.informativeText = "This custom command will no longer run when you choose Sleep."
        let confirm = alert.addButton(withTitle: "Remove")
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.store.removeCommand(id: command.id)
                self.reload()
            } catch {
                self.show(error)
            }
        }
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not save the command"
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell-\(column.identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let command = rows[row]
        let text: String
        switch column.identifier.rawValue {
        case "name":
            text = command.name
        case "command":
            text = command.script.replacingOccurrences(of: "\n", with: "  ⏎  ")
        default:
            text = command.isDefault ? "Default · locked" : (command.requiresAdmin ? "Custom · admin" : "Custom")
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = command.isDefault ? .secondaryLabelColor : .labelColor
        cell.textField?.toolTip = command.script
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
