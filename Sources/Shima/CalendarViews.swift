import AppKit
import SwiftUI

/// The Calendar page, after Apple's Calendar widget: today's date on the leading side (weekday in red
/// over the day number) and what's left of today on the trailing side. Clicking opens Calendar.
struct CalendarSection: View {
    let calendar: CalendarMonitor

    private static let maxRows = 3

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.date.formatted(.dateTime.weekday(.wide)).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(context.date.formatted(.dateTime.day()))
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.white)
                    Text(context.date.formatted(.dateTime.month(.wide)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 76, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if calendar.today.isEmpty {
                    Text("No more events today")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)
                    if let tomorrow = calendar.tomorrow {
                        Text("TOMORROW")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 4)
                        EventRow(entry: tomorrow)
                    }
                } else {
                    // Three events fit; with more, two and a count, so nothing crowds the page dots.
                    let shown = calendar.today.count > Self.maxRows ? Self.maxRows - 1 : Self.maxRows
                    ForEach(calendar.today.prefix(shown)) { EventRow(entry: $0) }
                    if calendar.today.count > shown {
                        Text("\(calendar.today.count - shown) more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
        .contentShape(Rectangle())
        .onTapGesture { openCalendar() }
    }

    private func openCalendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// One event: its calendar's color, the title, and when.
private struct EventRow: View {
    let entry: CalendarEntry

    private var when: String {
        if entry.isAllDay { return "All day" }
        let time = Date.FormatStyle.dateTime.hour().minute()
        let end = entry.end.formatted(time)
        return entry.start <= Date() ? "Now – \(end)" : "\(entry.start.formatted(time)) – \(end)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(entry.color)
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(when)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }
}
