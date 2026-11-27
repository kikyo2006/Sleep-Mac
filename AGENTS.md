# Sleep Mac — Agent Guide

Read this file first in every new session, before touching code.

## Critical rules

- Address the user as **"anh"** and refer to yourself as **"em"** (chat only; never in code or docs).
- **Language policy:** never write Vietnamese in code, comments, UI strings, tests or scripts. Everything in the repo is English.
- **Context awareness:** before starting a new coding task, use the Obsidian tool to check related notes (`01_Projects/Sleep-Mac/`, plus the daily note) so earlier technical decisions are not repeated or contradicted.
- **Save to memory:** when the user asks to "save to memory", use the Obsidian tool to save the relevant context and code snippets (see the Obsidian rules below).
- **Git:** work on a feature branch, never commit or push unless the user asks. When asked for a commit message, follow the style in the global `~/.config/zed/AGENTS.md` (short imperative subject, ≤ 50 chars, no trailing period, body only when it adds information, wrapped at 72).
- **Never put the Mac to sleep from a session.** Do not run the real Sleep flow while testing: it kills simulators, may ask for an admin password and puts the machine to sleep mid-session. Use `--dry-run` and the tests instead.
- **No secrets, no personal data** in code, logs, notes or commit messages.

## What this is

A macOS menu bar app (`Sleep Mac`) with seven menu items:

1. **Custom Commands…** opens a window listing the commands that run before sleep. Default commands are locked and cannot be removed. Custom commands are added with **+** (sheet: name, command, "run as administrator") and removed with **−** (confirmation dialog first).
2. **Sleep** runs every command in order, makes sure nothing is still keeping the Mac awake, then runs `pmset sleepnow`.
3. **Sleep Timer ▸** — presets (15 min, 30 min, 1 h, 2 h) or **At a Specific Time…** (hour:minute, next occurrence: today if still ahead, otherwise tomorrow). Choosing a new time replaces the old one; while a timer is set the submenu starts with "Sleeps at HH:MM (in …)" and **Cancel Timer**, the item title shows the time and the menu bar icon becomes `moon.zzz.fill`. When the time comes a floating panel counts down 30 s (**Cancel** is the default button, **Sleep Now** skips the wait); if nobody cancels, the same flow as **Sleep** runs.
4. **Sleep When Lid Closes ▸** — **Off / Lid Sensor / Light Sensor**, one at a time (`LidSleepMode`; shown when the Mac has a lid or a built-in light sensor, and each choice only when its sensor exists). Stored in the two guards' own user defaults keys, kept mutually exclusive: `sleepWhenLidCloses` (on by default, so Lid Sensor is the default) and `sleepWhenDarkLid`. If both are on (settings saved before the submenu), Light Sensor wins and the lid key is turned off at launch.
   - **Lid Sensor** — if the Mac is still awake 20 s after the lid closes, something is keeping it awake, so the Sleep flow runs unattended (no countdown, no question).
   - **Light Sensor** — for a lid sensor that never reports a closed lid: the light sensor in the bezel reads near-total darkness with the lid shut, so 10 s of darkness (< 0.5 lux) with no keyboard/trackpad input runs the Sleep flow unattended. It can misfire in a pitch-dark room or with the sensor covered, so once the lid sensor works again the user should switch back to Lid Sensor.
5. **Sleep When Idle ▸** (Off / 15 / 30 / 60 min, default 30; user defaults key `sleepWhenIdleMinutes`) — fallback that does not need the lid sensor: if nobody has used the keyboard/mouse/trackpad for that long and the Mac is still awake, the Sleep flow runs unattended. Added because this MacBook's lid close is never reported by macOS (no `Clamshell Sleep` in `pmset -g log`, `AppleClamshellState` stays `No` with the lid shut).
6. **Launch at Login** — one click checks it, the next click unchecks it (`SMAppService.mainApp`). The checkmark mirrors the real system status and is refreshed in `validateMenuItem` each time the menu opens: on = enabled, dash = registered but waiting for the user's approval in System Settings, off = disabled. If approval is needed, an alert offers to open Login Items settings.
7. **Quit Sleep Mac**.

