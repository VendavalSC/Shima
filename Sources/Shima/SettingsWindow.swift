import AppKit
import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, pages, activities, nowPlaying, notifications, calendar, shelf, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .pages: "Pages"
        case .activities: "Activities"
        case .nowPlaying: "Now Playing"
        case .notifications: "Notifications"
        case .calendar: "Calendar"
        case .shelf: "Shelf"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "macbook"
        case .pages: "square.stack.fill"
        case .activities: "sparkles"
        case .nowPlaying: "play.fill"
        case .notifications: "bell.badge.fill"
        case .calendar: "calendar"
        case .shelf: "tray.full.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .indigo
        case .pages: .teal
        case .activities: .orange
        case .nowPlaying: .pink
        case .notifications: .red
        case .calendar: .red
        case .shelf: .blue
        case .about: .gray
        }
    }
}

@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
}

/// A standalone Settings window: sidebar of panes, each a grouped form, like System Settings.
/// Shima normally has no Dock icon; it takes one while this window is open so it can be found.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let shelf: ShelfStore
    private let calendar: CalendarMonitor
    fileprivate let navigation = SettingsNavigation()
    fileprivate var window: NSWindow?

    init(settings: AppSettings, shelf: ShelfStore, calendar: CalendarMonitor) {
        self.settings = settings
        self.shelf = shelf
        self.calendar = calendar
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, navigation: navigation, shelf: shelf,
                                                                  calendar: calendar))
            let window = NSWindow(contentViewController: host)
            window.title = navigation.pane.title
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 700, height: 500))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("ShimaSettings")
            self.window = window
            // Like System Settings, the window is titled after the pane on show.
            trackChanges { [weak self] in
                guard let self, let window = self.window else { return }
                window.title = self.navigation.pane.title
            }
        }
        settings.refreshLaunchAtLogin()
        calendar.refreshAccess()
        NotificationWatcher.shared.refreshTrust()
        FocusMonitor.shared.update()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: Views

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let navigation: SettingsNavigation
    let shelf: ShelfStore
    let calendar: CalendarMonitor

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { navigation.pane },
                                                            set: { if let pane = $0 { navigation.pane = pane } })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            Group {
                switch navigation.pane {
                case .general: GeneralPane(settings: settings)
                case .appearance: AppearancePane(settings: settings)
                case .pages: PagesPane(settings: settings, calendar: calendar)
                case .activities: ActivitiesPane(settings: settings)
                case .nowPlaying: NowPlayingPane(settings: settings)
                case .notifications: NotificationsPane(settings: settings, watcher: .shared)
                case .calendar: CalendarPane(settings: settings, calendar: calendar)
                case .shelf: ShelfPane(settings: settings, shelf: shelf)
                case .about: AboutPane()
                }
            }
            .navigationTitle(navigation.pane.title)
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

/// System Settings' sidebar icon: a white glyph on a small colored tile.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient))
    }
}

