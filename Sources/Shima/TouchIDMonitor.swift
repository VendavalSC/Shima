import AppKit
import ApplicationServices

/// Touch ID requests, from any app: the system's prompt (sudo, System Settings, the App Store) or one
/// drawn inside an app's own window (Passwords, Safari). What they all share is the sensor, so Shima
/// follows it (`TouchIDSensor`): ready for a finger starts a request, a match ends it accepted, a
/// cancel ends it declined, and a finger it can't read asks again. That costs nothing measurable, as
/// macOS filters the messages before they reach Shima.
///
/// Should the sensor's messages ever stop coming (a future macOS may change them), Shima falls back
/// to the system prompt's window, seen through Accessibility. The window closes the same way whether
/// a finger was accepted or the prompt was cancelled, so then Shima notes whether its buttons or the
/// keyboard were used (Cancel, Escape, a password, Control-C in Terminal): a prompt that closes
/// untouched was answered with a finger.
final class TouchIDMonitor {
    enum Event: Equatable {
        case began
        /// A finger the sensor couldn't read or didn't recognize; it asks again.
        case retry
        case ended(succeeded: Bool)
    }

    var onEvent: ((Event) -> Void)?

    static let agentID = "com.apple.LocalAuthentication.UIAgent"
    /// A request that's said nothing for this long is over, however it ended.
    private static let giveUpAfter: TimeInterval = 90

    private var sensor: UUID?
    /// The sensor has reported something since Shima started: it can be relied on.
    private var sensorWorks = false
    /// A request is showing in the notch.
    private var active = false
    private var giveUp: DispatchWorkItem?

    // The fallback: the system prompt's window.
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var agentWatch: NSKeyValueObservation?
    private var prompt: AXUIElement?
    /// Its buttons or keys were used: it was cancelled, or a password typed instead.
    private var usedControls = false
    private var inputMonitors: [Any] = []

    init() {
        trackChanges { [weak self] in
            _ = AppSettings.shared.touchIDActivity
            _ = NotificationWatcher.shared.isTrusted
            DispatchQueue.main.async { self?.update() }
        }
        // The agent starts when first needed and quits when idle, so it comes and goes; follow it.
        agentWatch = watchApp(Self.agentID) { [weak self] running in
            if !running { self?.promptClosed() }
            self?.update()
        }
    }

    private func update() {
        guard AppSettings.shared.touchIDActivity else {
            TouchIDSensor.shared.stop(sensor)
            sensor = nil
            stopWatchingAgent()
            finish(succeeded: false)
            return
        }
        if sensor == nil {
            sensor = TouchIDSensor.shared.start { [weak self] event in self?.sensed(event) }
        }
        if NotificationWatcher.shared.isTrusted,
           let agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentID).first(where: { !$0.isTerminated }) {
            if observer == nil || observedPID != agent.processIdentifier { watchAgent(pid: agent.processIdentifier) }
        } else {
            stopWatchingAgent()
        }
    }

    // MARK: The request

    private func sensed(_ event: TouchIDSensor.Event) {
        sensorWorks = true
        switch event {
        case .armed, .fingerDown:
            begin()
        case .tryAgain:
            if active { onEvent?(.retry) }
            keepAlive()
        case .matched:
            finish(succeeded: true)
        case .cancelled:
            finish(succeeded: false)
        }
    }

    private func begin() {
        keepAlive()
        guard !active else { return }
        active = true
        Log.activity.info("touch id: asked")
        onEvent?(.began)
    }

    private func finish(succeeded: Bool) {
        giveUp?.cancel()
        giveUp = nil
        guard active else { return }
        active = false
        Log.activity.info("touch id: \(succeeded ? "accepted" : "ended", privacy: .public)")
        onEvent?(.ended(succeeded: succeeded))
    }

    /// Ends a request that's gone quiet without a word on how.
    private func keepAlive() {
        giveUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish(succeeded: false) }
        giveUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.giveUpAfter, execute: work)
    }

    // MARK: Fallback: the system prompt's window

    private func watchAgent(pid: pid_t) {
        stopWatchingAgent()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<TouchIDMonitor>.fromOpaque(refcon).takeUnretainedValue().received(notification as String, element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            Log.activity.error("touch id: couldn't observe the agent")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = pid
        // Started for a prompt, the agent may have its window up before Shima is watching.
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.observedPID == pid, self.prompt == nil else { return }
                let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                if let window = windows.first(where: { Self.offersTouchID($0) }) { self.promptOpened(window) }
            }
        }
    }

    private func stopWatchingAgent() {
        promptClosed()
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        observedPID = 0
    }

    private func received(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            // Only prompts that take a finger; with the lid closed, the agent asks for a password.
            guard Self.offersTouchID(element) else { return }
            promptOpened(element)
        case kAXUIElementDestroyedNotification:
            if let prompt, CFEqual(prompt, element) || Self.attribute(prompt, kAXRoleAttribute) == nil { promptClosed() }
        default:
            break
        }
    }

    private func promptOpened(_ window: AXUIElement) {
        prompt = window
        usedControls = false
        if let observer {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        guard !sensorWorks else { return }   // the sensor says more, and sooner
        watchInput()
        begin()
    }

    private func promptClosed() {
        guard prompt != nil else { return }
        prompt = nil
        inputMonitors.forEach(NSEvent.removeMonitor)
        inputMonitors.removeAll()
        if !sensorWorks { finish(succeeded: !usedControls) }
    }

    /// Clicks on the prompt, or keys pressed while it's up, mean it wasn't answered with a finger.
    private func watchInput() {
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let prompt = self.prompt, let frame = Self.frame(of: prompt) else { return }
            if frame.insetBy(dx: -4, dy: -4).contains(Self.axPoint(NSEvent.mouseLocation)) { self.usedControls = true }
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in self?.usedControls = true }
        inputMonitors = [mouse, keys].compactMap { $0 }
    }

    // MARK: Accessibility

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// The prompt shows the Touch ID glyph (identified as "touchid", whatever the Mac's language).
    private static func offersTouchID(_ element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 6 else { return false }
        if attribute(element, kAXIdentifierAttribute) as? String == "touchid" { return true }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains { offersTouchID($0, depth: depth + 1) }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    /// A point in AppKit's screen coordinates (origin bottom left) in Accessibility's (top left).
    private static func axPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }
}

/// Calls `changed` on the main thread whenever an app with this bundle ID starts (true) or quits
/// (false). Unlike the workspace's launch notifications, this also sees background agents that
/// launchd starts on demand (Notification Center, the Touch ID prompt's agent).
func watchApp(_ bundleID: String, changed: @escaping (Bool) -> Void) -> NSKeyValueObservation {
    NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { _, change in
        let started = change.newValue?.contains { $0.bundleIdentifier == bundleID } ?? false
        let quit = change.oldValue?.contains { $0.bundleIdentifier == bundleID } ?? false
        guard started || quit else { return }
        DispatchQueue.main.async { changed(started) }
    }
}
