import AppKit
import CoreAudio
import SwiftUI

/// Borderless panel flush with the top-center of the main display, above the menu bar; only the
/// notch's own pixels take the pointer.
final class IslandPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Before the level: making a panel floating resets its level to the ordinary floating one.
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        // ignoresMouseEvents is deliberately never set: left alone, the window server lets clicks
        // and drags fall through the panel's transparent pixels and lands them on the notch itself.
        // Setting it (even back to false) switches that off, and with it drag-and-drop.
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// It sits over the menu bar on purpose; never let AppKit push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI notch and reports the pointer entering, moving over and leaving the notch's
/// current shape. Tracking only that region (rather than watching every mouse move on the Mac) means
/// Shima isn't woken by pointer movement anywhere else.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onPointer: (() -> Void)?
    /// The notch's current shape, in panel coordinates with a top-left origin.
    var hoverRect: CGRect = .zero {
        didSet { if hoverRect != oldValue { updateTrackingAreas() } }
    }
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let rect = isFlipped ? hoverRect
            : CGRect(x: hoverRect.minX, y: bounds.height - hoverRect.maxY, width: hoverRect.width, height: hoverRect.height)
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?()
    }
}

/// Owns the panel and turns the pointer, file drags and trackpad swipes into notch state.
final class IslandPanelController {
    private let panel = IslandPanel(size: Metrics.window)
    private let model: IslandModel
    private let media: MediaController
    private let shelf: ShelfStore
    private let calendar: CalendarMonitor
    private let timer: NotchTimer
    private var monitors: [Any] = []
    private weak var hostView: IslandHostingView<IslandRootView>?
    private var pollTimer: Timer?
    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var swipeDistance: CGFloat = 0
    private var swipeActive = false
    /// The current two-finger gesture turned out horizontal, so it's paging (not scrolling the shelf).
    private var swipePaging = false
    /// The swipe has passed the point where releasing changes page (felt once as a haptic tick).
    private var swipePastThreshold = false
    /// The current two-finger gesture began over the timer's ruler, so it sets the time instead.
    private var swipeSetsTimer = false
    private var hideDots: DispatchWorkItem?
    private let tracksPointer: Bool
    private let settings = AppSettings.shared
    /// The display this notch is on.
    let displayID: CGDirectDisplayID
    /// Something fullscreen is in front (whether or not Settings says to hide for it).
    private var fullscreenInFront = false
    private var fullscreenWatcher: FullscreenWatcher?
    private var systemObservers: [NSObjectProtocol] = []
    /// Hidden because something fullscreen is in front.
    private var isSuppressed = false
    private var isLocked = false
    /// The drag pasteboard's change count when the mouse went down; a change means a drag with content.
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    /// The current drag began inside the open notch (a file being dragged off the shelf).
    private var dragStartedInside = false
    /// Polls only while the mouse button is held, to spot file drags heading for the notch even when
    /// the dragging app keeps the drag events to itself.
    private var dragWatch: Timer?
    /// Files were just kept on the shelf by the drop that's finishing.
    private var justKept = false
    /// After keeping files the notch stays open on the shelf at least this long, as confirmation.
    private var holdOpenUntil = Date.distantPast

    private static let swipeThreshold: CGFloat = 70