The app is `LSUIElement` (no Dock icon). Swift Package, AppKit, macOS 13+, no third-party dependencies, no Xcode project.

## Layout

```
Package.swift
Sources/SleepMacCore/   pure logic, no AppKit, unit-tested
  Command.swift           SleepCommand model + DefaultCommands (locked, fixed order)
  CommandStore.swift      defaults + custom commands, JSON persistence, add/remove rules
  ShellRunner.swift       /bin/zsh -c with timeout; runAsAdmin via osascript
  AssertionScanner.swift  parses `pmset -g assertions`; SleepState; ProcessInspector
  SleepCoordinator.swift  the Sleep flow: run commands, stop CLI blockers, verify, sleepnow
  LaunchAtLogin.swift     LoginItemService protocol, SMAppService wrapper, toggle() logic
 IdleSleepGuard.swift    idle fallback (CGEventSource idle time, display-assertion check, 2-check confirm)
  Log.swift               os.Logger channels (subsystem com.sleepmac.app)
  LidWatcher.swift        IOKit lid state + change notifications; LidSleepGuard (the 20 s rule)
  LidSleepMode.swift      Off / Lid Sensor / Light Sensor choice, keeps the two guards exclusive
  SleepSchedule.swift     timer rules (decide, nextOccurrence, describe), SleepCountdown, SleepTimer
Sources/SleepMac/       AppKit UI
  main.swift              entry point + developer flags (--dry-run, --ui-smoke-test)
  AppDelegate.swift       status item, menu, hidden main menu (Edit), Sleep action
  CommandsWindowController.swift   table with +/− buttons
  AddCommandSheetController.swift  "Add Command" sheet
  TimePickerWindowController.swift "Sleep at a Specific Time" window
  CountdownWindowController.swift  30-second "Mac will sleep in …" panel
  UISmokeTest.swift       headless UI checks + PNG snapshots
Tests/SleepMacCoreTests/
Resources/Info.plist      bundle metadata (LSUIElement, NSAppleEventsUsageDescription)
scripts/build_app.sh      tests → universal release build → .app → ad-hoc sign → zip + dmg in dist/
scripts/make_icon.swift   generates Resources/AppIcon.icns (run by build_app.sh when missing)
```

User data: `~/Library/Application Support/Sleep Mac/commands.json` (custom commands only; defaults live in code). The pending sleep time is the `scheduledSleepDate` key in the app's user defaults.

## Commands

```bash
swift build                                   # debug build
swift test                                    # unit tests (starts a real `caffeinate`, ~7 s)
.build/debug/SleepMac --dry-run               # prints what Sleep would do, changes nothing
.build/debug/SleepMac --ui-smoke-test <dir>   # headless UI checks, writes PNG snapshots to <dir>
scripts/build_app.sh                          # final product in dist/ (Sleep Mac.app, zip, dmg)
```

Both developer flags are safe to run on the user's machine. Open the PNGs with the Read tool to review layout, because screenshots of the live screen are not available.

## How Sleep works (keep this behaviour)

Order of steps, defaults first, then custom commands in the order they were added:

1. `Quit Simulator app` — `pkill -x Simulator` (not AppleScript: that would trigger an Automation permission prompt in the middle of the flow).
2. `Shut down all simulators` — `xcrun simctl shutdown all`. A booted simulator holds a sleep assertion through coreaudiod (`iOSSimulatorAudioDevice … preventuseridlesleep`) and kept the Mac awake for hours.
3. `Stop CLI tools keeping the Mac awake` (built-in) — reads `pmset -g assertions`, resolves "Created for PID" to the real owner, and SIGTERM → SIGKILL every process that holds a blocking assertion **and** is a command-line tool. A command-line tool is an executable that is not inside a `.app` bundle and not under a system path (`/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`, `/usr/lib`, `/Library/Apple`, `/Library/Developer`, the cryptex mount). Apps and system daemons are listed but never killed.
4. `Re-enable system sleep` (built-in) — if `pmset -g` shows `SleepDisabled 1`, run `pmset -a disablesleep 0` as administrator. The admin dialog only appears when it is actually needed.
5. Custom commands.
6. Wait 1.5 s, re-scan. If a CLI blocker remains, `disablesleep` is still on, or a custom command failed, show "Sleep Anyway / Cancel". Failures of default commands are silent on purpose (no simulator running is not a problem).
7. `pmset sleepnow`. It returns a few seconds before the Mac is actually asleep, so the app stays busy ("Preparing to sleep…", every trigger ignored) until the next wake, or for at most 30 s if the Mac never goes to sleep. Without that, a lid, light, idle or timer trigger in that gap would start Sleep a second time.

