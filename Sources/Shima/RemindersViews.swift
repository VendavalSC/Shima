import AppKit
import SwiftUI

/// The Reminders page, after Apple's Reminders widget: how many are left today on the leading side,
/// and the list on the trailing side, each with a circle to tick it off. The last row adds a reminder;
/// a date in what you type ("tomorrow at 5") becomes its due date.
struct RemindersSection: View {
    let model: IslandModel
    let reminders: RemindersMonitor

    private static let maxRows = 3

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "list.bullet.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
                Text("\(reminders.items.count - reminders.completing.count)")
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.top, 2)
                Text("Today")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 76, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { openReminders() }

            VStack(alignment: .leading, spacing: 6) {
                if reminders.items.isEmpty && !model.isTyping {
                    Text("Nothing left today")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)
                }
                // While typing, one row fewer, so the field keeps its place above the page dots.
                let rows = model.isTyping ? Self.maxRows - 1 : Self.maxRows
                let shown = reminders.items.count > rows ? rows - 1 : rows
                ForEach(reminders.items.prefix(shown)) { item in
                    ReminderRow(item: item, done: reminders.completing.contains(item.id)) { reminders.complete(item) }
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
                if reminders.items.count > shown {
                    Text("\(reminders.items.count - shown) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.leading, 26)
                }
                NewReminderRow(model: model) { reminders.add($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    private func openReminders() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// One reminder: a circle in its list's color that fills when ticked, the title, and when it's due
/// (in red once it's late).
private struct ReminderRow: View {
    let item: ReminderItem
    let done: Bool
    let complete: () -> Void

    private var due: String? {
        guard let date = item.due else { return nil }
        let calendar = Calendar.current
        if item.hasTime && calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDateInToday(date) { return nil }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: complete) {
                ZStack {
                    Circle().strokeBorder(done ? item.color : .white.opacity(0.35), lineWidth: 1.5)
                    Circle().fill(item.color).padding(3.5).scaleEffect(done ? 1 : 0.2).opacity(done ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(done)

            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(done ? 0.4 : 1))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let due {
                Text(due)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(item.isOverdue ? Color.red : .white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: 20)
    }
}

/// "New Reminder", which turns into a field when clicked. Return adds it; Escape, or clicking
/// elsewhere with nothing typed, puts it away.
private struct NewReminderRow: View {
    let model: IslandModel
    let add: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(model.isTyping ? 0.8 : 0.35))
                .frame(width: 18, height: 18)
            if model.isTyping {
                TypingField(placeholder: "Call Ana tomorrow at 5", text: Binding(get: { model.typedText },
                                                                                set: { model.typedText = $0 })) { submitted in
                    if submitted, !model.typedText.trimmingCharacters(in: .whitespaces).isEmpty { add(model.typedText) }
                    model.onTyping?(false)
                }
            } else {
                Text("New Reminder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
            }
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture { if !model.isTyping { model.onTyping?(true) } }
    }
}

/// A plain one-line text field that takes the keyboard as soon as it appears. Calls `finish` with true
/// on Return and false on Escape.
struct TypingField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let finish: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.3), .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ])
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TypingField
        init(parent: TypingField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.finish(true)
            case #selector(NSResponder.cancelOperation(_:)): parent.finish(false)
            default: return false
            }
            return true
        }
    }
}
