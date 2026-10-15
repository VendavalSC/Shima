import SwiftUI

/// Debug aid: `SHIMA_SNAPSHOT=<dir> Shima` renders every notch state at 2x to PNGs and exits.
@MainActor
enum Snapshot {
    private struct State {
        var name: String
        var playing = true
        var shelf = false
        var expanded = false
        var lock: LockPhase = .unlocked
        var dropping = false
        var dropTarget: DropTarget?
        var hover: CGPoint?
        var section: NotchSection = .player
        var battery: BatteryAlert?
        var device: DeviceAlert?
        var notification: NotchNotification?
        var status: StatusAlert?
        var drive: DriveAlert?
        var reply: ReplyPhase = .none
        var replyText = ""
        var event: UpcomingEvent?
    }

    static func runIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["SHIMA_SNAPSHOT"] else { return false }
        // Run from the build folder (not the app bundle), these settings live in their own defaults domain.
        AppSettings.shared.calendarPage = true
        AppSettings.shared.shelfEnabled = true
        AppSettings.shared.timerPage = true
        AppSettings.shared.systemPage = true
        let pad = Metrics.padding
        let chat = NotchNotification(id: "3", app: "Messages", title: "Alex Morgan", subtitle: "",
                                     body: "Nachos at seven? I'll bring the cheese.", banner: AXUIElementCreateSystemWide(),
                                     replyAction: "Name:Reply")
        let states = [
            State(name: "idle", playing: false),
            State(name: "music"),
            State(name: "shelf", playing: false, shelf: true),
            State(name: "locked", lock: .locked),
            State(name: "event", event: UpcomingEvent(id: "1", title: "Design review", start: Date().addingTimeInterval(8 * 60 - 1), color: .orange)),
            State(name: "event-now", playing: false, event: UpcomingEvent(id: "2", title: "Weekly sync with the team", start: Date().addingTimeInterval(-30), color: .blue)),
            State(name: "charging", battery: BatteryAlert(kind: .charging, level: 82, isCharging: true)),
            State(name: "low-battery", playing: false, battery: BatteryAlert(kind: .low, level: 10, isCharging: false)),
            State(name: "unlocking", lock: .unlocking),
            State(name: "open-player", expanded: true),
            State(name: "open-player-hover", expanded: true,
                  hover: CGPoint(x: pad + Metrics.openWidth / 2 - pad + Metrics.skipOffset, y: pad + Metrics.controlsCenterY)),
            State(name: "open-scrubbing", expanded: true, hover: CGPoint(x: 120, y: pad + Metrics.scrubberCenterY)),
            State(name: "open-player-with-shelf", shelf: true, expanded: true),
            State(name: "open-calendar", shelf: true, expanded: true, section: .calendar),
            State(name: "swipe-mid", shelf: true, expanded: true),
            State(name: "timer-idle", expanded: true, section: .timer),
            State(name: "timer-idle-long", expanded: true, section: .timer),
            State(name: "timer-idle-sliding", expanded: true, section: .timer),
            State(name: "timer-running", expanded: true, section: .timer),
            State(name: "timer-paused", expanded: true, section: .timer),
            State(name: "timer-compact"),
            State(name: "notification", notification: NotchNotification(
                id: "1", app: "Messages", title: "Alex Morgan", subtitle: "",
                body: "Nachos at seven? I'll bring the cheese, you bring the playlist.", banner: AXUIElementCreateSystemWide())),
            State(name: "notification-hover", hover: CGPoint(x: 200, y: 30), notification: chat),
            State(name: "notification-reply-empty", notification: chat, reply: .typing),
            State(name: "notification-not-chat-hover", hover: CGPoint(x: 200, y: 30), notification: NotchNotification(
                id: "4", app: "Calendar", title: "Design review", subtitle: "", body: "Starts in 5 minutes",
                banner: AXUIElementCreateSystemWide())),
            State(name: "notification-reply", notification: chat, reply: .typing, replyText: "Count me in! See you at 7."),
            State(name: "notification-sent", notification: chat, reply: .sent, replyText: "Count me in! See you at 7."),
            State(name: "notification-subtitle", notification: NotchNotification(
                id: "2", app: "Calendar", title: "Design review", subtitle: "Today at 3:00 PM",
                body: "Studio B · with Sam and Priya", banner: AXUIElementCreateSystemWide())),
            State(name: "caps-on", status: StatusAlert(symbol: "capslock.fill", title: "Caps Lock", state: "On", isOn: true)),
            State(name: "focus-on", status: StatusAlert(symbol: "moon.fill", title: "Do Not Disturb", state: "On", isOn: true,
                                                        tint: .indigo)),
            State(name: "focus-work", status: StatusAlert(symbol: "briefcase.fill", title: "Work", state: "On", isOn: true,
                                                          tint: .orange)),
            State(name: "caps-off", status: StatusAlert(symbol: "capslock", title: "Caps Lock", state: "Off", isOn: false)),
            State(name: "drive-connected", drive: DriveAlert(name: "Photos Backup", url: URL(fileURLWithPath: "/Volumes/X"),
                                                             symbol: "externaldrive.fill", phase: .connected)),
            State(name: "drive-ejected", drive: DriveAlert(name: "Photos Backup", url: URL(fileURLWithPath: "/Volumes/X"),
                                                           symbol: "externaldrive.fill", phase: .ejected)),
            State(name: "drive-in-use", drive: DriveAlert(name: "UNTITLED", url: URL(fileURLWithPath: "/Volumes/X"),
                                                          symbol: "sdcard.fill", phase: .inUse)),
            State(name: "device-banner", device: DeviceAlert(symbol: "airpodspro", name: "AirPods Pro", battery: 85)),
            State(name: "device-banner-waiting", device: DeviceAlert(symbol: "airpodspro", name: "AirPods Pro",
                                                                     awaitingBattery: true)),
            State(name: "device-banner-low", device: DeviceAlert(symbol: "airpods", name: "AirPods", battery: 15)),
            State(name: "device-banner-speaker", device: DeviceAlert(symbol: "hifispeaker", name: "Kitchen")),
            State(name: "device-compact", device: DeviceAlert(symbol: "airpodspro", name: "AirPods Pro", battery: 85,
                                                              isBanner: false)),
            State(name: "system", expanded: true, section: .system),
            State(name: "open-shelf", playing: false, shelf: true, expanded: true, section: .shelf),
            State(name: "open-shelf-empty", playing: false, expanded: true, section: .shelf),
            State(name: "open-nothing", playing: false, expanded: true),
            State(name: "drop", dropping: true),
            State(name: "drop-shelf", dropping: true, dropTarget: .shelf),
        ]
        // The same states as an island, for a few that show its shape.
        let islandStates: Set = ["idle", "music", "charging", "open-player", "notification-hover", "device-banner", "drop"]
        let runs = [(NotchStyle.notch, states)] + [(NotchStyle.island, states.filter { islandStates.contains($0.name) }.map {
            var island = $0
            island.name = "island-" + $0.name
            return island
        })]
        for (style, states) in runs {
        AppSettings.shared.notchStyle = style
        for state in states {
            let noMedia = ["idle", "shelf", "open-shelf", "open-shelf-empty", "open-nothing"]
                .contains(state.name.replacingOccurrences(of: "island-", with: ""))
            let media = noMedia ? MediaController() : MediaController.sample(playing: state.playing)
            let shelf = ShelfStore(persists: false)
            if state.shelf { shelf.add(sampleFiles()) }
            let model = IslandModel()
            model.isExpanded = state.expanded
            model.lockPhase = state.lock
            model.isDropping = state.dropping
            model.dropTarget = state.dropTarget
            model.pointer = state.hover
            model.section = state.section
            model.batteryAlert = state.battery
            model.deviceAlert = state.device
            model.notification = state.notification
            model.statusAlert = state.status
            model.driveAlert = state.drive
            model.replyPhase = state.reply
            model.replyText = state.replyText
            model.upcomingEvent = state.event
            let calendar = CalendarMonitor()
            if state.section == .calendar || state.name.hasPrefix("swipe") {
                calendar.loadSample(today: Snapshot.sampleEvents(), tomorrow: nil)
            }
            model.pageDrag = state.name == "swipe-mid" ? -150 : 0
            model.pageDotsVisible = state.name == "swipe-mid"
            let timer = NotchTimer()
            timer.pickerMinutes = ["timer-idle-long": 90, "timer-idle-sliding": 12.4][state.name] ?? 25
            if state.name.hasPrefix("timer-running") || state.name == "timer-compact" { timer.start(minutes: 5) }
            if state.name == "timer-paused" { timer.start(minutes: 5); timer.pause() }
            let view = IslandRootView(model: model, media: media, outputs: AudioOutputController(), shelf: shelf,
                                      calendar: calendar, timer: timer)
                .frame(width: Metrics.window.width, height: Metrics.window.height)
                // With SHIMA_SIMULATE_NOTCH, the camera housing in red: nothing should hide under it.
                .overlay(alignment: .top) {
                    if NotchGeometry.simulatesCameraHousing {
                        Rectangle().fill(Color.red.opacity(0.6))
                            .frame(width: NotchGeometry.simulatedHousing.width, height: NotchGeometry.simulatedHousing.height)
                    }
                }
                .background(Color(red: 0.36, green: 0.42, blue: 0.52))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                NSLog("snapshot \(state.name): render failed")
                continue
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(state.name).png")
            do {
                try png.write(to: url)
                NSLog("snapshot \(state.name): \(url.path)")
            } catch {
                NSLog("snapshot \(state.name): \(error.localizedDescription)")
            }
        }
        }
        AppSettings.shared.notchStyle = .notch
        return true
    }

    static func sampleEvents() -> [CalendarEntry] {
        let now = Date()
        return [
            CalendarEntry(id: "a", title: "Design review", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1800),
                          isAllDay: false, color: .orange),
            CalendarEntry(id: "b", title: "Lunch with Sam", start: now.addingTimeInterval(5400), end: now.addingTimeInterval(9000),
                          isAllDay: false, color: .green),
            CalendarEntry(id: "c", title: "Weekly sync", start: now.addingTimeInterval(14400), end: now.addingTimeInterval(16200),
                          isAllDay: false, color: .blue),
            CalendarEntry(id: "d", title: "Gym", start: now.addingTimeInterval(20000), end: now.addingTimeInterval(23600),
                          isAllDay: false, color: .purple),
        ]
    }

    /// A few real files of different kinds for the shelf, written to a temporary folder.
    static func sampleFiles() -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShimaSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemPink])?.draw(in: rect, angle: -60)
            return true
        }
        let photo = folder.appendingPathComponent("Sunset.png")
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: photo)
            urls.append(photo)
        }
        for name in ["Meeting notes.txt", "Quarterly report final v2.md", "Archive.zip"] {
            let url = folder.appendingPathComponent(name)
            try? Data("Shima".utf8).write(to: url)
            urls.append(url)
        }
        return urls
    }
}

