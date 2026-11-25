import AppKit
import SleepMacCore

// Developer aid: `SleepMac --dry-run` prints what Sleep would do and changes nothing.
if CommandLine.arguments.contains("--dry-run") {
    let store = CommandStore()
    let coordinator = SleepCoordinator(dryRun: true) { print($0) }
    let report = coordinator.prepare(commands: store.allCommands)
    coordinator.sleepNow()
    print(report.needsAttention ? "\nNeeds attention:\n\(report.attentionSummary)" : "\nNothing is left that would keep the Mac awake.")
    exit(0)
}

// Developer aid: `SleepMac --ui-smoke-test <dir>` checks the windows and writes PNG snapshots.
if let flag = CommandLine.arguments.firstIndex(of: "--ui-smoke-test") {
    let directory = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : "ui-snapshots"
    exit(UISmokeTest.run(outputDirectory: directory))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu bar only: no Dock icon and no app switcher entry.
application.setActivationPolicy(.accessory)
application.run()
