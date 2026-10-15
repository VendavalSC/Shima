import AppKit
import Observation
import ServiceManagement

enum NotchHeightMode: String, CaseIterable, Identifiable {
    /// The hardware notch where there is one, otherwise the menu bar.
    case automatic
    case custom

    var id: Self { self }
}

enum NotchStyle: String, CaseIterable, Identifiable, Codable {
    /// Hanging from the top edge, like the camera housing.
    case notch
    /// Floating just below the top edge, rounded all round, like iPhone's Dynamic Island.
    case island

    var id: Self { self }
    var title: String { self == .notch ? "Notch" : "Island" }
}

enum NotchWidth: String, CaseIterable, Identifiable {
    case narrow, standard, wide

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var scale: CGFloat { [.narrow: 0.85, .standard: 1, .wide: 1.15][self]! }
}

/// Where alerts (charging, headphones, Caps Lock, drives, Focus) and notifications appear.
enum AlertDisplay: String, CaseIterable, Identifiable {
    /// The display with the pointer.
    case active
    case main

    var id: Self { self }
    var title: String { self == .active ? "The display you're using" : "The main display" }
}

/// How one display shows the notch, remembered by display so it's the same when it's plugged in again.
struct DisplayPreference: Codable, Equatable {
    var shown = true
    var style: NotchStyle
}

enum HoverDelay: String, CaseIterable, Identifiable {
    case instant, short, long

    var id: Self { self }
    var title: String {
        switch self {
        case .instant: "Instant"
        case .short: "Short"
        case .long: "Long"
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .instant: 0.05
        case .short: 0.2
        case .long: 0.5
        }
    }
}

enum WaveformColor: String, CaseIterable, Identifiable {
    case artwork, white

    var id: Self { self }
    var title: String { self == .artwork ? "Album Artwork" : "White" }
}

