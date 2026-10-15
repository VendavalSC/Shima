import AppKit
import DiskArbitration
import SwiftUI

/// A quick status over the closed notch: a symbol and a word on one side, a state on the other
/// ("Caps Lock" / "On").
struct StatusAlert: Equatable {
    let symbol: String
    let title: String
    let state: String
    /// The state reads as on (tinted) rather than off.
    let isOn: Bool
    /// The tint when on: green for Caps Lock, a Focus's own color.
    var tint: Color = .green
    let id = UUID()
}

/// A drive that just connected (with an Eject button), or was just ejected.
struct DriveAlert: Equatable {
    enum Phase: Equatable { case connected, ejecting, ejected, inUse }

    let name: String
    let url: URL
    let symbol: String
    var phase: Phase
    let id = UUID()
}

/// Caps Lock turning on and off, from the system's modifier-key events. Seeing other apps' key
/// events takes Accessibility, which Shima asks for with notifications; without it this stays quiet.
final class CapsLockMonitor {
    var onChange: ((Bool) -> Void)?
    private var monitors: [Any] = []
    private var isOn = NSEvent.modifierFlags.contains(.capsLock)

    init() {
        start()
        // Events only arrive once Accessibility is granted; listen again when it is.
        trackChanges { [weak self] in
            _ = NotificationWatcher.shared.isTrusted
            DispatchQueue.main.async { self?.start() }
        }
    }

    private func start() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let handle: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event.modifierFlags) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let on = flags.contains(.capsLock)
        guard on != isOn else { return }
        isOn = on
        Log.activity.info("caps lock \(on ? "on" : "off", privacy: .public)")
        guard AppSettings.shared.capsLockActivity else { return }
        onChange?(on)
    }
}

/// External drives and SD cards mounting and unmounting. Disk images and network volumes don't count.
final class DriveMonitor {
    var onConnect: ((DriveAlert) -> Void)?
    var onEject: ((DriveAlert) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let session = DASessionCreate(kCFAllocatorDefault)

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, AppSettings.shared.driveActivity, let drive = self.drive(from: note) else { return }
            self.onConnect?(drive)
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, AppSettings.shared.driveActivity,
                  let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  let name = note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String,
                  self.ejected.contains(url) || self.connected.contains(url) else { return }
            self.connected.remove(url)
            // Shima's own Eject reports this itself.
            if self.ejected.remove(url) == nil {
                self.onEject?(DriveAlert(name: name, url: url, symbol: "eject.fill", phase: .ejected))
            }
        })
    }

    /// Drives seen connecting (only their unmounting is announced), and ones Shima is ejecting.
    private var connected: Set<URL> = []
    private var ejected: Set<URL> = []

    private func drive(from note: Notification) -> DriveAlert? {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let name = note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String,
              let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let info = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let isInternal = info[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
        let deviceProtocol = info[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        let model = info[kDADiskDescriptionDeviceModelKey as String] as? String ?? ""
        let network = info[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false
        // Disk images report a virtual interface (or the "Disk Image" model). For testing without a
        // drive, SHIMA_DEMO_DRIVES counts them.
        let images = ProcessInfo.processInfo.environment["SHIMA_DEMO_DRIVES"] != nil
        let image = deviceProtocol == "Virtual Interface" || model.contains("Disk Image")
        Log.activity.info("volume mounted: \(deviceProtocol, privacy: .public), internal \(isInternal, privacy: .public), image \(image, privacy: .public)")
        guard !network, !image || images, !isInternal || deviceProtocol == "Secure Digital" || images else { return nil }
        connected.insert(url)
        let symbol = deviceProtocol == "Secure Digital" ? "sdcard.fill" : "externaldrive.fill"
        return DriveAlert(name: name, url: url, symbol: symbol, phase: .connected)
    }

    /// Ejects the drive, as Finder's Eject would; `completion` says whether it's safe to disconnect.
    func eject(_ drive: DriveAlert, completion: @escaping (Bool) -> Void) {
        ejected.insert(drive.url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let done = (try? NSWorkspace.shared.unmountAndEjectDevice(at: drive.url)) != nil
            Log.activity.info("eject: \(done ? "done" : "in use", privacy: .public)")
            DispatchQueue.main.async {
                if !done { self?.ejected.remove(drive.url) }
                completion(done)
            }
        }
    }
}
