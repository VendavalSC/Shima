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

    /// The artwork's colors for the waveform, top to bottom: its two most prominent colors that are
    /// clearly different hues, the one that sits higher in the artwork on top (a blue sky over a
    /// yellow field gives blue over yellow). Art with a single color gets that color under a lighter,
    /// slightly shifted tint of it, so there's always a gradient. Each keeps its hue but is made vivid
    /// and bright enough to read on black. Nil for grayscale art.
    static func accents(of image: NSImage) -> [Color]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 16
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

        // Colorful pixels by hue, in twelve slices of the color wheel; rows run top to bottom.
        struct Slice { var weight = 0.0, r = 0.0, g = 0.0, b = 0.0, row = 0.0 }
        var slices = [Slice](repeating: Slice(), count: 12)
        for row in 0..<side {
            for column in 0..<side {
                let i = (row * side + column) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                let saturation = color.saturationComponent, brightness = color.brightnessComponent
                // Dark tints count too, for a little: they matter when the art has nothing brighter.
                guard saturation > 0.18, brightness > 0.03 else { continue }
                let weight = saturation * max(brightness, 0.25)
                let k = min(Int(color.hueComponent * 12), 11)
                slices[k].weight += weight
                slices[k].r += r * weight
                slices[k].g += g * weight
                slices[k].b += b * weight
                slices[k].row += Double(row) * weight
            }
        }
        let ranked = slices.indices.filter { slices[$0].weight > 0 }.sorted { slices[$0].weight > slices[$1].weight }
        let colorful = slices.reduce(0) { $0 + $1.weight }
        guard let first = ranked.first, colorful > Double(side * side) * 0.02 else { return nil }
        func color(_ k: Int) -> NSColor {
            let slice = slices[k]
            return NSColor(srgbRed: slice.r / slice.weight, green: slice.g / slice.weight, blue: slice.b / slice.weight, alpha: 1)
        }
        func apart(_ a: Int, _ b: Int) -> Int { min(abs(a - b), 12 - abs(a - b)) }

        if let second = ranked.dropFirst().first(where: { apart($0, first) >= 2 && slices[$0].weight >= slices[first].weight * 0.12 }) {
            let firstRow = slices[first].row / slices[first].weight, secondRow = slices[second].row / slices[second].weight
            let (top, bottom) = firstRow <= secondRow ? (first, second) : (second, first)
            return [lifted(color(top)), lifted(color(bottom))]
        }
        let main = color(first)
        let tint = Color(hue: (main.hueComponent + 0.06).truncatingRemainder(dividingBy: 1),
                         saturation: max(main.saturationComponent * 0.6, 0.3), brightness: 1)
        return [tint, lifted(main)]
    }

    private static func lifted(_ color: NSColor) -> Color {
        Color(hue: color.hueComponent, saturation: max(color.saturationComponent, 0.5),
              brightness: max(color.brightnessComponent, 0.9))
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
