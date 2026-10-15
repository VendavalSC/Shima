import Foundation
import IOKit.ps

/// A brief battery event worth showing in the notch.
struct BatteryAlert: Equatable {
    enum Kind: Equatable {
        case charging   // power connected
        case low        // crossed 20% or 10% on battery
    }

    let kind: Kind
    let level: Int
    let isCharging: Bool
    let id = UUID()
}

/// Watches the internal battery through the system's power-source notifications (no polling, no
/// permissions) and reports plugging in and low battery. Silent on Macs without a battery.
final class BatteryMonitor {
    struct Reading: Equatable {
        let level: Int
        let isCharging: Bool
        let onPower: Bool
    }

    var onAlert: ((BatteryAlert) -> Void)?
    private(set) var reading: Reading?
    private var source: CFRunLoopSource?

    static var hasBattery: Bool { read() != nil }

    init() {
        reading = Self.read()
        guard reading != nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().powerChanged()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func powerChanged() {
        guard let now = Self.read() else { return }
        let before = reading
        reading = now
        guard let before else { return }
        let settings = AppSettings.shared

        if !before.onPower, now.onPower, settings.chargingActivity {
            onAlert?(BatteryAlert(kind: .charging, level: now.level, isCharging: now.isCharging))
        } else if !now.onPower, settings.lowBatteryActivity,
                  [20, 10].contains(where: { before.level > $0 && now.level <= $0 }) {
            onAlert?(BatteryAlert(kind: .low, level: now.level, isCharging: false))
        }
    }

    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return Reading(level: Int((Double(current) / Double(maximum) * 100).rounded()),
                           isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                           onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}
