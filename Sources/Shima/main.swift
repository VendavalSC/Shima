import AppKit

signal(SIGPIPE, SIG_IGN) // writing to a media helper that just exited must not kill us

if MainActor.assumeIsolated({ Snapshot.runIfRequested() }) { exit(0) }

// Shima was called Isle while it was being made: bring over its settings and shelf, once.
Migration.fromIsle()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
