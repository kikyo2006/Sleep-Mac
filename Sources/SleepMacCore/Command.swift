import Foundation

/// One step that runs, in order, before the Mac goes to sleep.
public struct SleepCommand: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable {
        /// A shell command run with `/bin/zsh -c`.
        case shell
        /// Built-in: stop command-line tools that hold a sleep assertion.
        case terminateSleepBlockers
        /// Built-in: turn `pmset disablesleep` back off when it is on.
        case restoreSystemSleep
    }

    public var id: String
    public var name: String
    /// Shell script for `.shell`; a human-readable description for built-in kinds.
    public var script: String
    public var requiresAdmin: Bool
    public var kind: Kind
    /// Default commands always run first and can never be removed.
    public var isDefault: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        script: String,
        requiresAdmin: Bool = false,
        kind: Kind = .shell,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.script = script
        self.requiresAdmin = requiresAdmin
        self.kind = kind
        self.isDefault = isDefault
    }
}

public enum DefaultCommands {
    /// Order matters: simulators first (their audio device holds a sleep assertion),
    /// then any command-line blockers, then the disablesleep flag.
    public static let all: [SleepCommand] = [
        SleepCommand(
            id: "default.quit-simulator-app",
            name: "Quit Simulator app",
            // pkill instead of AppleScript: no Automation permission prompt in the middle of "Sleep".
            script: "pkill -x Simulator || true",
            isDefault: true
        ),
        SleepCommand(
            id: "default.shutdown-simulators",
            name: "Shut down all simulators",
            script: "if command -v xcrun >/dev/null 2>&1; then xcrun simctl shutdown all; fi",
            isDefault: true
        ),
        SleepCommand(
            id: "default.terminate-blockers",
            name: "Stop CLI tools keeping the Mac awake",
            script: "Built-in: ends caffeinate and any other command-line tool that holds a sleep assertion",
            kind: .terminateSleepBlockers,
            isDefault: true
        ),
        SleepCommand(
            id: "default.restore-sleep",
            name: "Re-enable system sleep",
            script: "Built-in: pmset -a disablesleep 0, only when it is on (asks for the admin password)",
            kind: .restoreSystemSleep,
            isDefault: true
        )
    ]
}
