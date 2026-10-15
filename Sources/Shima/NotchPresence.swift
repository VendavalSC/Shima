import AppKit

/// Keeps the notch's window in place with private window-server spaces, looked up at runtime (if a
/// symbol is missing the window keeps normal behaviour). Two spaces, as other notch apps do:
///  - Always, a space at the maximum level: the notch stays put while desktops slide past, and
///    stays an ordinary target for clicks and drag-and-drop.
///  - Only while the screen is locked, a space at the lock screen's notification level, so the notch
///    shows over the lock screen. (Kept to the lock screen because drags aren't delivered to it.)
enum NotchSpace {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias CGSpaceCreate = @convention(c) (Int32, Int, CFDictionary?) -> UInt64
    private typealias CGSpaceSetLevel = @convention(c) (Int32, UInt64, Int) -> Void
    private typealias SpacesCall = @convention(c) (Int32, CFArray) -> Void
    private typealias WindowsSpacesCall = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias SLSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SLSpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SLMoveWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private struct API {
        let connection: Int32
        let addWindows: WindowsSpacesCall
        let removeWindows: WindowsSpacesCall
        let moveWindows: SLMoveWindows
        let desktopSpace: UInt64      // max level, always
        let lockScreenSpace: Int32    // level 400, while locked
    }

    private static let api: API? = {
        let frameworks = ["/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                          "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"]
        let handles = frameworks.compactMap { dlopen($0, RTLD_NOW) }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            handles.lazy.compactMap { dlsym($0, name) }.first
        }
        guard let defaultConnection = symbol("_CGSDefaultConnection"),
              let cgCreate = symbol("CGSSpaceCreate"), let cgSetLevel = symbol("CGSSpaceSetAbsoluteLevel"),
              let cgShow = symbol("CGSShowSpaces"), let cgAdd = symbol("CGSAddWindowsToSpaces"),
              let cgRemove = symbol("CGSRemoveWindowsFromSpaces"),
              let slCreate = symbol("SLSSpaceCreate"), let slSetLevel = symbol("SLSSpaceSetAbsoluteLevel"),
              let slShow = symbol("SLSShowSpaces"), let slMove = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return nil }

        let connection = unsafeBitCast(defaultConnection, to: DefaultConnection.self)()
        // Flag 1 matters: other values make Finder draw desktop icons into the space.
        let desktopSpace = unsafeBitCast(cgCreate, to: CGSpaceCreate.self)(connection, 1, nil)
        unsafeBitCast(cgSetLevel, to: CGSpaceSetLevel.self)(connection, desktopSpace, Int(Int32.max))
        unsafeBitCast(cgShow, to: SpacesCall.self)(connection, [NSNumber(value: desktopSpace)] as CFArray)

        let lockScreenSpace = unsafeBitCast(slCreate, to: SLSpaceCreate.self)(connection, 1, 0)
        // kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock (technique from Lakr233/SkyLightWindow, MIT).
        _ = unsafeBitCast(slSetLevel, to: SLSpaceSetLevel.self)(connection, lockScreenSpace, 400)
        unsafeBitCast(slShow, to: SpacesCall.self)(connection, [NSNumber(value: lockScreenSpace)] as CFArray)

        guard desktopSpace != 0, lockScreenSpace != 0 else { return nil }
        return API(connection: connection,
                   addWindows: unsafeBitCast(cgAdd, to: WindowsSpacesCall.self),
                   removeWindows: unsafeBitCast(cgRemove, to: WindowsSpacesCall.self),
                   moveWindows: unsafeBitCast(slMove, to: SLMoveWindows.self),
                   desktopSpace: desktopSpace, lockScreenSpace: lockScreenSpace)
    }()

    /// Keeps the window fixed across desktops.
    static func pin(_ window: NSWindow) {
        guard let api else { return }
        api.addWindows(api.connection, [window.windowNumber] as CFArray, [NSNumber(value: api.desktopSpace)] as CFArray)
    }

    /// Lifts the window over the lock screen (this takes it out of its other spaces).
    static func raiseOverLockScreen(_ window: NSWindow) {
        guard let api else { return }
        _ = api.moveWindows(api.connection, api.lockScreenSpace, [window.windowNumber] as CFArray, 7)
    }

    /// Back from the lock screen to the ordinary pinned space.
    static func lowerFromLockScreen(_ window: NSWindow) {
        guard let api else { return }
        api.removeWindows(api.connection, [window.windowNumber] as CFArray,
                          [NSNumber(value: api.lockScreenSpace)] as CFArray)
        pin(window)
    }
}

/// Reports whether the frontmost thing on a display is fullscreen: a native fullscreen Space, or any
/// borderless window covering the whole display (games, video players). A window going fullscreen is
/// caught as its animation starts, when the window server makes its new Space; the switch to that
/// Space is only announced half a second later, as the animation ends.
final class FullscreenWatcher {
    private(set) var isFullscreen = false
    /// The display to watch.
    private let display: () -> NSScreen?
    private let onChange: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var pendingExit: DispatchWorkItem?
    /// The display's fullscreen Spaces as of the last look, to tell when a new one appears.
    private var knownFullscreenSpaces: Set<UInt64> = []

