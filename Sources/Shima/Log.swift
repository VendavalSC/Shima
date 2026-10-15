import os

/// Unified-log channels. Read them with:
/// `log show --last 10m --info --predicate 'subsystem == "io.github.vendavalsc.shima"'`
enum Log {
    /// File drags to the notch: detection, the drop targets, and what was dropped.
    static let drag = Logger(subsystem: "io.github.vendavalsc.shima", category: "drag")
    static let device = Logger(subsystem: "io.github.vendavalsc.shima", category: "device")
    static let notify = Logger(subsystem: "io.github.vendavalsc.shima", category: "notifications")
    /// Live activities: Caps Lock, drives.
    static let activity = Logger(subsystem: "io.github.vendavalsc.shima", category: "activity")
    /// Hiding for fullscreen apps, and the lock screen.
    static let presence = Logger(subsystem: "io.github.vendavalsc.shima", category: "presence")
}