### Sleep timer

- `SleepTimer` stores the fire date in user defaults (survives a restart of the app) and arms a **wall-clock** `DispatchSourceTimer` (`schedule(wallDeadline:)`, `.strict`), because run-loop timers stop counting while the Mac sleeps and are delayed by App Nap. `AppDelegate` also calls `reevaluate()` after `NSWorkspace.didWakeNotification` and `NSSystemClockDidChange`.
- A time that passed more than `SleepSchedule.missedGrace` (2 min) ago is **dropped, not fired**: if the Mac was already asleep at that time, someone who wakes it later must not see it go back to sleep.
- After the 30 s countdown, Sleep runs **unattended**: the "Sleep Anyway / Cancel" question is skipped because nobody may be at the Mac (the countdown was the chance to cancel). The admin password dialog for `disablesleep` can still appear and times out if nobody answers.
- The timer never fires while Sleep is already running or a countdown is already on screen.
- Tests and `--ui-smoke-test` give `SleepTimer` (and `LidSleepGuard`) a throw-away `UserDefaults` suite; never set or clear the user's real timer from a session.

### Sleep When Lid Closes ▸ Lid Sensor

- `IOKitLidStateSource` reads `AppleClamshellState` and `AppleClamshellCausesSleep` from `IOPMrootDomain` and listens for `kIOPMMessageClamshellStateChange` (`0xE0034100`; the C macro is not visible from Swift).
- A closed lid only counts when `AppleClamshellCausesSleep` is true. With an external display and power it is false (clamshell mode, the user wants the Mac running) and nothing happens.
- The 20 s wait uses `DispatchQueue.main.asyncAfter` (uptime), which stops while the Mac sleeps, so only awake time counts. It is cancelled when the lid opens, when the setting is turned off and on `NSWorkspace.willSleepNotification`. At the end the lid state is read again before Sleep runs.
- Before sleeping it dismisses a sleep-timer countdown on screen, otherwise that countdown would sleep the Mac again right after it is woken.
- Opening and closing a real lid cannot be tested from a session; the logic is covered by `LidSleepGuardTests` with a fake source.

### Sleep When Idle

- Checks every 60 s. Idle time comes from `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`.
- Skips while an app (not powerd, not a command-line tool) holds `PreventUserIdleDisplaySleep` / `NoDisplaySleepAssertion`: a video or presentation is playing.
- Needs two positive checks no more than 90 s apart on the wall clock, so a ~45 s DarkWake (huge idle time, display off) never triggers it.
- Fires once per idle period; it re-arms only after someone uses the Mac, so a Mac that refuses to sleep (`disablesleep` without an admin password) is not hammered.
- It overrides "keep awake" assertions from apps such as Claude's Electron `NoIdleSleepAssertion`. That is intended: the user chose the idle limit.

### Sleep When Lid Closes ▸ Light Sensor

