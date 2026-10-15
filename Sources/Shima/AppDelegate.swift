import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let media = MediaController()
    private let outputs = AudioOutputController()
    private let shelf = ShelfStore()
    /// A notch on each display it's shown on, each with its own state; music, the shelf, the timer
    /// and the calendar are shared.
    private var islands: [CGDirectDisplayID: (controller: IslandPanelController, model: IslandModel)] = [:]
    private var upcomingEvent: UpcomingEvent?
    private var statusItem: NSStatusItem?
    private var battery: BatteryMonitor?
    private let capsLock = CapsLockMonitor()
    private let drives = DriveMonitor()
    private let calendar = CalendarMonitor()
    private let timer = NotchTimer()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, shelf: shelf, calendar: calendar)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Filmstrip.runIfRequested() || WaveformBench.runIfRequested() { return }
        if ProcessInfo.processInfo.environment["SHIMA_SETTINGS_SNAPSHOT"] != nil {
            SettingsSnapshot.run(settings: settings, shelf: shelf, calendar: calendar)
            return
        }
        syncDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.syncDisplays()
        }
        trackChanges { [weak self] in
            _ = self?.settings.displayPreferences
            DispatchQueue.main.async { self?.syncDisplays() }
        }
        media.start()
        battery = BatteryMonitor()
        battery?.onAlert = { [weak self] alert in self?.activeIsland?.showBatteryAlert(alert) }
        outputs.onConnect = { [weak self] device in
            guard self?.settings.deviceActivity == true else { return }
            self?.activeIsland?.showDeviceAlert(device)
        }
        capsLock.onChange = { [weak self] on in
            self?.activeIsland?.showStatus(StatusAlert(symbol: on ? "capslock.fill" : "capslock", title: "Caps Lock",
                                                       state: on ? "On" : "Off", isOn: on))
        }
        drives.onConnect = { [weak self] drive in self?.activeIsland?.showDrive(drive) }
        FocusMonitor.shared.onChange = { [weak self] focus, on in
            self?.activeIsland?.showStatus(StatusAlert(symbol: focus.symbol, title: focus.name, state: on ? "On" : "Off",
                                                       isOn: on, tint: focus.color))
        }
        drives.onEject = { [weak self] drive in self?.activeIsland?.showDrive(drive) }
        calendar.onChange = { [weak self] event in
            guard let self else { return }
            self.upcomingEvent = event
            withAnimation(Motion.compact) { self.islands.values.forEach { $0.model.upcomingEvent = event } }
        }
        calendar.recalculate()
        NotificationWatcher.shared.onNotification = { [weak self] notification in
            self?.activeIsland?.showNotification(notification) ?? false
        }
        if let demo = ProcessInfo.processInfo.environment["SHIMA_DEMO_DEVICE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.activeIsland?.showDemoDevice(demo) }
        }
        installMainMenu()
        installStatusItem()
        trackChanges { [weak self] in
            guard let self else { return }
            self.statusItem?.isVisible = self.settings.showMenuBarIcon
        }
    }

    /// A notch on every display it's turned on for in Settings, added and removed as displays come
    /// and go.
    private func syncDisplays() {
        let screens = NSScreen.screens.filter { settings.preference(for: $0.displayKey).shown }
        let wanted = Set(screens.map(\.displayID))
        for (id, island) in islands where !wanted.contains(id) {
            island.controller.close()
            islands[id] = nil
        }
        for screen in screens where islands[screen.displayID] == nil {
            let model = IslandModel()
            model.upcomingEvent = upcomingEvent
            let controller = IslandPanelController(model: model, media: media, outputs: outputs, shelf: shelf,
                                                   calendar: calendar, timer: timer, displayID: screen.displayID)
            controller.ejectDrive = { [weak self] drive, completion in self?.drives.eject(drive, completion: completion) }
            islands[screen.displayID] = (controller, model)
        }
    }

    /// The notch where you're working, for things that appear in one place (an alert, a notification):
    /// the one on the display with the pointer.
    private var activeIsland: IslandPanelController? {
        if settings.alertDisplay == .main, let main = islands[CGMainDisplayID()]?.controller { return main }
        let pointer = NSEvent.mouseLocation
        let display = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }?.displayID
        return display.flatMap { islands[$0]?.controller }
            ?? islands[CGMainDisplayID()]?.controller
            ?? islands.values.first?.controller
    }

    /// Opening Shima again (from Finder, Spotlight, or Launchpad) brings up Settings, which is the way
    /// back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        media.stop()
    }

    @objc private func showSettings() { settingsWindow.show() }
    @objc private func showAbout() { settingsWindow.show(.about) }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "Shima")
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Shima")
        let menu = NSMenu()
        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shima", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// The menus shown while the Settings window is open (Shima has none otherwise).
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Shima")
        appMenu.addItem(withTitle: "About Shima", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Shima", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Shima", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Shima", action: nil, keyEquivalent: "").submenu = appMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