    init(model: IslandModel, media: MediaController, outputs: AudioOutputController, shelf: ShelfStore,
         calendar: CalendarMonitor, timer: NotchTimer, displayID: CGDirectDisplayID = CGMainDisplayID(),
         tracksPointer: Bool = true) {
        self.displayID = displayID
        self.model = model
        self.media = media
        self.shelf = shelf
        self.tracksPointer = tracksPointer

        self.calendar = calendar
        self.timer = timer
        let host = IslandHostingView(rootView: IslandRootView(model: model, media: media, outputs: outputs,
                                                              shelf: shelf, calendar: calendar, timer: timer))
        host.sizingOptions = []
        host.onPointer = { [weak self] in self?.pointerMoved(dragging: false) }
        hostView = host
        host.frame = NSRect(origin: .zero, size: Metrics.window)
        host.autoresizingMask = [.width, .height]
        model.onDropFiles = { [weak self] urls, target in self?.receive(urls, on: target) }
        model.onNotificationAction = { [weak self] action in self?.handle(action) }
        model.onEjectDrive = { [weak self] in self?.ejectShownDrive() }
        replier.onText = { [weak self] text in self?.model.replyText = text }
        replier.onEnd = { [weak self] sent in self?.replyEnded(sent: sent) }
        panel.contentView = host

        place()
        panel.orderFrontRegardless()
        NotchSpace.pin(panel)
        // Its style can change in Settings.
        trackChanges { [weak self] in
            guard let self, let screen = self.screen else { return }
            _ = self.settings.preference(for: screen.displayKey)
            DispatchQueue.main.async { self.place() }
        }

        systemObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.place()
        })
        guard tracksPointer else { return }
        installPointerTracking()
        fullscreenWatcher = FullscreenWatcher(display: { [weak self] in self?.screen }) { [weak self] fullscreen in
            self?.fullscreenInFront = fullscreen
            self?.applyFullscreenSetting()
        }
        trackChanges { [weak self] in
            _ = self?.settings.hideInFullscreen
            DispatchQueue.main.async { self?.applyFullscreenSetting() }
        }

        // After sleep or the lock screen, make sure the notch is back in front and in its space.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.restore()
            })
        }
        let distributed = DistributedNotificationCenter.default()
        systemObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked()
        })
        systemObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenUnlocked()
        })
    }

    private var content: NotchContent { NotchContent.resolve(model: model, media: media, shelf: shelf, timer: timer) }

    // MARK: Battery

    /// Shows a battery event over the closed notch for a few seconds. Skipped while the notch is open,
    /// locked, hidden for a fullscreen app, or taking a drop.
    func showBatteryAlert(_ alert: BatteryAlert) {
        guard !model.isExpanded, !model.isDropping, !isSuppressed, model.lockPhase == .unlocked else { return }
        withAnimation(Motion.compact) { model.batteryAlert = alert }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.model.batteryAlert?.id == alert.id else { return }
            withAnimation(Motion.close) { self.model.batteryAlert = nil }
        }
    }

    // MARK: Status and drives

    /// Shows a quick status (Caps Lock) for a moment; a newer one replaces it.
    func showStatus(_ alert: StatusAlert) {
        guard !model.isExpanded, !model.isDropping, !isSuppressed, model.lockPhase == .unlocked,
              model.notification == nil else { return }
        withAnimation(model.statusAlert == nil ? Motion.compact : .snappy(duration: 0.25)) { model.statusAlert = alert }
        Log.activity.info("status shown: \(alert.state, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.model.statusAlert?.id == alert.id else { return }
            withAnimation(Motion.close) { self.model.statusAlert = nil }
        }
    }

    private var driveDismissal: DispatchWorkItem?
    /// Ejects through the drive monitor; set by the app.
    var ejectDrive: ((DriveAlert, @escaping (Bool) -> Void) -> Void)?

    /// Shows a drive that connected (with Eject) or was ejected. It stays under the pointer.
    func showDrive(_ drive: DriveAlert) {
        guard !model.isExpanded, !model.isDropping, !isSuppressed, model.lockPhase == .unlocked,
              model.notification == nil else { return }
        withAnimation(Motion.compact) { model.driveAlert = drive }
        Log.activity.info("drive banner: \(String(describing: drive.phase), privacy: .public)")
        dismissDrive(after: drive.phase == .connected ? 4 : 2.5)
        if ProcessInfo.processInfo.environment["SHIMA_DEMO_DRIVES"] != nil, drive.phase == .connected {
            // For testing without clicking: press Eject a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.ejectShownDrive() }
        }
    }

    private func dismissDrive(after delay: TimeInterval) {
        driveDismissal?.cancel()
        schedule(&driveDismissal, after: delay) { [weak self] in
            withAnimation(Motion.close) { self?.model.driveAlert = nil }
        }
    }

    private func ejectShownDrive() {
        guard let drive = model.driveAlert, drive.phase == .connected || drive.phase == .inUse else { return }
        driveDismissal?.cancel()
        model.driveAlert?.phase = .ejecting
        ejectDrive?(drive) { [weak self] done in
            guard let self, self.model.driveAlert?.id == drive.id else { return }
            self.model.driveAlert?.phase = done ? .ejected : .inUse
            self.dismissDrive(after: done ? 1.8 : 3)
        }
    }

    // MARK: Notifications

    /// A notification stays this long, and a little longer after the pointer leaves it.
    private static let notificationDuration: TimeInterval = 5
    private var notificationDismissal: DispatchWorkItem?
    private let replier = NotificationReplier()

    /// Shows a notification below the notch, unless the notch is busy (open, taking a drop, locked,
    /// hidden for a fullscreen app, or you're replying to another); then macOS shows its own banner.
    func showNotification(_ notification: NotchNotification) -> Bool {
        guard !model.isExpanded, !model.isDropping, !isSuppressed, model.lockPhase == .unlocked,
              !replier.isActive else { return false }
        pendingExpand?.cancel()
        pendingExpand = nil
        withAnimation(model.notification == nil ? Motion.compact : .snappy(duration: 0.35)) {
            model.notification = notification
        }
        dismissNotification(after: Self.notificationDuration)
        if let text = ProcessInfo.processInfo.environment["SHIMA_DEMO_REPLY"], notification.canReply {
            // For testing replies without typing: reply on its own, then type and press Return.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.handle(.reply) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.replier.debugType(text) }
        }
        return true
    }

    private func dismissNotification(after delay: TimeInterval) {
        notificationDismissal?.cancel()
        schedule(&notificationDismissal, after: delay) { [weak self] in
            withAnimation(Motion.close) { self?.clearNotification() }
        }
    }

    private func clearNotification() {
        if replier.isActive { replier.cancel() }
        model.notification = nil
        model.replyPhase = .none
        model.replyText = ""
    }

    private func handle(_ action: NotificationAction) {
        guard let notification = model.notification else { return }
        switch action {
        case .open:
            notificationDismissal?.cancel()
            notification.open()
            withAnimation(Motion.close) { clearNotification() }
        case .reply:
            notificationDismissal?.cancel()
            notificationDismissal = nil
            model.replyText = ""
            withAnimation(.snappy(duration: 0.35)) { model.replyPhase = .typing }
            replier.begin(notification) { [weak self] ready in
                guard let self, !ready else { return }
                // No reply box after all: open the conversation instead.
                notification.open()
                withAnimation(Motion.close) { self.clearNotification() }
            }
        case .send:
            replier.send()
        }
    }

    private func replyEnded(sent: Bool) {
        guard model.notification != nil else { return }
        if sent {
            withAnimation(.snappy(duration: 0.3)) { model.replyPhase = .sent }
            dismissNotification(after: 1.2)
        } else {
            withAnimation(.snappy(duration: 0.35)) {
                model.replyPhase = .none
                model.replyText = ""
            }
            dismissNotification(after: 2)
        }
    }

    // MARK: Connected devices

    /// Shows headphones or a speaker that just connected, then fills in their battery level as soon
    /// as the system has it (AirPods report it a moment after connecting).
    func showDeviceAlert(_ device: AudioOutputDevice) {
        guard canShowDeviceAlert else { return }
        let alert = DeviceAlert(symbol: device.symbol, name: device.shortName, awaitingBattery: device.isBluetooth)
        guard device.isBluetooth else { return present(alert, of: device) }
        // Wait a moment for the product's spinning video and battery, so the banner opens complete
        // rather than swapping its art in after.
        var presented = false
        let presentOnce = { [weak self] (found: BluetoothInfo.Device?, spin: URL?) in
            guard !presented, let self, self.canShowDeviceAlert else { return }
            presented = true
            var alert = alert
            alert.spin = spin
            if let level = found?.level { alert.battery = level; alert.awaitingBattery = false }
            self.present(alert, of: device)
        }
        BluetoothInfo.lookup(address: device.bluetoothAddress, name: device.name) { presentOnce($0, $1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { presentOnce(nil, nil) }
    }

    /// For trying the activity without connecting anything. SHIMA_DEMO_DEVICE=<product ID, e.g. 0x2024>
    /// shows that product; SHIMA_DEMO_DEVICE=<the name of connected headphones> goes through the same
    /// lookup as a real connection.
    func showDemoDevice(_ demo: String) {
        guard let productID = BluetoothInfo.hex(demo) else {
            return showDeviceAlert(AudioOutputDevice(id: 0, name: demo, transport: kAudioDeviceTransportTypeBluetooth, uid: nil))
        }
        let device = AudioOutputDevice(id: 0, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth, uid: nil)
        var alert = DeviceAlert(symbol: device.symbol, name: device.shortName, battery: 85)
        alert.spin = ProductSpin.url(productID: productID)
        present(alert, of: device)
    }

    private var canShowDeviceAlert: Bool {
        !model.isExpanded && !model.isDropping && !isSuppressed && model.lockPhase == .unlocked
    }

    private func present(_ alert: DeviceAlert, of device: AudioOutputDevice) {
        withAnimation(Motion.compact) { model.deviceAlert = alert }
        let steps: [(TimeInterval, () -> Void)] = [
            (0.35, { self.model.deviceAlert?.bounces += 1 }),
            (2.6, { withAnimation(Motion.compact) { self.model.deviceAlert?.isBanner = false } }),
            (4.8, { withAnimation(Motion.close) { self.model.deviceAlert = nil } }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.model.deviceAlert?.id == alert.id else { return }
                step()
            }
        }
        guard alert.awaitingBattery || (device.isBluetooth && alert.spin == nil) else { return }
        fillIn(device, alert: alert, retries: 2)
    }

    /// Fills in what wasn't known when the banner opened: the battery level and the spinning video.
    private func fillIn(_ device: AudioOutputDevice, alert: DeviceAlert, retries: Int) {
        BluetoothInfo.lookup(address: device.bluetoothAddress, name: device.name) { [weak self] found, spin in
            guard let self, self.model.deviceAlert?.id == alert.id else { return }
            if self.model.deviceAlert?.spin == nil, let spin {
                withAnimation(.easeOut(duration: 0.25)) { self.model.deviceAlert?.spin = spin }
            }
            if let level = found?.level {
                withAnimation(.snappy(duration: 0.3)) {
                    self.model.deviceAlert?.battery = level
                    self.model.deviceAlert?.awaitingBattery = false
                }
            } else if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.fillIn(device, alert: alert, retries: retries - 1)
                }
            } else {
                withAnimation(.snappy(duration: 0.3)) { self.model.deviceAlert?.awaitingBattery = false }
            }
        }
    }

    // MARK: Lock screen

    /// Widens with an open padlock, then snaps the shackle shut, like the iPhone's Dynamic Island.
    /// With "Show on the lock screen" off, the notch simply fades away until unlock.
    func screenLocked() {
        isLocked = true
        endDropMode()
        setExpanded(false)
        guard settings.showOnLockScreen else {
            fade(visible: false)
            return
        }
        restore()
        panel.alphaValue = 1   // shown over the lock screen even if a fullscreen app was in front
        withAnimation(Motion.open) { model.lockPhase = .locking }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isLocked else { return }
            withAnimation(.snappy) { self.model.lockPhase = .locked }
        }
    }

    /// Springs the shackle open, holds a beat, then returns to the normal notch.
    func screenUnlocked() {
        guard isLocked else {
            restore()
            return
        }
        isLocked = false
        restore()
        guard model.lockPhase != .unlocked else { return }
        withAnimation(.snappy) { model.lockPhase = .unlocking }
        // Leave the lock screen's space just after it's gone, so nothing flickers on the way out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isLocked else { return }
            NotchSpace.lowerFromLockScreen(self.panel)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !self.isLocked else { return }
            withAnimation(Motion.close) { self.model.lockPhase = .unlocked }
            if self.isSuppressed { self.fade(visible: false) }
        }
    }

    private func restore() {
        place()
        panel.orderFrontRegardless()
        if isLocked && settings.showOnLockScreen {
            NotchSpace.raiseOverLockScreen(panel)
        } else {
            NotchSpace.pin(panel)
        }
        if !isLocked && !isSuppressed && panel.alphaValue < 1 { fade(visible: true) }
    }

    private func applyFullscreenSetting() {
        setSuppressed(fullscreenInFront && settings.hideInFullscreen)
    }

    /// Fades the notch away while a fullscreen app is in front, and back when it leaves.
    private func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        if suppressed {
            endDropMode()
            setExpanded(false)
        }
        guard model.lockPhase == .unlocked else { return }   // the lock screen always shows it
        fade(visible: !suppressed)
    }

    private func fade(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.25 : 0.12
            panel.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// The display's screen, while it's connected.
    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    /// At the top center of its display, measured for that display.
    private func place() {
        guard let screen else { return }
        let geometry = NotchGeometry(screen: screen)
        if model.geometry != geometry { model.geometry = geometry }
        let frame = screen.frame
        panel.setFrame(NSRect(x: frame.midX - Metrics.window.width / 2,
                              y: frame.maxY - Metrics.window.height,
                              width: Metrics.window.width, height: Metrics.window.height),
                       display: true)
    }

    // MARK: Pointer

    /// Takes the notch down for good, when its display goes away or Settings no longer shows it there.
    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        for observer in systemObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        systemObservers.removeAll()
        fullscreenWatcher?.stop()
        fullscreenWatcher = nil
        pollTimer?.invalidate()
        dragWatch?.invalidate()
        if replier.isActive { replier.cancel() }
        [pendingExpand, pendingCollapse, hideDots, notificationDismissal, driveDismissal].forEach { $0?.cancel() }
        panel.orderOut(nil)
        panel.close()
    }

    /// Hover comes from the hosting view's tracking area, kept on the notch's current shape. Clicks
    /// are watched (cheaply, only on press) to spot file drags starting elsewhere.
    private func installPointerTracking() {
        trackChanges { [weak self] in
            guard let self else { return }
            self.hostView?.hoverRect = self.content.spec(in: model.geometry).bodyRect
        }
        let downs: NSEvent.EventTypeMask = [.leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: downs, handler: { [weak self] _ in
            self?.mouseWentDown(inside: false)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: downs, handler: { [weak self] event in
            self?.mouseWentDown(inside: true)
            return event
        }) { monitors.append(local) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleScroll(event)
        }) { monitors.append(scroll) }
    }

    /// While open or taking a drop, also poll: the pointer can leave through a menu bar item where
    /// no move events reach us, and a drag ends without one. Closed, nothing ticks in the background.
    private func updatePolling() {
        let needed = model.isExpanded || model.isDropping
        if needed, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.pointerMoved(dragging: false)
            }
            pollTimer?.tolerance = 0.05
        } else if !needed {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Pointer location in panel coordinates with a top-left origin, matching SwiftUI's.
    private var pointer: CGPoint {
        let location = NSEvent.mouseLocation
        let frame = panel.frame
        return CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y)
    }

    private var mouseIsDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    private func mouseWentDown(inside: Bool) {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        dragStartedInside = inside
        // A click on a notification opens it; a click on the closed notch opens the notch (the only
        // way in, with hover-to-open turned off).
        if inside, !model.isExpanded, !isSuppressed, model.lockPhase == .unlocked,
           content.spec(in: model.geometry).bodyRect.contains(pointer) {
            // A notification handles its own clicks (open, Reply, send).
            if ![.notification, .notificationReply, .drive].contains(content) { setExpanded(true) }
        }
        guard !inside, dragWatch == nil else { return }
        dragWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self, self.mouseIsDown else {
                timer.invalidate()
                self?.dragWatch = nil
                self?.pointerMoved(dragging: false)
                return
            }
            self.pointerMoved(dragging: true)
        }
    }

    private func pointerMoved(dragging: Bool) {
        guard tracksPointer else { return }
        guard !isSuppressed, model.lockPhase == .unlocked else { return }
        if dragging, !dragStartedInside, settings.shelfEnabled, isDraggingFiles { fileDragMoved() }
        if model.isDropping {
            if !mouseIsDown { finishDrop() }
            return
        }

        let point = pointer
        let body = content.spec(in: model.geometry).bodyRect
        if model.isExpanded {
            let overNotch = body.contains(point)
            let local = CGPoint(x: point.x - body.minX, y: point.y - body.minY)
            if model.pointer != (overNotch ? local : nil) { model.pointer = overNotch ? local : nil }
            // Stays open while the mouse is held (dragging a file off the shelf, or scrubbing), and
            // briefly after files are kept.
            if body.insetBy(dx: -10, dy: -10).contains(point) || mouseIsDown || Date() < holdOpenUntil {
                pendingCollapse?.cancel()
                pendingCollapse = nil
            } else if pendingCollapse == nil {
                schedule(&pendingCollapse, after: 0.25) { [weak self] in self?.setExpanded(false) }
            }
        } else if content == .drive {
            // Under the pointer a drive banner stays; it goes a moment after the pointer leaves.
            let over = body.insetBy(dx: -4, dy: -4).contains(point)
            if over, driveDismissal != nil {
                driveDismissal?.cancel()
                driveDismissal = nil
            } else if !over, driveDismissal == nil, model.driveAlert?.phase != .ejecting {
                dismissDrive(after: 2)
            }
        } else if content == .notification || content == .notificationReply {
            // Under the pointer a notification stays (and a chat grows its reply box); it goes a moment
            // after the pointer leaves. While you're replying it stays regardless.
            let over = body.insetBy(dx: -4, dy: -4).contains(point)
            let local = CGPoint(x: point.x - body.minX, y: point.y - body.minY)
            if (model.pointer != nil) != over {
                withAnimation(.snappy(duration: 0.3)) { model.pointer = over ? local : nil }
            } else if over, model.pointer != local {
                model.pointer = local
            }
            if model.replyPhase != .none { return }
            if over, notificationDismissal != nil {
                notificationDismissal?.cancel()
                notificationDismissal = nil
            } else if !over, notificationDismissal == nil {
                dismissNotification(after: 2)
            }
        } else {
            if model.pointer != nil { model.pointer = nil }
            let overNotch = body.insetBy(dx: -4, dy: -4).contains(point)
            if overNotch && !mouseIsDown {
                if pendingExpand == nil {
                    if settings.openOnHover {
                        schedule(&pendingExpand, after: settings.hoverDelay.seconds) { [weak self] in
                            self?.setExpanded(true)
                        }
                    }
                }
            } else {
                pendingExpand?.cancel()
                pendingExpand = nil
            }
        }
    }

    private func schedule(_ slot: inout DispatchWorkItem?, after delay: TimeInterval, _ action: @escaping () -> Void) {
        let work = DispatchWorkItem(block: action)
        slot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setExpanded(_ expanded: Bool) {
        pendingExpand = nil
        pendingCollapse = nil
        guard model.isExpanded != expanded, expanded ? !isSuppressed : !model.isMenuOpen else { return }
        if expanded {
            model.batteryAlert = nil
            model.deviceAlert = nil
            model.statusAlert = nil
            model.driveAlert = nil
            clearNotification()
        }
        // Open on what's relevant: the player while something is loaded, otherwise the shelf if it has files.
        if expanded {
            model.section = pageToOpen()
            flashPageDots(for: 1.2)
        } else {
            model.pageDotsVisible = false
        }
        withAnimation(expanded ? Motion.open : Motion.close) {
            model.isExpanded = expanded
        }
        if expanded && settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        updatePolling()
        pointerMoved(dragging: false)
    }

    // MARK: File drops

    /// A drag with file URLs has started somewhere since the mouse went down.
    private var isDraggingFiles: Bool {
        let pasteboard = NSPasteboard(name: .drag)
        return pasteboard.changeCount != dragChangeCount
            && pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Opens the drop targets as a file drag nears the notch, and puts them away if it moves off.
    private func fileDragMoved() {
        let point = pointer
        let drop = model.geometry.drop.bodyRect
        let approach = CGRect(x: drop.minX - 24, y: 0, width: drop.width + 48, height: model.geometry.closedHeight + 48)
        if !model.isDropping, approach.contains(point) {
            pendingExpand?.cancel()
            pendingExpand = nil
            Log.drag.notice("file drag reached the notch: showing drop targets")
            withAnimation(Motion.open) {
                model.isExpanded = false
                model.isDropping = true
            }
            updatePolling()
        } else if model.isDropping, !drop.insetBy(dx: -32, dy: -32).contains(point) {
            Log.drag.notice("file drag left the notch")
            endDropMode()
        }
    }

    private func receive(_ urls: [URL], on target: DropTarget) {
        Log.drag.notice("received \(urls.count) file(s) for \(String(describing: target), privacy: .public)")
        switch target {
        case .shelf:
            withAnimation(Motion.compact) { shelf.add(urls) }
            model.section = .shelf
            holdOpenUntil = Date() + 1.2
            if model.isDropping {
                justKept = true   // finishDrop opens on the shelf
            } else {
                setExpanded(true)
                model.section = .shelf
            }
        case .airDrop:
            // After the drag session unwinds, so the AirDrop sheet isn't fighting it for focus.
            DispatchQueue.main.async { FileActions.airDrop(urls) }
        }
        model.dropTarget = nil
    }

    /// The drag ended (dropped or released elsewhere). After keeping files, the notch opens briefly
    /// on the shelf as confirmation; pointer tracking closes it as usual once the pointer leaves.
    private func finishDrop() {
        endDropMode(showShelf: justKept)
        justKept = false
    }

    private func endDropMode(showShelf: Bool = false) {
        guard model.isDropping else { return }
        Log.drag.notice("drop targets closing (kept: \(showShelf))")
        if showShelf { model.section = .shelf }
        withAnimation(showShelf ? Motion.open : Motion.close) {
            model.isDropping = false
            model.dropTarget = nil
            model.isExpanded = showShelf
        }
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        updatePolling()
        pointerMoved(dragging: false)
    }

    // MARK: Pages

    private var pages: [NotchSection] { NotchSection.available(calendarAccess: calendar.hasAccess) }

    /// Opens on what's relevant: a timer that just finished, the player while music plays, the
    /// calendar while an event is about to start, a running timer, otherwise the page last looked at.
    private func pageToOpen() -> NotchSection {
        let pages = self.pages
        if timer.state == .finished, pages.contains(.timer) { return .timer }
        if media.isPlaying { return .player }
        if model.upcomingEvent != nil, pages.contains(.calendar) { return .calendar }
        if timer.isActive, pages.contains(.timer) { return .timer }
        return pages.contains(model.section) ? model.section : .player
    }

    /// Two-finger horizontal swipes move between pages, which follow the fingers and rubber-band at
    /// the ends; vertical scrolls pass through (the shelf's grid scrolls vertically). Over the
    /// timer's ruler, scrolling slides the ruler instead.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard content == .open else { return event }
        if event.momentumPhase != [] { return swipePaging || swipeSetsTimer ? nil : event }
        if event.phase == [], isOverTimerRuler {
            // A mouse wheel: a minute per notch.
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0 else { return nil }
            timer.movePicker(by: (delta > 0) != event.isDirectionInvertedFromDevice ? -1 : 1)
            timer.settlePicker()
            Haptics.tick()
            return nil
        }

        switch event.phase {
        case .began:
            swipeDistance = 0
            swipeActive = true
            swipePaging = false
            swipePastThreshold = false
            swipeSetsTimer = isOverTimerRuler
            return swipeSetsTimer ? nil : event
        case .changed where swipeSetsTimer:
            // The ruler follows the fingers, like dragging it.
            let fingerDelta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let before = timer.pickedMinutes
            timer.movePicker(by: -Double(fingerDelta / TimerRuler.spacing))
            if timer.pickedMinutes != before { Haptics.tick() }
            return nil
        case .ended where swipeSetsTimer, .cancelled where swipeSetsTimer:
            swipeActive = false
            withAnimation(.snappy(duration: 0.3)) { timer.settlePicker() }
            return nil
        case .changed where swipeActive:
            if !swipePaging {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 0.5 else {
                    return event
                }
                swipePaging = true
                showPageDots()
            }
            // Follow the fingers whichever way the user's scroll direction is set.
            let fingerDelta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            swipeDistance += fingerDelta
            model.pageDrag = pageDrag(for: swipeDistance)
            let past = abs(swipeDistance) >= Self.swipeThreshold && target(for: swipeDistance) != nil
            if past != swipePastThreshold {
                swipePastThreshold = past
                if past && settings.haptics {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            return nil
        case .ended, .cancelled:
            guard swipeActive else { return event }
            swipeActive = false
            guard swipePaging else { return event }
            let destination = abs(swipeDistance) >= Self.swipeThreshold ? target(for: swipeDistance) : nil
            withAnimation(.snappy(duration: 0.42)) {
                if let destination { model.section = destination }
                model.pageDrag = 0
            }
            flashPageDots(for: 0.9)
            return nil
        default:
            return event
        }
    }

    /// The pointer is over the timer's ruler, on the Timer page with no timer set.
    private var isOverTimerRuler: Bool {
        guard model.section == .timer, timer.state == .idle, let pointer = model.pointer else { return false }
        return Metrics.timerRuler.offsetBy(dx: Metrics.padding, dy: model.geometry.contentTop).contains(pointer)
    }

    /// Shows the page dots until told otherwise (while a swipe is in progress).
    private func showPageDots() {
        hideDots?.cancel()
        hideDots = nil
        guard !model.pageDotsVisible else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.pageDotsVisible = true }
    }

    /// Shows the page dots, then fades them out after a moment.
    private func flashPageDots(for seconds: TimeInterval) {
        showPageDots()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.4)) { self?.model.pageDotsVisible = false }
        }
        hideDots = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The page a swipe of this distance leads to, if there is one that way.
    private func target(for distance: CGFloat) -> NotchSection? {
        let pages = self.pages
        guard let index = pages.firstIndex(of: model.section) else { return nil }
        let next = distance < 0 ? index + 1 : index - 1
        return pages.indices.contains(next) ? pages[next] : nil
    }

    /// Pages track the fingers one-to-one towards a neighbor, and resist past the first or last page.
    private func pageDrag(for distance: CGFloat) -> CGFloat {
        if target(for: distance) == nil { return 40 * tanh(distance / 160) }
        return max(-Metrics.openWidth, min(Metrics.openWidth, distance))
    }
}

