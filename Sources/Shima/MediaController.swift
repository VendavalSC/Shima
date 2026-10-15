import AppKit
import Observation
import SwiftUI

/// Live Now Playing state, fed by the perl-hosted MediaRemote bridge (Helper/ShimaMedia.m).
@Observable
final class MediaController {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var artworkKey = ""
    /// The artwork's colors, top and bottom, lifted to read well on black; the waveform fades from
    /// one to the other, as on iPhone. White without artwork.
    private(set) var accentColors = MediaController.plainColors
    private(set) var bundleID = ""

    /// Elapsed time at `anchorDate`; while playing, time advances from there at `rate`.
    private var elapsedAnchor: Double = 0
    private var anchorDate = Date()
    private var rate: Double = 1

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var stopped = false

    var hasMedia: Bool { !title.isEmpty }
    /// The waveform's colors, top to bottom: the artwork's, or white, per Settings.
    var waveformColors: [Color] {
        AppSettings.shared.waveformColor == .artwork ? accentColors : Self.plainColors
    }
    static let plainColors = [Color.white.opacity(0.85), Color.white.opacity(0.85)]
    var trackKey: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    func elapsed(at date: Date) -> Double {
        var value = elapsedAnchor
        if isPlaying { value += date.timeIntervalSince(anchorDate) * rate }
        return duration > 0 ? min(max(value, 0), duration) : max(value, 0)
    }

    // MARK: Commands

    func togglePlayPause() {
        reanchor()
        isPlaying.toggle()
        send("toggle")
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func seek(to seconds: Double) {
        elapsedAnchor = seconds
        anchorDate = Date()
        send("seek \(seconds)")
    }

    func openSourceApp() {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Bridge process

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        try? input?.close()
        process?.terminate()
    }

    private static let perlScript = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "load: " . DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "shima_media_run") or die "symbol missing";
    DynaLoader::dl_install_xsub("main::run", $sym);
    run();
    """

    private var bridgeURL: URL? {
        if let bundled = Bundle.main.url(forResource: "libshimamedia", withExtension: "dylib") { return bundled }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("libshimamedia.dylib")
        return sibling.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private func launch() {
        guard let bridgeURL else {
            NSLog("Shima: libshimamedia.dylib not found; Now Playing disabled")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.perlScript, bridgeURL.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.standardError

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self, !self.stopped else { return }
                self.launch()
            }
        }

        do {
            try process.run()
        } catch {
            NSLog("Shima: could not start media bridge: \(error)")
            return
        }
        buffer.removeAll()
        self.process = process
        self.input = input.fileHandleForWriting
    }

    private func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            apply(Data(line))
        }
    }

    private func apply(_ line: Data) {
        guard let state = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }

        title = state["title"] as? String ?? ""
        artist = state["artist"] as? String ?? ""
        album = state["album"] as? String ?? ""
        duration = state["duration"] as? Double ?? 0
        bundleID = state["bundle"] as? String ?? ""
        isPlaying = state["playing"] as? Bool ?? false

        let reportedRate = state["rate"] as? Double ?? 0
        rate = reportedRate > 0 ? reportedRate : 1
        elapsedAnchor = state["elapsed"] as? Double ?? 0
        let timestamp = state["timestamp"] as? Double ?? 0
        anchorDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : Date()

        if let encoded = state["artwork"] as? String {
            artwork = Data(base64Encoded: encoded).flatMap(NSImage.init(data:))
            artworkKey = state["artworkKey"] as? String ?? ""
            accentColors = artwork.flatMap(Self.accents(of:)) ?? Self.plainColors
        }
    }

    /// The artwork's colors for the waveform, from a 12x12 downsample: the vivid color of the top
    /// half over that of the bottom half (a blue sky over a yellow field gives blue over yellow). Each
    /// keeps its hue but is made vivid and bright enough to read on black. One color twice when the
    /// halves agree; nil for grayscale art.
    private static func accents(of image: NSImage) -> [Color]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Rows run top to bottom in the buffer.
        let half = side * side * 4 / 2
        let top = vividAverage(pixels[0..<half]), bottom = vividAverage(pixels[half...])
        let whole = vividAverage(pixels[...])
        guard let whole else { return nil }
        guard let top, let bottom, distance(top, bottom) > 0.18 else { return [lifted(whole), lifted(whole)] }
        return [lifted(top), lifted(bottom)]
    }

    /// The average color, weighted toward vivid pixels so a splash of color outweighs a gray or dark
    /// background. Nil when there's no color to speak of.
    private static func vividAverage(_ pixels: ArraySlice<UInt8>) -> NSColor? {
        var sum = (r: 0.0, g: 0.0, b: 0.0, weight: 0.0)
        var index = pixels.startIndex
        while index + 3 < pixels.endIndex + 1 {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high - low) / high : 0
            let weight = saturation * high + 0.02
            sum = (sum.r + r * weight, sum.g + g * weight, sum.b + b * weight, sum.weight + weight)
            index += 4
        }
        guard sum.weight > 0 else { return nil }
        let color = NSColor(srgbRed: sum.r / sum.weight, green: sum.g / sum.weight, blue: sum.b / sum.weight, alpha: 1)
        return color.saturationComponent > 0.08 ? color : nil
    }

    private static func lifted(_ color: NSColor) -> Color {
        Color(hue: color.hueComponent, saturation: max(color.saturationComponent, 0.5),
              brightness: max(color.brightnessComponent, 0.9))
    }

    /// How different two colors look, roughly: hue around the circle, weighted by how colorful they are.
    private static func distance(_ a: NSColor, _ b: NSColor) -> Double {
        let hue = abs(a.hueComponent - b.hueComponent)
        let around = min(hue, 1 - hue) * 2   // 0...1
        return around * min(a.saturationComponent, b.saturationComponent) + abs(a.brightnessComponent - b.brightnessComponent) * 0.3
    }

    /// Fixed state for snapshots, with a placeholder cover.
    func loadSample(title: String, artist: String, duration: Double, elapsed: Double, playing: Bool) {
        self.title = title
        self.artist = artist
        self.duration = duration
        elapsedAnchor = elapsed
        anchorDate = Date()
        isPlaying = playing
        artworkKey = "sample"
        let cover = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            // A sky over a field: blue on top, yellow below.
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.80, blue: 0.20, alpha: 1),
                                NSColor(srgbRed: 0.35, green: 0.70, blue: 0.95, alpha: 1)])?.draw(in: rect, angle: 90)
            return true
        }
        artwork = cover
        accentColors = Self.accents(of: cover) ?? Self.plainColors
    }

    private func reanchor() {
        elapsedAnchor = elapsed(at: Date())
        anchorDate = Date()
    }
}
