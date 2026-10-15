import AppKit
import ApplicationServices
import Observation

/// A notification as the notch shows it, read from Notification Center's banner.
struct NotchNotification: Identifiable, Equatable {
    let id: String
    let app: String
    let title: String
    let subtitle: String
    let body: String
    /// The system banner it came from, which knows how to open it and to reply.
    let banner: AXUIElement
    /// Its banner has a reply box (chat apps: Messages, WhatsApp, Telegram...).
    var canReply = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// Opens it as clicking the system banner would; once that banner has gone, brings up the app.
    func open() {
        if AXUIElementPerformAction(banner, kAXPressAction as CFString) == .success { return }
        if let url = AppIcons.url(forApp: app) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Notifications as Notification Center shows them, read through Accessibility the moment a banner
/// appears (Shima is told; nothing polls). When the notch takes one, the system banner's window is
/// moved out of sight rather than closed, so the notification still lands in Notification Center.
/// Alerts that wait for an answer (reminders, for example) are left alone. Off until turned on in
/// Settings and Accessibility is granted.
@Observable
final class NotificationWatcher {
    static let shared = NotificationWatcher()
    static let notificationCenterID = "com.apple.notificationcenterui"

    private(set) var isTrusted = AXIsProcessTrusted()
    /// Offered each new notification; returns whether the notch shows it (and the banner can go).
    @ObservationIgnored var onNotification: ((NotchNotification) -> Bool)?

    @ObservationIgnored private var observer: AXObserver?
    @ObservationIgnored private var observedPID: pid_t = 0
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var seen: [String] = []
    /// Banner windows moved out of sight, with where they were.
    @ObservationIgnored private var hidden: [(window: AXUIElement, origin: CGPoint)] = []
    private static let far = CGPoint(x: 20_000, y: 20_000)

    private init() {
        trackChanges { [weak self] in
            _ = AppSettings.shared.notifications
            DispatchQueue.main.async { self?.update() }
        }
        // The system announces changes to the Accessibility list; the new state settles a moment later.
        tokens.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshTrust() }
        })
        // Notification Center can restart; follow it.
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Self.notificationCenterID { self?.update() }
        })
    }

    /// Asks for Accessibility: macOS shows its prompt, which leads to Privacy & Security.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted != isTrusted { isTrusted = trusted }
        update()
    }

    func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
        update()
    }

    private func update() {
        guard AppSettings.shared.notifications, isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenterID).first else {
            stop()
            return
        }
        if observer != nil, observedPID == app.processIdentifier { return }
        start(pid: app.processIdentifier)
    }

    private func start(pid: pid_t) {
        stop()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue().windowAppeared(element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            Log.notify.error("couldn't observe Notification Center")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = pid
        // Anything Shima left behind (it quit while a banner was hidden, or mid-reply) goes back to
        // normal: the window returns, an open reply box closes, and the banner times out as usual.
        for window in Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if (Self.position(of: window)?.x ?? 0) >= Self.far.x / 2 { Self.setPosition(.zero, of: window) }
            guard Self.first(in: window, role: kAXTextAreaRole) != nil else { continue }
            for banner in Self.banners(in: window) {
                if let hide = Self.rawActions(banner).first(where: { $0.hasPrefix("Name:Hide Details") }) {
                    AXUIElementPerformAction(banner, hide as CFString)
                }
            }
        }
        Log.notify.info("watching Notification Center")
    }

    private func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        observedPID = 0
        Log.notify.info("stopped watching Notification Center")
    }

    // MARK: Banners

    /// A new window, or something new in one (a banner can join a window that's still up).
    private func windowAppeared(_ element: AXUIElement) {
        var window: AXUIElement? = element
        var depth = 0
        while let current = window, Self.attribute(current, kAXRoleAttribute) as? String != kAXWindowRole, depth < 12 {
            window = Self.attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
            depth += 1
        }
        guard let window, Self.attribute(window, kAXRoleAttribute) as? String == kAXWindowRole else { return }
        scan(window, attempt: 0)
    }

    /// Reads the window's new banners; a banner's text can arrive a moment after its window.
    private func scan(_ window: AXUIElement, attempt: Int) {
        var takeWindow = false
        var declined = false
        var incomplete = false
        for banner in Self.banners(in: window) {
            guard let id = Self.attribute(banner, kAXIdentifierAttribute) as? String, !seen.contains(id) else { continue }
            guard let notification = Self.read(banner, id: id) else { incomplete = true; continue }
            seen.append(id)
            if seen.count > 64 { seen.removeFirst(seen.count - 64) }
            if onNotification?(notification) == true { takeWindow = true } else { declined = true }
        }
        // The notch shows it: the banner goes out of sight. The notch can't: the banner shows, even
        // if its window was hidden for an earlier one.
        if takeWindow && !declined { hide(window) } else if declined { reveal(window) }
        if incomplete, attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.scan(window, attempt: attempt + 1) }
        }
    }

    private static func read(_ banner: AXUIElement, id: String) -> NotchNotification? {
        var texts: [String: String] = [:]
        for child in attribute(banner, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let key = attribute(child, kAXIdentifierAttribute) as? String,
               let value = attribute(child, kAXValueAttribute) as? String {
                texts[key] = value
            }
        }
        let title = texts["title"] ?? "", subtitle = texts["subtitle"] ?? "", body = texts["body"] ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        // The banner describes itself as "App, title, subtitle, body".
        let description = attribute(banner, kAXDescriptionAttribute) as? String ?? ""
        let rest = [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: ", ")
        var app = description
        if !rest.isEmpty, let range = description.range(of: ", " + rest, options: .backwards) {
            app = String(description[..<range.lowerBound])
        } else if let comma = description.firstIndex(of: ",") {
            app = String(description[..<comma])
        }
        let actions = rawActions(banner).map(clean)
        let appName = clean(app)
        // Chat apps put a Reply action on the banner; Messages keeps its reply box behind Show Details.
        let canReply = actions.contains { $0.hasPrefix("Name:Reply") }
            || (appName == "Messages" && actions.contains { $0.hasPrefix("Name:Show Details") })
        return NotchNotification(id: id, app: appName, title: title, subtitle: subtitle, body: body, banner: banner,
                                 canReply: canReply)
    }

    /// The banners in a Notification Center window. Alerts have their own subrole and aren't included.
    private static func banners(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        if attribute(element, kAXSubroleAttribute) as? String == "AXNotificationCenterBanner" { return [element] }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap { banners(in: $0, depth: depth + 1) }
    }

    /// Out of sight, not closed: the banner times out as usual and the notification stays in
    /// Notification Center.
    private func hide(_ window: AXUIElement) {
        hidden.removeAll { Self.attribute($0.window, kAXRoleAttribute) == nil }
        guard !hidden.contains(where: { CFEqual($0.window, window) }) else { return }
        hidden.append((window, Self.position(of: window) ?? .zero))
        Self.setPosition(Self.far, of: window)
    }

    private func reveal(_ window: AXUIElement) {
        guard let index = hidden.firstIndex(where: { CFEqual($0.window, window) }) else { return }
        Self.setPosition(hidden[index].origin, of: window)
        hidden.remove(at: index)
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func setPosition(_ point: CGPoint, of element: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    /// Without the invisible direction marks some apps (WhatsApp) put around their name.
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rawActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func first(in element: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if attribute(element, kAXRoleAttribute) as? String == role { return element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = first(in: child, role: role, depth: depth + 1) { return found }
        }
        return nil
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// App icons and locations by the name a notification shows.
enum AppIcons {
    private static var urls: [String: URL?] = [:]
    private static var icons: [String: NSImage] = [:]

    static func icon(forApp name: String) -> NSImage {
        if let icon = icons[name] { return icon }
        let icon = url(forApp: name).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icons[name] = icon
        return icon
    }

    static func url(forApp name: String) -> URL? {
        if let cached = urls[name] { return cached }
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
        let installed = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                         "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let url = running ?? installed
        urls[name] = url
        return url
    }
}