extension MediaController {
    /// A stand-in track for renders: 1:25 in, 2:09 left.
    static func sample(playing: Bool) -> MediaController {
        let media = MediaController()
        media.loadSample(title: "Golden Hour", artist: "The Meridian", duration: 214, elapsed: 85, playing: playing)
        return media
    }
}

/// Debug aid: `SHIMA_FILMSTRIP=<dir> Shima` shows the notch with a sample track, then opens, closes,
/// shows the drop targets, locks and unlocks, saving a frame every 1/30s of each transition
/// (open-NN, close-NN, drop-NN, lock-NN, unlock-NN .png), and exits.
@MainActor
enum Filmstrip {
    private static var controller: IslandPanelController?

    static func runIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["SHIMA_FILMSTRIP"] else { return false }
        let model = IslandModel()
        let shelf = ShelfStore(persists: false)
        shelf.add(Snapshot.sampleFiles())
        let controller = IslandPanelController(model: model, media: MediaController.sample(playing: true),
                                               outputs: AudioOutputController(), shelf: shelf,
                                               calendar: CalendarMonitor(), timer: NotchTimer(), tracksPointer: false)
        self.controller = controller

        func at(_ time: Double, _ action: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: action)
        }
        func capture(_ name: String) {
            guard let png = controller.captureFrame()?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        func record(_ name: String, from start: Double, frames: Int = 27) {
            for i in 0..<frames { at(start + Double(i) / 30) { capture(String(format: "\(name)-%02d", i)) } }
        }
        at(0.6) { controller.setExpanded(true) }
        record("open", from: 0.6)
        // A two-finger swipe to the next page: the drag, then the release.
        for (step, drag) in [-20.0, -60, -110, -150].enumerated() {
            at(1.5 + Double(step) * 0.05) { controller.simulatePageDrag(drag) }
        }
        at(1.7) { controller.simulatePageRelease() }
        record("swipe", from: 1.5, frames: 18)
        at(2.2) { controller.setExpanded(false) }
        record("close", from: 2.2)
        at(3.0) { controller.showSection(.shelf) }
        record("shelf", from: 3.0, frames: 6)
        at(3.2) { controller.showDropTargets(hovering: nil) }
        at(3.8) { controller.showDropTargets(hovering: .shelf) }
        at(4.0) { NSLog("drop registration: %@", controller.dragRegistrationReport()) }
        at(4.3) { controller.logOnScreen("pinned, drop targets up") }
        at(5.0) { controller.logOnScreen("over lock screen") }
        at(6.6) { controller.logOnScreen("back from lock screen") }
        record("drop", from: 3.2, frames: 30)
        at(4.4) { controller.screenLocked() }
        record("lock", from: 4.4)
        at(5.8) { controller.screenUnlocked() }
        record("unlock", from: 5.8, frames: 45)
        at(7.6) { exit(0) }
        return true
    }
}

