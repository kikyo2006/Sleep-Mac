# Sleep Mac

A tiny menu bar app that puts your Mac to sleep **for real**: it first stops everything that would keep it awake, then sleeps.

![icon](Resources/icon-preview.png)

## Menu

| Item | What it does |
| --- | --- |
| **Custom Commands…** | Opens the list of commands that run before sleep. Default commands are locked; add your own with **+**, remove one with **−** (asks for confirmation). |
| **Sleep** | Runs all commands in order, checks that nothing still holds a sleep assertion, then sleeps. |
| **Sleep Timer** | Puts the Mac to sleep later: in 15 min, 30 min, 1 h, 2 h, or at a time you pick. When the time comes, a window counts down 30 seconds; press **Cancel** to stay awake, otherwise Sleep runs as if you chose it from the menu. While a timer is set, the menu shows the time and offers **Cancel Timer**, and the moon icon is filled in. |
| **Sleep When Lid Closes ▸** | Choose one way to notice a closed lid (MacBooks only). **Lid Sensor** (default): if the Mac is still awake 20 seconds after you close the lid, something is keeping it awake, so Sleep runs without asking; ignored when an external display keeps the Mac running with the lid closed. **Light Sensor**: for a lid sensor that does not report a closed lid; when the light sensor in the screen bezel reads dark for 10 seconds and nobody touches the keyboard or trackpad, Sleep runs without asking. Any input, a video playing, or the first minute after waking keeps it away. **Off**: neither. |
| **Sleep When Idle** | Off, 15, 30 (default) or 60 minutes. If nobody has used the keyboard, mouse or trackpad for that long and the Mac is still awake, Sleep runs without asking. A video or presentation that keeps the screen on is respected. Works even when the lid sensor does not report a closed lid. |
| **Launch at Login** | Click once to check it (Sleep Mac starts when you log in), click again to uncheck it. If macOS asks for approval, the app opens System Settings → General → Login Items for you. |
| **Quit Sleep Mac** | Quits the app. |

## What Sleep does

1. Quits the iOS Simulator app and shuts down all simulators (a booted simulator keeps the Mac awake through its audio device).
2. Stops command-line tools that hold a sleep assertion, such as `caffeinate`. Apps and macOS services are never touched.
3. Turns `pmset disablesleep` back off if it was left on (asks for your admin password only when needed).
4. Runs your custom commands.
5. Re-checks. If something is still keeping the Mac awake it tells you and lets you choose **Sleep Anyway** or **Cancel**.
6. Runs `pmset sleepnow`.

A timer started by Sleep Timer skips the **Sleep Anyway** question in step 5, since nobody may be at the Mac. If the Mac was already asleep at the chosen time, the timer is dropped rather than putting it back to sleep after you wake it.

Custom commands are plain shell commands run with `/bin/zsh -c`. Tick *Run as administrator* to run one as root through the standard macOS password dialog.

## Install

Download `Sleep-Mac.dmg` from the GitHub Releases page (or build it, see below: `dist/Sleep-Mac.dmg`) and drag **Sleep Mac** to Applications. The app is signed ad hoc, so on a different Mac use right-click → Open the first time.

Install it in Applications **before** switching on *Launch at Login*: macOS remembers the app's location, so a copy running from `dist/` (which every build deletes) would leave a dead login item.

## Build from source

Requires Xcode 15+ command line tools.

```bash
scripts/build_app.sh     # tests, universal release build, Sleep Mac.app, zip and dmg in dist/
swift test               # unit tests only
```

### Releasing

Push a version tag and the **Release** workflow (`.github/workflows/release.yml`) builds, tests and publishes a GitHub release with the dmg and zip. The tag sets the app version.

```bash
git tag v1.1.0
git push origin v1.1.0
```

Developer flags (safe to run, they change nothing on your system):

```bash
.build/debug/SleepMac --dry-run                 # print what Sleep would do
.build/debug/SleepMac --ui-smoke-test /tmp/ui   # headless UI checks and PNG snapshots
```

Your custom commands are stored in `~/Library/Application Support/Sleep Mac/commands.json`.
