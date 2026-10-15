import AppKit
import CoreAudio
import Observation

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let uid: String?

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Worth announcing when it connects: headphones and speakers, not virtual or aggregate devices.
    var isAccessory: Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            return name.localizedCaseInsensitiveContains("Headphones")
        default:
            return false
        }
    }

    /// The Bluetooth address, from the device's UID ("70-8C-F2-8E-72-21:output").
    var bluetoothAddress: String? {
        guard isBluetooth, let uid else { return nil }
        let address = uid.prefix(17).replacingOccurrences(of: "-", with: ":").uppercased()
        return address.count == 17 ? address : nil
    }

    /// The name without its owner: "AirPods Pro" rather than "Alonso’s AirPods Pro".
    var shortName: String {
        for product in ["AirPods Max", "AirPods Pro", "AirPods"] where name.localizedCaseInsensitiveContains(product) {
            return product
        }
        if let owner = name.range(of: #"^.+?['’]s "#, options: .regularExpression) {
            return String(name[owner.upperBound...])
        }
        return name
    }

    /// The glyph for the player's output button, following what the device is.
    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return name.localizedCaseInsensitiveContains("Headphones") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.localizedCaseInsensitiveContains("AirPods Max") { return "airpodsmax" }
            if name.localizedCaseInsensitiveContains("AirPods Pro") { return "airpodspro" }
            if name.localizedCaseInsensitiveContains("AirPods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        default:
            return "hifispeaker"
        }
    }
}

/// The system's audio outputs: which one is current (kept live), and a menu to switch between them.
/// Also notices headphones or a speaker connecting and taking over the sound, through CoreAudio's
/// notifications (no polling, no permissions).
@Observable
final class AudioOutputController {
    private(set) var current: AudioOutputDevice?
    /// A device that just connected became the output.
    @ObservationIgnored var onConnect: ((AudioOutputDevice) -> Void)?

    @ObservationIgnored private let menuTarget = MenuTarget()
    @ObservationIgnored private var known: Set<AudioDeviceID> = []
    @ObservationIgnored private var arrivals: [AudioDeviceID: Date] = [:]

    /// A new device counts as just connected if it becomes the output within this long of appearing.
    private static let arrivalWindow: TimeInterval = 5

    init() {
        known = Set(Self.outputDevices().map(\.id))
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        var output = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &output, .main) { [weak self] _, _ in
            self?.refresh()
        }
        var devices = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(system, &devices, .main) { [weak self] _, _ in
            self?.devicesChanged()
        }
    }

    private func devicesChanged() {
        let ids = Set(Self.outputDevices().map(\.id))
        for id in ids.subtracting(known) { arrivals[id] = Date() }
        arrivals = arrivals.filter { ids.contains($0.key) }
        known = ids
        refresh()
    }

    /// Announces the current output if it only just appeared (it may become the output before or
    /// after the device list changes).
    private func announceIfNew() {
        guard let current, let arrived = arrivals[current.id] else { return }
        arrivals[current.id] = nil
        if Date().timeIntervalSince(arrived) < Self.arrivalWindow, current.isAccessory { onConnect?(current) }
    }

    /// Pops up a menu of output devices at the pointer; blocks until the menu closes.
    func showMenu() {
        let menu = NSMenu()
        let currentID = Self.defaultOutputID()
        for device in Self.outputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = menuTarget
            item.tag = Int(device.id)
            item.state = device.id == currentID ? .on : .off
            item.image = NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Sound Settings…", action: #selector(MenuTarget.openSoundSettings), keyEquivalent: "")
        settings.target = menuTarget
        menu.addItem(settings)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func refresh() {
        let id = Self.defaultOutputID()
        let device = Self.outputDevices().first { $0.id == id }
        if device != current { current = device }
        announceIfNew()
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputID() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    static func outputDevices() -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else {
                return nil
            }
            return AudioOutputDevice(id: id, name: string(kAudioObjectPropertyName, of: id) ?? "Output",
                                     transport: transport(of: id), uid: string(kAudioDevicePropertyDeviceUID, of: id))
        }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = address(selector)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }
}

private final class MenuTarget: NSObject {
    @objc func pick(_ item: NSMenuItem) {
        AudioOutputController.setDefaultOutput(AudioDeviceID(item.tag))
    }

    @objc func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
