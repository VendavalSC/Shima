import AppKit
import EventKit
import Observation
import SwiftUI

/// The next calendar event, as shown in the closed notch.
struct UpcomingEvent: Equatable {
    let id: String
    let title: String
    let start: Date
    let color: Color
}

/// An event on the Calendar page.
struct CalendarEntry: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
}

/// Calendar data for the notch: the event about to start (for Up Next in the closed notch) and the
/// rest of today (for the Calendar page). Wakes only at the moments that matter (an event coming
/// within notice, an event ending, midnight) and whenever the calendar database changes. Does
/// nothing until Calendar access has been granted and one of the features is turned on.
@Observable
final class CalendarMonitor {
    /// Up Next starts this long before an event (from Settings) and lasts this long after it starts.
    static let lingerAfterStart: TimeInterval = 5 * 60

    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    /// Today's events that haven't ended yet, all-day ones first.
    private(set) var today: [CalendarEntry] = []
    /// Tomorrow's first timed event, when nothing timed is left today.
    private(set) var tomorrow: CalendarEntry?
    var onChange: ((UpcomingEvent?) -> Void)?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var wakeUp: Timer?
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var current: UpcomingEvent?

    init() {
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                               queue: .main) { [weak self] _ in
            self?.recalculate()
        }
        // Only the settings are read inside the tracking closure; recalculating happens outside it,
        // so the state it updates doesn't feed back into the tracking.
        trackChanges { [weak self] in
            let settings = AppSettings.shared
            _ = (settings.calendarActivity, settings.calendarPage, settings.calendarLeadMinutes)
            DispatchQueue.main.async { self?.recalculate() }
        }
    }

    var hasAccess: Bool { access == .fullAccess }

    /// Asks for Calendar access (macOS shows its prompt the first time) and starts if granted.
    func requestAccess(completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.recalculate()
                completion(granted)
            }
        }
    }

    func refreshAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != access { access = status }
    }

    func recalculate() {
        wakeUp?.invalidate()
        wakeUp = nil
        refreshAccess()
        let settings = AppSettings.shared
        guard hasAccess, settings.calendarActivity || settings.calendarPage else {
            publish(nil)
            setPage(today: [], tomorrow: nil)
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now.addingTimeInterval(172_800)
        let events = store.events(matching: store.predicateForEvents(withStart: startOfToday, end: endOfTomorrow, calendars: nil))
            .filter { $0.status != .canceled && !Self.declined($0) && $0.startDate != nil && $0.endDate != nil }
            .sorted { $0.startDate < $1.startDate }
        var wakeTimes: [Date] = []

        // Up Next, in the closed notch.
        if settings.calendarActivity {
            let lead = TimeInterval(settings.calendarLeadMinutes * 60)
            let timed = events.filter { !$0.isAllDay }
            if let showing = timed.first(where: {
                $0.startDate.addingTimeInterval(-lead) <= now && now < $0.startDate.addingTimeInterval(Self.lingerAfterStart)
            }) {
                publish(UpcomingEvent(id: showing.eventIdentifier ?? UUID().uuidString, title: showing.title ?? "Event",
                                      start: showing.startDate, color: Self.color(of: showing)))
                wakeTimes.append(showing.startDate.addingTimeInterval(Self.lingerAfterStart))
            } else {
                publish(nil)
                if let next = timed.first(where: { $0.startDate.addingTimeInterval(-lead) > now }) {
                    wakeTimes.append(next.startDate.addingTimeInterval(-lead))
                }
            }
        } else {
            publish(nil)
        }

        // The Calendar page.
        if settings.calendarPage {
            let remaining = events.filter { $0.startDate < endOfToday && $0.endDate > now }
            let entries = remaining.filter(\.isAllDay) + remaining.filter { !$0.isAllDay }
            let laterToday = remaining.contains { !$0.isAllDay }
            let firstTomorrow = laterToday ? nil : events.first { !$0.isAllDay && $0.startDate >= endOfToday }
            setPage(today: entries.map(Self.entry), tomorrow: firstTomorrow.map(Self.entry))
            wakeTimes.append(endOfToday)
            if let soonestEnd = remaining.filter({ !$0.isAllDay }).map(\.endDate).min() { wakeTimes.append(soonestEnd) }
        } else {
            setPage(today: [], tomorrow: nil)
        }

        if let next = wakeTimes.filter({ $0 > now }).min() { schedule(at: next) }
    }

    /// Fills in the page with fixed events, for snapshots.
    func loadSample(today: [CalendarEntry], tomorrow: CalendarEntry?) {
        access = .fullAccess
        setPage(today: today, tomorrow: tomorrow)
    }

    private func setPage(today: [CalendarEntry], tomorrow: CalendarEntry?) {
        if today != self.today { self.today = today }
        if tomorrow != self.tomorrow { self.tomorrow = tomorrow }
    }

    private func schedule(at date: Date) {
        let timer = Timer(fire: date.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            self?.recalculate()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        wakeUp = timer
    }

    private func publish(_ event: UpcomingEvent?) {
        guard event != current else { return }
        current = event
        onChange?(event)
    }

    private static func entry(_ event: EKEvent) -> CalendarEntry {
        CalendarEntry(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event",
                      start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, color: color(of: event))
    }

    private static func color(of event: EKEvent) -> Color {
        Color(nsColor: event.calendar?.color ?? .systemBlue)
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}
