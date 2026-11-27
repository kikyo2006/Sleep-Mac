import os

/// Unified-log channels. Read them with:
/// `/usr/bin/log show --last 1h --predicate 'subsystem == "com.sleepmac.app"'`
/// (in zsh, plain `log` is a shell builtin, so use the full path).
public enum Log {
    public static let lid = Logger(subsystem: "com.sleepmac.app", category: "lid")
    public static let timer = Logger(subsystem: "com.sleepmac.app", category: "timer")
    public static let sleep = Logger(subsystem: "com.sleepmac.app", category: "sleep")
    public static let idle = Logger(subsystem: "com.sleepmac.app", category: "idle")
    public static let light = Logger(subsystem: "com.sleepmac.app", category: "light")
}
