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

A macOS menu bar app (`Sleep Mac`) with four menu items:

1. **Custom Commands…** opens a window listing the commands that run before sleep. Default commands are locked and cannot be removed. Custom commands are added with **+** (sheet: name, command, "run as administrator") and removed with **−** (confirmation dialog first).
2. **Sleep** runs every command in order, makes sure nothing is still keeping the Mac awake, then runs `pmset sleepnow`.
3. **Launch at Login** — one click checks it, the next click unchecks it (`SMAppService.mainApp`). The checkmark mirrors the real system status and is refreshed in `validateMenuItem` each time the menu opens: on = enabled, dash = registered but waiting for the user's approval in System Settings, off = disabled. If approval is needed, an alert offers to open Login Items settings.
4. **Quit Sleep Mac**.

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
Sources/SleepMac/       AppKit UI
  main.swift              entry point + developer flags (--dry-run, --ui-smoke-test)
  AppDelegate.swift       status item, menu, hidden main menu (Edit), Sleep action
  CommandsWindowController.swift   table with +/− buttons
  AddCommandSheetController.swift  "Add Command" sheet
  UISmokeTest.swift       headless UI checks + PNG snapshots
Tests/SleepMacCoreTests/
Resources/Info.plist      bundle metadata (LSUIElement, NSAppleEventsUsageDescription)
scripts/build_app.sh      tests → universal release build → .app → ad-hoc sign → zip + dmg in dist/
scripts/make_icon.swift   generates Resources/AppIcon.icns (run by build_app.sh when missing)
```

User data: `~/Library/Application Support/Sleep Mac/commands.json` (custom commands only; defaults live in code).

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
7. `pmset sleepnow`.

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