/// Debug aid: `SHIMA_BENCH_WAVEFORM=<seconds> Shima` animates a closed-notch waveform in an off-screen
/// window for that long and exits, so its CPU cost can be measured on its own.
@MainActor
enum WaveformBench {
    private static var window: NSWindow?

    static func runIfRequested() -> Bool {
        guard let seconds = ProcessInfo.processInfo.environment["SHIMA_BENCH_WAVEFORM"].flatMap(Double.init) else { return false }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 60, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView:
            Visualizer(isPlaying: true, colors: [.cyan, .pink], spec: Metrics.compactBars)
                .frame(width: 60, height: 30)
                .background(.black))
        window.orderFrontRegardless()
        self.window = window
        // Prove the bars are moving: their on-screen (presentation) heights at a few moments.
        for t in [1.0, 1.4, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                func find(_ view: NSView) -> WaveformView? {
                    (view as? WaveformView) ?? view.subviews.lazy.compactMap(find).first
                }
                guard let waveform = window.contentView.flatMap(find), let bars = waveform.layer?.sublayers else { return }
                let heights = bars.map { String(format: "%.1f", $0.presentation()?.bounds.height ?? -1) }
                NSLog("waveform at %.1fs: %@ (animations: %@)", t, heights.joined(separator: " "),
                      bars.first?.animationKeys()?.joined(separator: ",") ?? "none")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        return true
    }
}