extension IslandPanelController {
    /// The panel's current contents, mid-animation included; for the debug filmstrip.
    func captureFrame() -> NSBitmapImageRep? {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Whether the window server lists the panel as on screen; for the debug filmstrip.
    var isOnScreen: Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Logs whether the window server lists the panel as on screen; for the debug filmstrip.
    func logOnScreen(_ label: String) {
        NSLog("%@: on screen %d", label, isOnScreen)
    }

    /// Which views in the panel accept which dragged types; for the debug filmstrip.
    func dragRegistrationReport() -> String {
        var lines: [String] = []
        func visit(_ view: NSView, depth: Int) {
            if !view.registeredDraggedTypes.isEmpty {
                let types = view.registeredDraggedTypes.map(\.rawValue).joined(separator: ",")
                lines.append("\(String(repeating: " ", count: depth))\(type(of: view)) \(view.frame) [\(types)]")
            }
            view.subviews.forEach { visit($0, depth: depth + 1) }
        }
        if let root = panel.contentView { visit(root, depth: 0) }
        return lines.isEmpty ? "none" : lines.joined(separator: "\n")
    }

    /// Drags the pages as a two-finger swipe would; for the debug filmstrip.
    func simulatePageDrag(_ distance: CGFloat) {
        swipeDistance = distance
        model.pageDrag = pageDrag(for: distance)
    }

    /// Releases a simulated swipe; for the debug filmstrip.
    func simulatePageRelease() {
        let destination = abs(swipeDistance) >= Self.swipeThreshold ? target(for: swipeDistance) : nil
        withAnimation(.snappy(duration: 0.42)) {
            if let destination { model.section = destination }
            model.pageDrag = 0
        }
    }

    /// Opens the notch on a section; for the debug filmstrip.
    func showSection(_ section: NotchSection) {
        withAnimation(Motion.open) {
            model.isExpanded = true
            model.section = section
        }
    }

    /// Puts the notch in its drop state as if files were being dragged to it; for the debug filmstrip.
    func showDropTargets(hovering target: DropTarget?) {
        withAnimation(Motion.open) {
            model.isDropping = true
            model.dropTarget = target
        }
    }
}
