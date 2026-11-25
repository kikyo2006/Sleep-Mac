import Foundation

/// Holds the locked default commands plus the user's custom commands (persisted as JSON).
public final class CommandStore {
    public enum StoreError: LocalizedError, Equatable {
        case invalidInput(String)
        case cannotRemoveDefault
        case notFound

        public var errorDescription: String? {
            switch self {
            case .invalidInput(let message): return message
            case .cannotRemoveDefault: return "Default commands cannot be removed."
            case .notFound: return "That command no longer exists."
            }
        }
    }

    public private(set) var customCommands: [SleepCommand] = []
    private let fileURL: URL

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sleep Mac", isDirectory: true).appendingPathComponent("commands.json")
    }

    public init(fileURL: URL = CommandStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    /// Defaults first (always, in a fixed order), then custom commands in the order they were added.
    public var allCommands: [SleepCommand] {
        DefaultCommands.all + customCommands
    }

    @discardableResult
    public func addCommand(name: String, script: String, requiresAdmin: Bool) throws -> SleepCommand {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw StoreError.invalidInput("Please enter a name.") }
        guard !trimmedScript.isEmpty else { throw StoreError.invalidInput("Please enter a command.") }

        let command = SleepCommand(name: trimmedName, script: trimmedScript, requiresAdmin: requiresAdmin)
        customCommands.append(command)
        do {
            try save()
        } catch {
            customCommands.removeLast()
            throw error
        }
        return command
    }

    public func removeCommand(id: String) throws {
        if DefaultCommands.all.contains(where: { $0.id == id }) { throw StoreError.cannotRemoveDefault }
        guard let index = customCommands.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        let removed = customCommands.remove(at: index)
        do {
            try save()
        } catch {
            customCommands.insert(removed, at: index)
            throw error
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([SleepCommand].self, from: data)
            // Never trust the file to mark a command as default, or to carry a built-in kind.
            customCommands = decoded.map { command in
                var custom = command
                custom.isDefault = false
                custom.kind = .shell
                return custom
            }
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("commands.json.corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            customCommands = []
        }
    }

    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(customCommands)
        try data.write(to: fileURL, options: .atomic)
    }
}
