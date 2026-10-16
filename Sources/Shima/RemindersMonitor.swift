import AppKit
import EventKit
import Observation
import SwiftUI

/// A reminder on the Reminders page.
struct ReminderItem: Equatable, Identifiable {
    let id: String
    let title: String
    let due: Date?
    /// The due date has a time of day, not just a day.
    let hasTime: Bool
    let color: Color

    var isOverdue: Bool {
        guard let due else { return false }
        return hasTime ? due < Date() : due < Calendar.current.startOfDay(for: Date())
    }
}

/// What's left to do today, from Reminders: anything due today or overdue, then reminders without a
/// date from the default list. Wakes when the Reminders database changes and at midnight; nothing
/// polls. Does nothing until Reminders access has been granted and the page is turned on.
@Observable
final class RemindersMonitor {
    static let shared = RemindersMonitor()

    private(set) var access = EKEventStore.authorizationStatus(for: .reminder)
    private(set) var items: [ReminderItem] = []
    /// Reminders just ticked off, shown filled in for a moment before they leave the list.
    private(set) var completing: Set<String> = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var midnight: Timer?
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var fetch: Any?

    var hasAccess: Bool { access == .fullAccess }

    private init() {
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                               queue: .main) { [weak self] _ in self?.refresh() }
        trackChanges { [weak self] in
            _ = AppSettings.shared.remindersPage
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Asks for Reminders access (macOS shows its prompt the first time) and starts if granted.
    func requestAccess(completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refresh()
                completion(granted)
            }
        }
    }

    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status != access { access = status }
        midnight?.invalidate()
        guard hasAccess, AppSettings.shared.remindersPage else {
            setItems([])
            return
        }
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let defaultList = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        if let fetch { store.cancelFetchRequest(fetch) }
        fetch = store.fetchReminders(matching: predicate) { [weak self] reminders in
            let reminders = reminders ?? []
            let dated = reminders.filter { ($0.dueDateComponents?.date ?? .distantFuture) < endOfToday }
                .sorted { ($0.dueDateComponents?.date ?? .distantPast) < ($1.dueDateComponents?.date ?? .distantPast) }
            let undated = reminders.filter { $0.dueDateComponents == nil && $0.calendar?.calendarIdentifier == defaultList }
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            let items = (dated + undated).map(Self.item)
            DispatchQueue.main.async { self?.setItems(items) }
        }
        let timer = Timer(fire: endOfToday.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in self?.refresh() }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        midnight = timer
    }

    /// Ticks a reminder off: it fills in, then leaves the list a moment later.
    func complete(_ item: ReminderItem) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        withAnimation(.snappy(duration: 0.25)) { _ = completing.insert(item.id) }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            Log.activity.error("reminders: couldn't complete: \(error.localizedDescription, privacy: .public)")
            withAnimation { _ = completing.remove(item.id) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            withAnimation(.snappy(duration: 0.35)) {
                self.items.removeAll { $0.id == item.id }
                self.completing.remove(item.id)
            }
        }
    }

    /// Adds a reminder to the default list. A date or time in the text ("tomorrow at 5", "Friday")
    /// becomes its due date and is taken out of the title.
    func add(_ text: String) {
        let parsed = Self.parse(text)
        guard !parsed.title.isEmpty, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = parsed.title
        reminder.calendar = list
        if let due = parsed.due {
            let units: Set<Calendar.Component> = parsed.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
            if parsed.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        do {
            try store.save(reminder, commit: true)
            Log.activity.info("reminders: added")
        } catch {
            Log.activity.error("reminders: couldn't add: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fills in the page with fixed reminders, for snapshots.
    func loadSample(_ items: [ReminderItem]) {
        access = .fullAccess
        setItems(items)
    }

    private func setItems(_ items: [ReminderItem]) {
        let shown = items.filter { !completing.contains($0.id) } + self.items.filter { completing.contains($0.id) }
        guard shown != self.items else { return }
        withAnimation(.snappy(duration: 0.35)) { self.items = shown }
    }

    private static func item(_ reminder: EKReminder) -> ReminderItem {
        let components = reminder.dueDateComponents
        return ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder",
                            due: components?.date ?? components.flatMap { Calendar.current.date(from: $0) },
                            hasTime: components?.hour != nil,
                            color: Color(nsColor: reminder.calendar?.color ?? .systemOrange))
    }

    /// The text without the date in it, and that date.
    static func parse(_ text: String) -> (title: String, due: Date?, hasTime: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let date = match.date, let range = Range(match.range, in: trimmed) else {
            return (trimmed, nil, false)
        }
        var title = trimmed
        title.removeSubrange(range)
        // Words left dangling where the date was: "Call Ana at" → "Call Ana".
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let dangling = [" at", " on", " by", " for", " el", " la", " a las", " a la", " para", " el día"]
        while let word = dangling.first(where: { title.lowercased().hasSuffix($0) }) {
            title = String(title.dropLast(word.count))
        }
        // A date without a time comes back at noon, in any language; noon said in words counts too.
        let spoken = String(trimmed[range]).lowercased()
        let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hasTime = clock.hour != 12 || clock.minute != 0 || spoken.contains(":") || spoken.range(of: #"\d\s*(am|pm|h)\b"#, options: .regularExpression) != nil
            || spoken.contains(" at ") || spoken.hasPrefix("at ") || spoken.contains("noon") || spoken.contains("tonight")
        return (title.trimmingCharacters(in: .whitespaces), date, hasTime)
    }
}