private struct GeneralPane: View {
    @Bindable var settings: AppSettings
    let updater = Updater.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Shima \(Updater.currentVersion)") {
                    switch updater.state {
                    case .available(let version):
                        Button("Install \(version)") { updater.install() }.buttonStyle(.borderedProminent)
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .installing:
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary) }
                    default:
                        Button("Check for Updates") { updater.check() }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Group {
                    switch updater.state {
                    case .upToDate: Text("You're up to date.")
                    case .available(let version): Text("Shima \(version) is available. Shima installs it and reopens.")
                    case .failed(let message): Text(message)
                    default: Text("Shima looks for a new version once a day.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin },
                                                      set: { settings.setLaunchAtLogin($0) }))
                Toggle("Show in menu bar", isOn: $settings.showMenuBarIcon)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.launchAtLoginNeedsApproval {
                        HStack(spacing: 4) {
                            Text("Shima needs your approval to open at login.")
                            Button("Open Login Items…") { SMAppServiceSettings.open() }
                                .buttonStyle(.link)
                        }
                    } else if let error = settings.launchAtLoginError {
                        Text(error)
                    }
                    if !settings.showMenuBarIcon {
                        Text("To come back to Settings, open Shima again from your Applications folder.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open when the pointer rests on the notch", isOn: $settings.openOnHover)
                Picker("Delay", selection: $settings.hoverDelay) {
                    ForEach(HoverDelay.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.openOnHover)
                Toggle("Haptic feedback when opening", isOn: $settings.haptics)
            } header: {
                Text("Opening")
            } footer: {
                Text(settings.openOnHover
                     ? "Haptic feedback is felt on Force Touch trackpads."
                     : "Click the notch to open it. Haptic feedback is felt on Force Touch trackpads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearancePane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(ConnectedDisplays.shared.all) { display in
                    DisplayRow(display: display, settings: settings)
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("The notch hangs from the top of the screen; the island floats just below it, rounded all round, like iPhone's Dynamic Island. Displays with a camera notch always use the notch. Each display's notch opens on its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Width", selection: $settings.notchWidth) {
                    ForEach(NotchWidth.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Height", selection: $settings.notchHeightMode) {
                    Text("Automatic").tag(NotchHeightMode.automatic)
                    Text("Custom").tag(NotchHeightMode.custom)
                }
                if settings.notchHeightMode == .custom {
                    LabeledContent("Custom height") {
                        HStack {
                            Slider(value: $settings.customNotchHeight, in: 22...40, step: 1)
                                .frame(maxWidth: 220)
                            Text("\(Int(settings.customNotchHeight)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Size When Closed")
            } footer: {
                Text("A camera notch sets its own width. Taller than the menu bar, the closed notch covers the top edge of windows beneath it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide when there's nothing to show", isOn: $settings.hideWhenIdle)
                Toggle("Hide when an app is full screen", isOn: $settings.hideInFullscreen)
                Toggle("Show on the lock screen", isOn: $settings.showOnLockScreen)
            } header: {
                Text("Visibility")
            } footer: {
                Text("Hidden with nothing to show, it appears with music, a timer or an alert, and pointing where it sits still opens it. On the lock screen, a padlock closes as your Mac locks and opens as you unlock it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The pages, in the order they're swiped through: drag to reorder, switch off the ones you don't want.
private struct PagesPane: View {
    @Bindable var settings: AppSettings
    let calendar: CalendarMonitor

    var body: some View {
        Form {
            Section {
                ForEach(settings.pageOrder) { page in
                    pageRow(page)
                }
                .onMove { from, to in settings.pageOrder.move(fromOffsets: from, toOffset: to) }
            } header: {
                Text("Pages")
            } footer: {
                Text("Drag pages to change their order. Swipe with two fingers on the open notch to move between them. With the Shelf on, you can also drag files to the notch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if settings.weatherPage { WeatherLocationSection(settings: settings) }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func pageRow(_ page: NotchSection) -> some View {
        let label = Label { Text(page.title) } icon: { Image(systemName: page.symbol).foregroundStyle(.secondary).frame(width: 20) }
        switch page {
        case .player: LabeledContent { Text("Always on") } label: { label }
        case .calendar: CalendarAccessToggle(title: page.title, setting: \.calendarPage, settings: settings, calendar: calendar,
                                             symbol: page.symbol)
        case .reminders:
            Toggle(isOn: Binding(get: { settings.remindersPage && RemindersMonitor.shared.hasAccess }, set: { turnOn in
                guard turnOn else { return settings.remindersPage = false }
                if RemindersMonitor.shared.hasAccess {
                    settings.remindersPage = true
                } else {
                    RemindersMonitor.shared.requestAccess { granted in settings.remindersPage = granted }
                }
            })) { label }
        case .weather:
            Toggle(isOn: Binding(get: { settings.weatherPage }, set: { on in
                settings.weatherPage = on
                if on && settings.weatherCity == nil { WeatherMonitor.shared.requestLocation() }
            })) { label }
        case .timer: Toggle(isOn: $settings.timerPage) { label }
        case .system: Toggle(isOn: $settings.systemPage) { label }
        case .shelf: Toggle(isOn: $settings.shelfEnabled) { label }
        }
    }
}

private struct ActivitiesPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Show alerts on", selection: $settings.alertDisplay) {
                    ForEach(AlertDisplay.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Alerts and notifications appear on one display: the one with the pointer, or always the main one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if BatteryMonitor.hasBattery {
                Section {
                    Toggle("Show when charging starts", isOn: $settings.chargingActivity)
                    Toggle("Warn when the battery is low", isOn: $settings.lowBatteryActivity)
                } header: {
                    Text("Battery")
                } footer: {
                    Text("The notch shows your battery level for a few seconds when you plug in, and at 20% and 10% on battery.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show when headphones connect", isOn: $settings.deviceActivity)
            } header: {
                Text("Audio")
            } footer: {
                Text("When AirPods, other headphones or a speaker connect and start playing your sound, the notch shows them for a few seconds, with their battery level when they report one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            AgentsSection(settings: settings)

            Section {
                Toggle("Show when the Mac asks for Touch ID", isOn: $settings.touchIDActivity)
            } header: {
                Text("Touch ID")
            } footer: {
                Text("When an app, a password or sudo asks for your fingerprint, the notch drops down with it, and shows a checkmark once your finger is accepted. On the lock screen, a fingerprint sits beside the padlock.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show when Caps Lock turns on or off", isOn: Binding(get: { settings.capsLockActivity }, set: { on in
                    settings.capsLockActivity = on
                    if on && !NotificationWatcher.shared.isTrusted { NotificationWatcher.shared.requestAccess() }
                }))
                Toggle("Show when a drive connects", isOn: $settings.driveActivity)
                Toggle("Show when a Focus turns on or off", isOn: Binding(get: { settings.focusActivity }, set: { on in
                    settings.focusActivity = on
                    if on && !FocusMonitor.shared.hasAccess { FocusMonitor.shared.openPrivacySettings() }
                }))
            } header: {
                Text("Keyboard, Drives and Focus")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.focusActivity && !FocusMonitor.shared.hasAccess {
                        HStack(spacing: 4) {
                            Text("Seeing Focus needs Full Disk Access: drag Shima into the list, then reopen it.")
                            Button("Open Privacy Settings…") { FocusMonitor.shared.openPrivacySettings() }
                                .buttonStyle(.link)
                        }
                    }
                    if settings.capsLockActivity && !NotificationWatcher.shared.isTrusted {
                        Text("Seeing Caps Lock needs Accessibility access, in Privacy & Security.")
                    }
                    Text("A drive's banner has an Eject button, and tells you when it's safe to disconnect. Focus shows when it's turned on or off by hand.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NowPlayingPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show what's playing when closed", isOn: $settings.showMusicWhenClosed)
                Picker("Waveform color", selection: $settings.waveformColor) {
                    ForEach(WaveformColor.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Works with Music, Spotify, web browsers, and any app that appears in Now Playing in Control Center.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationsPane: View {
    @Bindable var settings: AppSettings
    let watcher: NotificationWatcher

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications in the notch", isOn: Binding(get: { settings.notifications }, set: { turnOn in
                    settings.notifications = turnOn
                    if turnOn && !watcher.isTrusted { watcher.requestAccess() }
                }))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.notifications && !watcher.isTrusted {
                        HStack(spacing: 4) {
                            Text("Shima needs Accessibility access to see notifications.")
                            Button("Open Privacy Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Text("Notifications appear below the notch instead of in the corner; click one to open it. They still collect in Notification Center as usual, and alerts that wait for you, like reminders, stay where they are. Shima reads them through Accessibility; nothing leaves your Mac.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalendarPane: View {
    @Bindable var settings: AppSettings
    let calendar: CalendarMonitor

    private var accessRefused: Bool { [.denied, .restricted, .writeOnly].contains(calendar.access) }

    var body: some View {
        Form {
            Section {
                CalendarAccessToggle(title: "Show upcoming events", setting: \.calendarActivity,
                                     settings: settings, calendar: calendar)
                Picker("Show", selection: $settings.calendarLeadMinutes) {
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                }
                .disabled(!(settings.calendarActivity && calendar.hasAccess))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if accessRefused {
                        HStack(spacing: 4) {
                            Text("Shima doesn't have access to your calendars.")
                            Button("Open Privacy Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Text("A few minutes before an event starts, the notch shows its title and a countdown. All-day events and invitations you've declined aren't shown. The Calendar page is turned on in Notch → Pages.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A toggle for a calendar feature; turning it on asks for Calendar access the first time.
/// One display: whether it shows the notch, and in which style (where there's a choice).
private struct DisplayRow: View {
    let display: DisplayInfo
    @Bindable var settings: AppSettings

    private var preference: DisplayPreference { settings.preference(for: display.key) }

    /// What the name doesn't say.
    private var caption: String {
        [display.isMain ? "Main display" : nil, display.hasCameraNotch ? "Camera notch" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Toggle(isOn: Binding(get: { preference.shown },
                             set: { shown in settings.updatePreference(for: display.key) { $0.shown = shown } })) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                    if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
            }
        }
        if preference.shown && !display.hasCameraNotch {
            Picker("Style", selection: Binding(get: { preference.style },
                                               set: { style in settings.updatePreference(for: display.key) { $0.style = style } })) {
                ForEach(NotchStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.leading, 28)
        }
    }
}

/// Where the Weather page's forecast is for: the Mac's location, or a city.
private struct WeatherLocationSection: View {
    @Bindable var settings: AppSettings
    @Bindable var form = WeatherForm()

    var body: some View {
        Section {
            Picker("Location", selection: Binding(get: { settings.weatherCity == nil }, set: { useHere in
                if useHere {
                    settings.weatherCity = nil
                    WeatherMonitor.shared.requestLocation()
                } else {
                    form.choosing = true
                }
            })) {
                Text("Current Location").tag(true)
                Text(settings.weatherCity?.name ?? "A City…").tag(false)
            }
            if form.choosing || settings.weatherCity != nil {
                HStack {
                    TextField("City", text: $form.city, prompt: Text(settings.weatherCity?.name ?? "Barcelona"))
                        .onSubmit(search)
                    Button("Use", action: search).disabled(form.city.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Weather")
        } footer: {
            Text(form.notFound
                 ? "No city by that name was found."
                 : "Forecasts come from Open-Meteo, free and without an account. Only a rounded location is sent, and only when the notch opens with a forecast more than 15 minutes old.")
                .font(.footnote)
                .foregroundStyle(form.notFound ? .red : .secondary)
        }
    }

    private func search() {
        let name = form.city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        WeatherMonitor.shared.search(city: name) { found in
            form.notFound = !found
            if found { form.city = ""; form.choosing = false }
        }
    }
}

@Observable
final class WeatherForm {
    var city = ""
    var choosing = false
    var notFound = false
}

/// Coding agents: connecting Claude Code and Codex adds Shima's hook to their settings.
private struct AgentsSection: View {
    @Bindable var settings: AppSettings
    @Bindable var state = AgentsSectionState()

    var body: some View {
        Section {
            Toggle("Show coding agents", isOn: $settings.agentActivity)
            row("Claude Code", installed: AgentConnection.hasClaude, connected: state.claude) { connect in
                try AgentConnection.setClaude(connected: connect)
            }
            row("Codex", installed: AgentConnection.hasCodex, connected: state.codex) { connect in
                try AgentConnection.setCodex(connected: connect)
            }
        } header: {
            Text("Coding Agents")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = state.error { Text(error).foregroundStyle(.red) }
                Text("While Claude Code or Codex works, the notch shows the project and how long it's been going. It tells you when one needs your permission, and when it's done; click to go back to it. Connecting adds a small hook to the agent's settings, which Disconnect takes out again. Nothing leaves your Mac.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, installed: Bool, connected: Bool, set: @escaping (Bool) throws -> Void) -> some View {
        LabeledContent(name) {
            if !installed && !connected {
                Text("Not installed").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if connected { Label("Connected", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green) }
                    Button(connected ? "Disconnect" : "Connect") {
                        do {
                            try set(!connected)
                            state.error = nil
                        } catch {
                            state.error = "Couldn't change \(name)'s settings: \(error.localizedDescription)"
                        }
                        state.reload()
                    }
                }
            }
        }
    }
}

@Observable
final class AgentsSectionState {
    var claude = AgentConnection.isClaudeConnected
    var codex = AgentConnection.isCodexConnected
    var error: String?

    func reload() {
        claude = AgentConnection.isClaudeConnected
        codex = AgentConnection.isCodexConnected
    }
}

private struct CalendarAccessToggle: View {
    let title: String
    let setting: ReferenceWritableKeyPath<AppSettings, Bool>
    let settings: AppSettings
    let calendar: CalendarMonitor
    var symbol: String?

    var body: some View {
        Toggle(isOn: Binding(get: { settings[keyPath: setting] && calendar.hasAccess }, set: { turnOn in
            guard turnOn else { return settings[keyPath: setting] = false }
            if calendar.hasAccess {
                settings[keyPath: setting] = true
            } else {
                calendar.requestAccess { granted in settings[keyPath: setting] = granted }
            }
        })) {
            if let symbol {
                Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20) }
            } else {
                Text(title)
            }
        }
    }
}

private struct ShelfPane: View {
    @Bindable var settings: AppSettings
    let shelf: ShelfStore

    var body: some View {
        Form {
            Section {
                Toggle("AirDrop when dropping files", isOn: $settings.airDropTarget)
                    .disabled(!settings.shelfEnabled)
            } footer: {
                Text(settings.shelfEnabled
                     ? "Drag files to the notch to keep them on the shelf for later, or to AirDrop them. The shelf keeps a reference to each file, not a copy."
                     : "The Shelf is off. Turn it on in Notch → Pages.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("On the shelf") {
                    Text(shelf.items.count == 1 ? "1 file" : "\(shelf.items.count) files")
                        .monospacedDigit()
                }
                Button("Clear Shelf", role: .destructive) { shelf.clear() }
                    .disabled(shelf.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text("Shima")
                        .font(.title2.weight(.semibold))
                    Text("Version \(version)")
                        .foregroundStyle(.secondary)
                    Text("Your Mac's notch, put to work: what's playing, a shelf for files, and the lock screen.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("Acknowledgements") {
                Text("Showing over the lock screen uses the technique from SkyLightWindow by Lakr Aream (MIT License).")
                Text("Reading Now Playing on current macOS follows the approach of the open-source mediaremote-adapter project.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Opens System Settings → General → Login Items.
enum SMAppServiceSettings {
    static func open() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Debug aid: `SHIMA_SETTINGS_SNAPSHOT=<dir> Shima` renders every Settings pane, from a real window
/// placed off-screen, to <pane>.png and exits.
enum SettingsSnapshot {
    private static var controller: SettingsWindowController?

    static func run(settings: AppSettings, shelf: ShelfStore, calendar: CalendarMonitor) {
        guard let directory = ProcessInfo.processInfo.environment["SHIMA_SETTINGS_SNAPSHOT"] else { return }
        let controller = SettingsWindowController(settings: settings, shelf: shelf, calendar: calendar)
        self.controller = controller
        controller.renderPanes(to: URL(fileURLWithPath: directory)) { exit(0) }
    }
}

extension SettingsWindowController {
    func renderPanes(to directory: URL, done: @escaping () -> Void) {
        show(.general)
        window?.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        for (index, pane) in SettingsPane.allCases.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(index) * 0.6) { [weak self] in
                guard let self else { return }
                self.navigation.pane = pane
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    // Render the layer tree: unlike cacheDisplay, it includes the sidebar's rows.
                    guard let view = self.window?.contentView?.superview, let layer = view.layer else { return }
                    let scale = self.window?.backingScaleFactor ?? 2
                    let size = view.bounds.size
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
                    context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                    context.scaleBy(x: scale, y: scale)
                    if view.isFlipped {
                        context.translateBy(x: 0, y: size.height)
                        context.scaleBy(x: 1, y: -1)
                    }
                    layer.render(in: context)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("\(pane.rawValue).png"))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(SettingsPane.allCases.count) * 0.6 + 0.3, execute: done)
    }
}