/// Every user preference, saved to UserDefaults the moment it changes and read live by the notch.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // General
    var showMenuBarIcon = Store.bool(.menuBarIcon, default: true) { didSet { Store.set(showMenuBarIcon, .menuBarIcon) } }
    var openOnHover = Store.bool(.openOnHover, default: true) { didSet { Store.set(openOnHover, .openOnHover) } }
    var hoverDelay = Store.value(.hoverDelay, default: HoverDelay.short) { didSet { Store.set(hoverDelay.rawValue, .hoverDelay) } }
    var haptics = Store.bool(.haptics, default: true) { didSet { Store.set(haptics, .haptics) } }

    // Notch
    // Appearance
    var hideWhenIdle = Store.bool(.hideWhenIdle, default: false) { didSet { Store.set(hideWhenIdle, .hideWhenIdle) } }
    var notchWidth = Store.value(.notchWidth, default: NotchWidth.standard) {
        didSet { Store.set(notchWidth.rawValue, .notchWidth) }
    }
    var alertDisplay = Store.value(.alertDisplay, default: AlertDisplay.active) {
        didSet { Store.set(alertDisplay.rawValue, .alertDisplay) }
    }
    /// The pages in the order they're swiped through; every page is listed, turned on or not.
    var pageOrder: [NotchSection] = {
        let saved = (UserDefaults.standard.stringArray(forKey: Store.Key.pageOrder.rawValue) ?? []).compactMap(NotchSection.init)
        return saved + NotchSection.allCases.filter { !saved.contains($0) }
    }() {
        didSet { Store.set(pageOrder.map(\.rawValue), .pageOrder) }
    }

    /// The style for a display that hasn't been set up in Settings yet.
    var notchStyle = Store.value(.notchStyle, default: NotchStyle.notch) {
        didSet { Store.set(notchStyle.rawValue, .notchStyle) }
    }
    /// Each display's choices, by its lasting ID (see `NSScreen.displayKey`).
    var displayPreferences: [String: DisplayPreference] = Store.decoded(.displays) ?? [:] {
        didSet { Store.encode(displayPreferences, .displays) }
    }

    /// A display's choices: what was set for it, or shown in the default style.
    func preference(for display: String) -> DisplayPreference {
        displayPreferences[display] ?? DisplayPreference(style: notchStyle)
    }

    func updatePreference(for display: String, _ change: (inout DisplayPreference) -> Void) {
        var preference = preference(for: display)
        change(&preference)
        displayPreferences[display] = preference
    }
    var notchHeightMode = Store.value(.notchHeightMode, default: NotchHeightMode.automatic) {
        didSet { Store.set(notchHeightMode.rawValue, .notchHeightMode) }
    }
    var customNotchHeight = Store.double(.customNotchHeight, default: 32) { didSet { Store.set(customNotchHeight, .customNotchHeight) } }
    var hideInFullscreen = Store.bool(.hideInFullscreen, default: true) { didSet { Store.set(hideInFullscreen, .hideInFullscreen) } }
    var showOnLockScreen = Store.bool(.showOnLockScreen, default: true) { didSet { Store.set(showOnLockScreen, .showOnLockScreen) } }

    // Battery
    var chargingActivity = Store.bool(.chargingActivity, default: true) { didSet { Store.set(chargingActivity, .chargingActivity) } }
    var lowBatteryActivity = Store.bool(.lowBatteryActivity, default: true) { didSet { Store.set(lowBatteryActivity, .lowBatteryActivity) } }

    // Notifications
    var notifications = Store.bool(.notifications, default: false) { didSet { Store.set(notifications, .notifications) } }

    // More activities
    var capsLockActivity = Store.bool(.capsLockActivity, default: true) { didSet { Store.set(capsLockActivity, .capsLockActivity) } }
    var driveActivity = Store.bool(.driveActivity, default: true) { didSet { Store.set(driveActivity, .driveActivity) } }
    /// Off until asked for: it needs Full Disk Access.
    var focusActivity = Store.bool(.focusActivity, default: false) { didSet { Store.set(focusActivity, .focusActivity) } }

    // Audio
    var deviceActivity = Store.bool(.deviceActivity, default: true) { didSet { Store.set(deviceActivity, .deviceActivity) } }

    // Calendar
    var calendarActivity = Store.bool(.calendarActivity, default: false) { didSet { Store.set(calendarActivity, .calendarActivity) } }
    var calendarPage = Store.bool(.calendarPage, default: false) { didSet { Store.set(calendarPage, .calendarPage) } }

    // Pages
    var timerPage = Store.bool(.timerPage, default: true) { didSet { Store.set(timerPage, .timerPage) } }
    var systemPage = Store.bool(.systemPage, default: false) { didSet { Store.set(systemPage, .systemPage) } }
    var calendarLeadMinutes = Store.int(.calendarLead, default: 10) { didSet { Store.set(calendarLeadMinutes, .calendarLead) } }

    // Now Playing
    var showMusicWhenClosed = Store.bool(.musicWhenClosed, default: true) { didSet { Store.set(showMusicWhenClosed, .musicWhenClosed) } }
    var waveformColor = Store.value(.waveformColor, default: WaveformColor.artwork) {
        didSet { Store.set(waveformColor.rawValue, .waveformColor) }
    }

    // Shelf
    var shelfEnabled = Store.bool(.shelf, default: true) { didSet { Store.set(shelfEnabled, .shelf) } }
    var airDropTarget = Store.bool(.airDropTarget, default: true) { didSet { Store.set(airDropTarget, .airDropTarget) } }

    // MARK: Launch at login (lives with the system, not in UserDefaults)

    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// The system wants the user to approve Shima in System Settings → General → Login Items.
    private(set) var launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    private(set) var launchAtLoginError: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }
}

/// UserDefaults keys and typed reads.
enum Store {
    enum Key: String {
        case menuBarIcon, openOnHover, hoverDelay, haptics, notchStyle, displays, hideWhenIdle, notchWidth, alertDisplay, pageOrder, notchHeightMode, customNotchHeight
        case hideInFullscreen, showOnLockScreen, musicWhenClosed, waveformColor, shelf, airDropTarget
        case chargingActivity, lowBatteryActivity, deviceActivity, capsLockActivity, driveActivity, focusActivity, notifications, calendarActivity, calendarLead, calendarPage, timerPage, systemPage
    }

    static func bool(_ key: Key, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key.rawValue) as? Bool ?? value
    }

    static func int(_ key: Key, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key.rawValue) as? Int ?? value
    }

    static func double(_ key: Key, default value: Double) -> Double {
        UserDefaults.standard.object(forKey: key.rawValue) as? Double ?? value
    }

    static func value<T: RawRepresentable>(_ key: Key, default value: T) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key.rawValue).flatMap(T.init(rawValue:)) ?? value
    }

    static func set(_ value: Any, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func decoded<T: Decodable>(_ key: Key) -> T? {
        UserDefaults.standard.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func encode<T: Encodable>(_ value: T, _ key: Key) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key.rawValue) }
    }
}

/// Runs `apply` now and again whenever anything it read from an observable object changes.
func trackChanges(_ apply: @escaping () -> Void) {
    withObservationTracking(apply) {
        DispatchQueue.main.async { trackChanges(apply) }
    }
}
