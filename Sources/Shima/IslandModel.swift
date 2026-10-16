import Foundation
import Observation

/// The iPhone-style lock sequence: the shackle closes as the screen locks, and opens on unlock
/// before the notch returns to normal.
enum LockPhase {
    case unlocked, locking, locked, unlocking

    var showsOpenShackle: Bool { self == .locking || self == .unlocking }
}

/// Where a file drag is hovering while the notch shows its drop targets.
enum DropTarget {
    case shelf, airDrop
}

/// The open notch's pages, swiped between with two fingers.
enum NotchSection: String, CaseIterable, Identifiable {
    case player, calendar, reminders, weather, timer, system, shelf

    var id: Self { self }

    var title: String {
        switch self {
        case .player: "Now Playing"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .weather: "Weather"
        case .timer: "Timer"
        case .system: "System"
        case .shelf: "Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .player: "play.fill"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .weather: "cloud.sun.fill"
        case .timer: "timer"
        case .system: "gauge.with.dots.needle.67percent"
        case .shelf: "tray.full.fill"
        }
    }

    /// The pages in your order: Now Playing always, the others when they're turned on.
    static func available(calendarAccess: Bool) -> [NotchSection] {
        let settings = AppSettings.shared
        return settings.pageOrder.filter { page in
            switch page {
            case .player: true
            case .calendar: settings.calendarPage && calendarAccess
            case .reminders: settings.remindersPage && RemindersMonitor.shared.hasAccess
            case .weather: settings.weatherPage
            case .timer: settings.timerPage
            case .system: settings.systemPage
            case .shelf: settings.shelfEnabled
            }
        }
    }
}

enum ReplyPhase: Equatable {
    case none, typing, sent
}

/// Touch ID on the lock screen: the fingerprint resting, reading a finger, then matched.
enum LockFinger: Equatable {
    case resting, reading, matched
}

/// A Touch ID prompt mirrored in the notch: waiting for a finger, then accepted.
enum TouchIDPhase: Equatable {
    case waiting, accepted
}

enum NotificationAction {
    case open, reply, send
}

@Observable
final class IslandModel {
    /// The display this notch is on.
    var geometry = NotchGeometry.main
    var isExpanded = false
    var lockPhase: LockPhase = .unlocked
    /// The fingerprint beside the padlock, on Macs with Touch ID.
    var lockFinger: LockFinger?
    /// Bumped each time the sensor can't read a finger on the lock screen.
    var lockMisses = 0
    /// Music was paused from the lock screen: keep its controls there until unlock.
    var lockMusicKept = false
    /// Files are being dragged near the notch: it shows drop targets instead of its usual content.
    var isDropping = false
    var dropTarget: DropTarget?
    var section: NotchSection = .player
    /// A brief battery event (plugged in, low battery) shown over the closed notch.
    var batteryAlert: BatteryAlert?
    /// Headphones or a speaker that just connected, shown over the closed notch.
    var deviceAlert: DeviceAlert?
    /// A quick status (Caps Lock) over the closed notch.
    var statusAlert: StatusAlert?
    /// A drive that just connected (with Eject) or was ejected.
    var driveAlert: DriveAlert?
    /// The Mac is asking for Touch ID.
    var touchID: TouchIDPhase?
    /// Bumped each time the sensor can't read a finger, so the fingerprint shakes.
    var touchIDMisses = 0
    /// Eject on the drive banner.
    @ObservationIgnored var onEjectDrive: (() -> Void)?
    /// A notification that just arrived, shown below the notch.
    var notification: NotchNotification?
    /// Replying to it from the notch: typing, then sent.
    var replyPhase: ReplyPhase = .none
    /// What's in the reply box, mirrored from the system's.
    var replyText = ""
    /// How far a two-finger swipe up has pushed the notification back into the notch.
    var notificationLift: CGFloat = 0
    /// The notification's buttons: open it, start a reply, send the reply.
    @ObservationIgnored var onNotificationAction: ((NotificationAction) -> Void)?
    /// A calendar event about to start (or just started), shown over the closed notch.
    var upcomingEvent: UpcomingEvent?
    /// Called with files dropped on a target; set by the panel controller, which owns the shelf.
    @ObservationIgnored var onDropFiles: (([URL], DropTarget) -> Void)?
    /// How far the pages have been dragged by a two-finger swipe in progress.
    var pageDrag: CGFloat = 0
    /// The page dots are showing: during a swipe, and for a moment as the notch opens.
    var pageDotsVisible = false
    /// Where the progress bar is being dragged to (0...1), or nil when not scrubbing.
    var scrubFraction: Double?
    /// Bumped on each skip so the skip buttons replay their bounce.
    var nextTaps = 0
    var previousTaps = 0
    /// True while the output-device menu is up, so the notch stays open underneath it.
    var isMenuOpen = false
    /// A field in the notch has the keyboard (adding a reminder); the notch stays open meanwhile.
    var isTyping = false
    var typedText = ""
    /// Starts (true) or ends (false) typing; the panel takes the keyboard only meanwhile.
    @ObservationIgnored var onTyping: ((Bool) -> Void)?
    /// Pointer position in the expanded player's coordinates, or nil when it's elsewhere.
    /// Tracked by the panel controller because hover tracking areas don't fire in a never-key panel.
    var pointer: CGPoint?

    func isHovering(_ center: CGPoint, radius: CGFloat) -> Bool {
        guard let pointer else { return false }
        return hypot(pointer.x - center.x, pointer.y - center.y) <= radius
    }
}
