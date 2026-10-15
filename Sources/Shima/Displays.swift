import AppKit
import Observation

/// A connected display, as Settings lists it.
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    /// Lasting across reconnections, for remembering its settings.
    let key: String
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
    let hasCameraNotch: Bool
}

/// The displays connected now, kept current as they come and go.
@Observable
final class ConnectedDisplays {
    static let shared = ConnectedDisplays()

    private(set) var all: [DisplayInfo] = []

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let displays = NSScreen.screens.enumerated().map { index, screen in
            DisplayInfo(id: screen.displayID, key: screen.displayKey, name: screen.localizedName,
                        isBuiltIn: CGDisplayIsBuiltin(screen.displayID) != 0, isMain: index == 0,
                        hasCameraNotch: screen.safeAreaInsets.top > 0)
        }
        if displays != all { all = displays }
    }
}

extension NSScreen {
    /// The display's ID, which stays the same while it's connected.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The display's lasting ID, the same each time it's connected.
    var displayKey: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
