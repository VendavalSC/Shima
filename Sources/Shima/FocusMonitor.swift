import AppKit
import Observation
import SwiftUI

/// A Focus, as its settings describe it.
struct FocusMode: Equatable {
    let id: String
    let name: String
    let symbol: String
    let color: Color
}

/// Focus turning on and off. macOS keeps the active Focus in a file only readable with Full Disk
/// Access, so this is opt-in: with access, Shima watches the folder and is told the moment it
/// changes (nothing polls). Focus turned on or off by hand shows up; schedules may not.
@Observable
final class FocusMonitor {
    static let shared = FocusMonitor()

    /// A Focus turned on (true) or off (false).
    @ObservationIgnored var onChange: ((FocusMode, Bool) -> Void)?
    /// Shima can read the Focus files (Full Disk Access is granted).
    private(set) var hasAccess = false

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var active: FocusMode?
    @ObservationIgnored private var watching = false

    private static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB")
    private static let assertions = folder.appendingPathComponent("Assertions.json")
    private static let modes = folder.appendingPathComponent("ModeConfigurations.json")

    private init() {
        trackChanges { [weak self] in
            _ = AppSettings.shared.focusActivity
            DispatchQueue.main.async { self?.update() }
        }
    }

    /// Looks again for access (after it's granted in System Settings) and starts if it's there.
    func update() {
        let wanted = AppSettings.shared.focusActivity
        let readable = (try? Data(contentsOf: Self.assertions)) != nil
        if readable != hasAccess { hasAccess = readable }
        if wanted && readable { start() } else { stop() }
    }

    /// Opens Full Disk Access in System Settings, and shows Shima in Finder to drag into the list.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func start() {
        guard !watching else { return }
        let descriptor = open(Self.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watching = true
        active = Self.activeMode()   // what's on already isn't news
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        Log.activity.info("focus: watching")
    }

    private func stop() {
        source?.cancel()
        source = nil
        watching = false
    }

    /// The file is rewritten in a few steps; read it once they've settled.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Self.activeMode()
            guard now != self.active else { return }
            let previous = self.active
            self.active = now
            Log.activity.info("focus: \(now?.id ?? "off", privacy: .public)")
            if let now { self.onChange?(now, true) } else if let previous { self.onChange?(previous, false) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Reading the files

    /// The Focus that's on, if any: the mode of the newest active assertion.
    private static func activeMode() -> FocusMode? {
        guard let data = try? Data(contentsOf: assertions),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let records = values(forKey: "storeAssertionRecords", in: json).compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
        let newest = records.max { ($0["assertionStartDateTimestamp"] as? Double ?? 0) < ($1["assertionStartDateTimestamp"] as? Double ?? 0) }
        guard let newest, let id = values(forKey: "assertionDetailsModeIdentifier", in: newest).first as? String else { return nil }
        return mode(id)
    }

    /// A Focus's name, symbol and color from its settings, or Do Not Disturb's look.
    private static func mode(_ id: String) -> FocusMode {
        let fallback = FocusMode(id: id, name: "Focus", symbol: "moon.fill", color: .indigo)
        guard let data = try? Data(contentsOf: modes), let json = try? JSONSerialization.jsonObject(with: data),
              let configuration = values(forKey: id, in: json).first as? [String: Any],
              let mode = configuration["mode"] as? [String: Any] else {
            return id.hasSuffix(".default") ? FocusMode(id: id, name: "Do Not Disturb", symbol: "moon.fill", color: .indigo) : fallback
        }
        return FocusMode(id: id, name: mode["name"] as? String ?? fallback.name,
                         symbol: mode["symbolImageName"] as? String ?? fallback.symbol,
                         color: color(named: mode["tintColorName"] as? String))
    }

    private static func color(named name: String?) -> Color {
        let colors: [String: Color] = [
            "systemIndigoColor": .indigo, "systemPurpleColor": .purple, "systemBlueColor": .blue, "systemTealColor": .teal,
            "systemCyanColor": .cyan, "systemMintColor": .mint, "systemGreenColor": .green, "systemYellowColor": .yellow,
            "systemOrangeColor": .orange, "systemRedColor": .red, "systemPinkColor": .pink, "systemBrownColor": .brown,
            "systemGrayColor": .gray,
        ]
        return name.flatMap { colors[$0] } ?? .indigo
    }

    /// Every value stored under `key`, anywhere in the JSON.
    private static func values(forKey key: String, in json: Any) -> [Any] {
        if let dictionary = json as? [String: Any] {
            return (dictionary[key].map { [$0] } ?? []) + dictionary.values.flatMap { values(forKey: key, in: $0) }
        }
        if let array = json as? [Any] { return array.flatMap { values(forKey: key, in: $0) } }
        return []
    }
}