- Reads `AmbientBrightness` (16.16 fixed point, lux) from the built-in display's `AppleCLCD2` entry (the one without `external = Yes`). One property read per second, only while the setting is on; never shell out to `ioreg -l` for it.
- Measured on this MacBook: lid shut ≈ 0.03 lux, dim room 1–7 lux. Threshold `darkLux = 0.5`.
- Runs Sleep when it has been dark for `darkSeconds` (10 s) and there has been no input for at least that long. Any input resets it (a dark room, not a closed lid).
- Ignores everything for `graceAfterWake` (60 s) after a wake or a launch: right after waking the sensor can still report the old dark value, and the third-party `lid_monitor.sh` script looped Sleep → wake → Sleep because of that.
- Skips while a video player keeps the display on; `coreaudiod` is ignored so music playing with the lid shut does not keep the Mac awake.
- Fires once per dark period, then stays quiet for `graceAfterWake` too: Sleep takes a few seconds and the reading flickers when the display turns off, which once started a second countdown. Covered by `DarkLidGuardTests` with a fake sensor and clock.

### Logs and App Nap

- All lid, light, idle, timer and Sleep decisions go to the unified log: `/usr/bin/log show --last 1h --predicate 'subsystem == "com.sleepmac.app"'`. In zsh plain `log` is a builtin, so use the full path.
- `Info.plist` sets `NSAppSleepDisabled` so App Nap never delays the timers while the display is off.

## Gotchas

- An accessory app has no menu bar, so ⌘C/⌘V in text fields only work because `AppDelegate.installMainMenu()` creates a hidden Edit menu. Do not remove it.
- `NSMenu` re-enables items whose target responds to the action, so greying out "Sleep" needs `validateMenuItem`, not just `isEnabled`.
- The Add sheet turns off smart quotes/dashes in the command field; shell commands must not be rewritten.
- `commands.json` is untrusted input: on load every entry is forced to `isDefault = false` and `kind = .shell`; a corrupt file is moved to `commands.json.corrupt`.
- GUI apps start with a minimal `PATH`; `ShellRunner` prepends the Homebrew and system directories.
- The build is ad-hoc signed (no Developer ID). It runs on the machine that built it; on another Mac the user must right-click → Open the first time.
- Launch at Login registers the app **at its current path**. Tests and `--ui-smoke-test` use a fake `LoginItemService`, so they never touch the user's real Login Items; never call the real `register()` from a session without asking. The user should install the app in `/Applications` before switching it on (a copy in `dist/` is deleted by every build).
- `swift build --arch arm64 --arch x86_64` prints a deprecation warning for x86_64 on the current SDK. It is expected.

## Definition of done for a change

1. `swift test` passes (add tests for new logic in `SleepMacCore`).
2. `--ui-smoke-test` passes when UI code changed; look at the snapshots.
3. `scripts/build_app.sh` produces `dist/Sleep Mac.app` without errors.
4. Behaviour or rules described in this file changed → update this file in the same change.

## Obsidian Integration Rules (Smart Logging)

To avoid cluttering the data, follow this storage process:

### 1. Classify content to store

- **High-Value Info (save into the project folder):** only create a new file for in-depth code reviews, analysis of complex logic, or the process of resolving serious bugs. Add the file path into Obsidian.
  - **Path:** `01_Projects/Sleep-Mac/{{date}}-{{short-description}}.md`
- **General Chat & Q&A (save into the Daily Note):** for answers to questions, bugs fixed during the day, or small pieces of knowledge, do not create a new file. Use the `obsidian_update_note` tool (or append) to add to that day's Daily Note.
  - **Path:** `04_Daily/{{date}}.md`
  - **Location:** add it under the `## 📝 Nhật ký ghi chú nhanh` section (this heading is a literal in the user's vault; keep it exactly as written).

### 2. Format and Tools

- **Tool:** use the `obsidian` MCP server for read/write operations.
- **Existence check:** always verify that the target folder exists before creating a file. If `01_Projects/Sleep-Mac/` does not exist yet, create it first.
- **Consistency:** content saved into Obsidian must be presented cleanly in Markdown, with clear headings and code blocks.

### 3. The "Filter" principle

Before deciding to save content, ask: "Does this information have reuse value in the future?" If it is just small talk or an explanation of basic syntax, skip the storage step.

### 4. Task check

When asked whether there are any remaining tasks, check `00_Inbox/TODO_Task.md` and `04_Daily/{{date}}.md`, then answer the user.