    init(display: @escaping () -> NSScreen?, onChange: @escaping (Bool) -> Void) {
        self.display = display
        self.onChange = onChange
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.recheckSoon()
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recheckSoon()
        })
        observers.append(NotificationCenter.default.addObserver(forName: DisplaySpaces.spacesWillChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            self?.spacesWillChange()
        })
        if let screen = display() { knownFullscreenSpaces = DisplaySpaces.fullscreenSpaces(on: screen) }
        // Borderless "fullscreen" windows don't switch Spaces, so also look now and then; listing
        // window bounds is cheap and needs no permission.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.recheck() }
        timer?.tolerance = 2   // let the system coalesce it with other wake-ups
        recheck()
    }

    func stop() {
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers.removeAll()
        timer?.invalidate()
        pendingExit?.cancel()
    }

    /// A window is starting to go fullscreen on this display if a fullscreen Space has just appeared
    /// for it: hide now, rather than when the switch is announced at the end of the animation.
    private func spacesWillChange() {
        guard let screen = display() else { return }
        let spaces = DisplaySpaces.fullscreenSpaces(on: screen)
        let appeared = !spaces.subtracting(knownFullscreenSpaces).isEmpty
        knownFullscreenSpaces = spaces
        guard appeared, !isFullscreen else { return }
        pendingExit?.cancel()
        pendingExit = nil
        isFullscreen = true
        Log.presence.info("fullscreen starting on \(screen.localizedName, privacy: .public)")
        onChange(true)
        // Confirm once the animation has finished (it can be cancelled).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.recheck() }
    }

    /// Space switches report before the new Space's windows are listed; look again once it lands.
    private func recheckSoon() {
        recheck()
        for delay in [0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.recheck() }
        }
    }

    /// Entering fullscreen applies at once. Leaving waits until fullscreen has stayed gone for a
    /// moment: mid-transition the window list briefly shows no fullscreen window, which would
    /// otherwise flash the notch back for a frame or two.
    private func recheck() {
        if let screen = display() { knownFullscreenSpaces = DisplaySpaces.fullscreenSpaces(on: screen) }
        if frontmostIsFullscreen() {
            pendingExit?.cancel()
            pendingExit = nil
            guard !isFullscreen else { return }
            isFullscreen = true
            Log.presence.info("fullscreen in front on \(self.display()?.localizedName ?? "?", privacy: .public)")
            onChange(true)
        } else if isFullscreen, pendingExit == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingExit = nil
                guard !self.frontmostIsFullscreen() else { return }
                self.isFullscreen = false
                Log.presence.info("fullscreen gone on \(self.display()?.localizedName ?? "?", privacy: .public)")
                self.onChange(false)
            }
            pendingExit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func frontmostIsFullscreen() -> Bool {
        guard let screen = display() else { return false }
        if DisplaySpaces.currentSpaceIsFullscreen(on: screen) { return true }
        guard let main = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        // Window bounds are in CoreGraphics coordinates: top-left origin on the main display.
        let display = CGRect(x: screen.frame.minX, y: main.frame.maxY - screen.frame.maxY,
                             width: screen.frame.width, height: screen.frame.height)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // System-owned windows that briefly cover the display during Space and Mission Control animations.
        let transient: Set<String> = ["Dock", "Window Server", "WindowManager"]
        return windows.contains { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != ownPID,
                  !transient.contains(info[kCGWindowOwnerName as String] as? String ?? ""),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return false }
            return bounds.insetBy(dx: 1, dy: 1).contains(display.insetBy(dx: 2, dy: 2))
                && bounds.width <= display.width + 2
        }
    }
}

/// Each display's Spaces, from the window server (looked up at runtime, like `NotchSpace`).
enum DisplaySpaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias Register = @convention(c) (Int32, Handler, UInt32, UnsafeMutableRawPointer?) -> Int32

    /// Posted on the main thread as Spaces start to change: when a window starts going fullscreen,
    /// its Space is made at this moment, half a second before the switch to it is announced.
    static let spacesWillChange = Notification.Name("ShimaSpacesWillChange")
    /// The window server's event for that (as measured on macOS 27).
    private static let spaceCreatedEvent: UInt32 = 1327

    private static let api: (connection: Int32, copy: CopySpaces)? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let connectionSymbol = dlsym(skyLight, "SLSMainConnectionID"),
              let copy = dlsym(skyLight, "SLSCopyManagedDisplaySpaces") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        if let register = dlsym(skyLight, "SLSRegisterConnectionNotifyProc") {
            let handler: Handler = { _, _, _, _ in
                NotificationCenter.default.post(name: DisplaySpaces.spacesWillChange, object: nil)
            }
            _ = unsafeBitCast(register, to: Register.self)(connection, handler, spaceCreatedEvent, nil)
        }
        return (connection, unsafeBitCast(copy, to: CopySpaces.self))
    }()

    private static func entry(for screen: NSScreen) -> [String: Any]? {
        guard let api, let displays = api.copy(api.connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        // With "Displays have separate Spaces" off there's a single entry for all of them.
        return displays.first { $0["Display Identifier"] as? String == screen.displayKey }
            ?? (displays.count == 1 ? displays.first : nil)
    }

    /// The display's current Space belongs to a fullscreen app.
    static func currentSpaceIsFullscreen(on screen: NSScreen) -> Bool {
        let current = entry(for: screen)?["Current Space"] as? [String: Any]
        return current?["type"] as? Int == fullscreenType
    }

    /// The display's fullscreen apps' Spaces.
    static func fullscreenSpaces(on screen: NSScreen) -> Set<UInt64> {
        let spaces = entry(for: screen)?["Spaces"] as? [[String: Any]] ?? []
        return Set(spaces.compactMap { space in
            space["type"] as? Int == fullscreenType ? (space["id64"] as? NSNumber)?.uint64Value : nil
        })
    }

    private static let fullscreenType = 4   // 0 is a desktop
}
