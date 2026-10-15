import AppKit
import ApplicationServices

/// Replies to a notification through its own system banner, kept out of sight. Shima opens the
/// banner's reply box and gives Notification Center the keyboard, which is also what keeps the banner
/// from timing out while you type; what you type shows in the notch, and Return (or the notch's send
/// button) sends it through the system, exactly as replying on the banner would. Switching to another
/// app, or Escape, puts the reply away unsent.
final class NotificationReplier {
    /// What's in the reply box, as it changes.
    var onText: ((String) -> Void)?
    /// The reply is over: sent, or put away.
    var onEnd: ((_ sent: Bool) -> Void)?

    private(set) var isActive = false
    private var banner: AXUIElement?
    private var field: AXUIElement?
    private var pid: pid_t = 0
    private var text = ""
    private var observer: AXObserver?
    private var poll: Timer?
    private var activation: NSObjectProtocol?
    private var previousApp: NSRunningApplication?

    /// Opens the reply box; `completion` says whether there is one.
    func begin(_ notification: NotchNotification, completion: @escaping (Bool) -> Void) {
        end(sent: false, notify: false)
        let banner = notification.banner
        var pid: pid_t = 0
        guard AXUIElementGetPid(banner, &pid) == .success else { return completion(false) }
        guard let open = notification.replyAction else { return completion(false) }
        let opened = AXUIElementPerformAction(banner, open as CFString)
        Log.notify.info("reply: opening the reply box (\(opened.rawValue, privacy: .public))")
        self.banner = banner
        self.pid = pid
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid { previousApp = front }
        findField(attempt: 0, completion: completion)
    }

    /// The reply box appears a moment after it's asked for.
    private func findField(attempt: Int, completion: @escaping (Bool) -> Void) {
        guard let banner else { return completion(false) }
        guard let field = Self.replyBox(near: banner) else {
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.findField(attempt: attempt + 1, completion: completion)
                }
            } else {
                Log.notify.info("reply: no reply box")
                end(sent: false, notify: false)
                completion(false)
            }
            return
        }
        Log.notify.info("reply: reply box ready (\(NotificationWatcher.attribute(field, kAXRoleAttribute) as? String ?? "?", privacy: .public))")
        self.field = field
        isActive = true
        text = ""
        focus(field)
        watch(field)
        completion(true)
    }

    /// The reply box: a text area (or, in some apps, a text field) in the banner, or elsewhere in its
    /// window, since some apps' banners are rebuilt when Reply is pressed.
    private static func replyBox(near banner: AXUIElement) -> AXUIElement? {
        for role in [kAXTextAreaRole, kAXTextFieldRole] {
            if let field = NotificationWatcher.first(in: banner, role: role) { return field }
        }
        var window: AXUIElement? = banner
        while let current = window, NotificationWatcher.attribute(current, kAXRoleAttribute) as? String != kAXWindowRole {
            window = NotificationWatcher.attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        guard let window else { return nil }
        for role in [kAXTextAreaRole, kAXTextFieldRole] {
            if let field = NotificationWatcher.first(in: window, role: role) { return field }
        }
        return nil
    }

    /// Notification Center comes forward with the reply box focused, as when you click into it.
    private func focus(_ field: AXUIElement) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var window: AXUIElement? = field
        while let current = window, NotificationWatcher.attribute(current, kAXRoleAttribute) as? String != kAXWindowRole {
            window = NotificationWatcher.attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        if let window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func watch(_ field: AXUIElement) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let replier = Unmanaged<NotificationReplier>.fromOpaque(refcon).takeUnretainedValue()
            if notification as String == kAXValueChangedNotification { replier.readText() } else { replier.boxClosed() }
        }
        if AXObserverCreate(pid, callback, &created) == .success, let created {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(created, field, kAXValueChangedNotification as CFString, refcon)
            AXObserverAddNotification(created, field, kAXUIElementDestroyedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            observer = created
        }
        // A light check as well, while the reply is open: not every change is announced.
        poll = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.readText() }
        // Going to another app puts the reply away, as clicking off a banner does.
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != self.pid else { return }
            self.previousApp = nil   // the user chose where to go
            Log.notify.info("reply: put away, \(app.bundleIdentifier ?? "?", privacy: .public) came forward")
            self.cancel()
        }
    }

    private func readText() {
        guard isActive, let field else { return }
        if NotificationWatcher.attribute(field, kAXRoleAttribute) == nil { return boxClosed() }
        let value = NotificationWatcher.attribute(field, kAXValueAttribute) as? String ?? ""
        guard value != text else { return }
        text = value
        onText?(value)
    }

    /// The reply box went away: sent, if the banner went with it and there was something to send;
    /// otherwise put away (Escape).
    private func boxClosed() {
        guard isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isActive else { return }
            let bannerGone = self.banner.map { NotificationWatcher.attribute($0, kAXRoleAttribute) == nil } ?? true
            self.end(sent: bannerGone && !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Sends what's in the box, as the banner's own send button would.
    func send() {
        guard isActive, let banner else { return }
        readText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let send = NotificationWatcher.rawActions(banner).first(where: { NotificationWatcher.clean($0).hasPrefix("Name:Send") }) {
            AXUIElementPerformAction(banner, send as CFString)
        } else {
            // Some apps send on Return and have no Send action.
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] { CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.boxClosed() }
    }

    /// Puts the reply away unsent.
    func cancel() {
        guard isActive else { return }
        if let field { AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) }
        // Hide Details: the expanded banner's first named action, whatever the language.
        if let banner, let hide = NotificationWatcher.rawActions(banner).first(where: { NotificationWatcher.actionTitle($0) != nil }) {
            AXUIElementPerformAction(banner, hide as CFString)
        }
        end(sent: false)
    }

    private func end(sent: Bool, notify: Bool = true) {
        let wasActive = isActive
        if wasActive { Log.notify.info("reply: ended, sent \(sent, privacy: .public)") }
        isActive = false
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        poll?.invalidate()
        poll = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        // Back to where you were, if you didn't go somewhere else yourself.
        if wasActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { previousApp?.activate() }
        previousApp = nil
        banner = nil
        field = nil
        if wasActive && notify { onEnd?(sent) }
    }

    /// For testing without typing: fills the box and presses Return, as a person would.
    func debugType(_ reply: String) {
        Log.notify.info("reply: test typing, active \(self.isActive, privacy: .public)")
        guard isActive, let field else { return }
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, reply as CFString)
        readText()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
        }
    }
}
