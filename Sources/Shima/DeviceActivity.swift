import AVFoundation
import AppKit
import SwiftUI

/// Headphones or a speaker that just connected. It announces itself in a banner below the notch
/// (the spinning product, "Connected", the name, battery ring), then settles into the wings
/// (product and ring) before it goes.
struct DeviceAlert: Equatable {
    let symbol: String
    let name: String
    /// 0...100, once known. For AirPods, the lower of the two buds.
    var battery: Int?
    /// Still asking for the battery level (Bluetooth devices report it a moment after connecting).
    var awaitingBattery = false
    /// The system's own spinning video of the product, when it has one; otherwise `symbol` shows.
    var spin: URL?
    /// Showing the banner rather than the wings.
    var isBanner = true
    /// Bumped to bounce the symbol once the banner has appeared.
    var bounces = 0
    let id = UUID()
}

/// What System Information knows about connected Bluetooth headphones: the battery level and the
/// product. The system gathers these from the devices itself; asking takes a tenth of a second and
/// needs no permission.
enum BluetoothInfo {
    struct Device {
        let name: String
        let address: String?
        let level: Int?
        let productID: Int?
        /// Resolved off the main thread along with the rest.
        var spin: URL? { productID.flatMap(ProductSpin.url) }
    }

    /// Looks the device up; `completion` runs on the main thread with its details and spin video.
    static func lookup(address: String?, name: String, completion: @escaping (Device?, URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let device = read().first { device in
                if let address, device.address == address { return true }
                return device.name == name
            }
            let spin = device?.spin
            Log.device.info("""
                lookup: found \(device != nil, privacy: .public), product \(device?.productID ?? 0, privacy: .public), \
                battery \(device?.level ?? -1, privacy: .public), spin \(spin?.lastPathComponent ?? "none", privacy: .public)
                """)
            DispatchQueue.main.async { completion(device, spin) }
        }
    }

    private static func read() -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        // The full report: the quicker "mini" one leaves out connected devices' product IDs.
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        return controllers.flatMap { controller in
            (controller["device_connected"] as? [[String: [String: Any]]] ?? []).flatMap { entry in
                entry.map { name, info in
                    Device(name: name, address: (info["device_address"] as? String)?.uppercased(), level: level(info),
                           productID: (info["device_productID"] as? String).flatMap(hex))
                }
            }
        }
    }

    private static func level(_ info: [String: Any]) -> Int? {
        func percent(_ key: String) -> Int? {
            (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        }
        let buds = [percent("device_batteryLevelLeft"), percent("device_batteryLevelRight")].compactMap { $0 }
        return buds.min() ?? percent("device_batteryLevelMain")
    }

    static func hex(_ string: String) -> Int? {
        Int(string.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
    }
}

/// The spinning product videos macOS shows when AirPods or Beats connect: one transparent loop per
/// model, part of the system. Shima plays them from where they are; nothing is copied.
enum ProductSpin {
    private static let movies = URL(fileURLWithPath: "/System/Library/CoreServices/BluetoothUIService.app/Contents/Resources")
    private static let assetPaths = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/CoreBluetoothUI.framework/Versions/A/Resources")

    static func url(productID: Int) -> URL? {
        if let url = loop(for: productID) { return url }
        // A newer revision (USB-C rather than Lightning, say) may share an older one's artwork,
        // and with it the loop.
        guard let image = imageNames[productID] else { return nil }
        for (other, name) in imageNames.sorted(by: { $0.key < $1.key }) where name == image && other != productID {
            if let url = loop(for: other) { return url }
        }
        return nil
    }

    private static func loop(for productID: Int) -> URL? {
        let folder = movies.appendingPathComponent("Banner-PID-\(productID)-mov")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let preferred = ["Banner-PID-\(productID)-Loop.mov", "Banner-PID-\(productID)-default-Loop.mov"]
        let name = preferred.first(where: files.contains) ?? files.sorted().first { $0.hasSuffix("-Loop.mov") }
        return name.map { folder.appendingPathComponent($0) }
    }

    /// Product ID → artwork name, from the system's table of Bluetooth product images.
    private static let imageNames: [Int: String] = {
        var names: [Int: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: assetPaths.path)) ?? []
        for file in files where file.hasPrefix("AssetPaths") && file.hasSuffix(".plist") {
            guard let table = NSDictionary(contentsOf: assetPaths.appendingPathComponent(file)) as? [String: Any] else { continue }
            for (key, value) in table {
                guard let id = BluetoothInfo.hex(key), let image = (value as? [String: Any])?["ImageName"] as? String else { continue }
                names[id] = names[id] ?? image
            }
        }
        return names
    }()
}

/// The product: its spinning video when the system has one, its symbol otherwise.
struct DeviceArt: View {
    let alert: DeviceAlert
    let size: CGFloat

    var body: some View {
        if let spin = alert.spin {
            LoopingVideo(url: spin)
                .frame(width: size, height: size)
        } else {
            Image(systemName: alert.symbol)
                .font(.system(size: size * 0.55, weight: .regular))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, options: .nonRepeating, value: alert.bounces)
                .frame(width: size, height: size)
        }
    }
}

/// A silent, transparent video on a loop, decoded by the hardware; it stops when it leaves the screen.
struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingVideoView { LoopingVideoView(url: url) }
    func updateNSView(_ view: LoopingVideoView, context: Context) {}
    static func dismantleNSView(_ view: LoopingVideoView, coordinator: ()) { view.stop() }
}

final class LoopingVideoView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL) {
        super.init(frame: .zero)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        self.layer = layer
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    required init?(coder: NSCoder) { nil }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}
