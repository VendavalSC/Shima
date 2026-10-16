import SwiftUI

/// Album art that squashes and blurs out when the track's artwork changes.
struct ArtworkView: View {
    let image: NSImage?
    let key: String
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            artwork
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .id(key)
                .transition(.squash)
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: key)
    }

    @ViewBuilder private var artwork: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(.white.opacity(0.12))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
        }
    }
}

private struct SquashModifier: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1 - 0.75 * amount, y: 1 - 0.08 * amount)
            .blur(radius: 6 * amount)
            .opacity(1 - amount)
    }
}

extension AnyTransition {
    static var squash: AnyTransition {
        .modifier(active: SquashModifier(amount: 1), identity: SquashModifier(amount: 0))
    }
}

/// The Now Playing waveform: five capsules in the artwork's color, moving while music plays and
/// resting low when paused. (The motion is synthesized; reading real audio would need a recording
/// permission that a glanceable indicator doesn't justify.)
///
/// Built on Core Animation: each bar gets a looping keyframe animation that the system compositor
/// runs on its own, so the waveform costs Shima no CPU while it dances (a SwiftUI version redrawing
/// at 30fps measured about 5% CPU).
struct Visualizer: NSViewRepresentable {
    let isPlaying: Bool
    /// Top to bottom; the bars fade from one to the other.
    let colors: [Color]
    let spec: BarSpec

    func makeNSView(context: Context) -> WaveformView { WaveformView(spec: spec) }

    func updateNSView(_ view: WaveformView, context: Context) {
        view.update(playing: isPlaying, colors: colors.map { NSColor($0) })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformView, context: Context) -> CGSize? {
        CGSize(width: spec.totalWidth, height: spec.height)
    }
}

/// The waveform: the animated one, or a still drawing of it when rendering snapshots (the renderer
/// can't draw the animated layers).
struct Waveform: View {
    let isPlaying: Bool
    let colors: [Color]
    let spec: BarSpec

    /// Set while rendering snapshots.
    static var drawsStill = false

    var body: some View {
        if Self.drawsStill {
            HStack(spacing: spec.spacing) {
                ForEach(Array([0.55, 0.95, 0.7, 1.0, 0.5].enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                        .frame(width: spec.width, height: max(spec.width, spec.height * (isPlaying ? level : 0.2)))
                }
            }
            .frame(width: spec.totalWidth, height: spec.height)
        } else {
            Visualizer(isPlaying: isPlaying, colors: colors, spec: spec)
        }
    }
}

/// Each bar fades from the top color to the bottom one along its own length, so every bar shows
/// both, however high it reaches.
final class WaveformView: NSView {
    private let spec: BarSpec
    private var bars: [CAGradientLayer] = []
    private var colors: [CGColor] = []
    private var playing: Bool?

    // Per-bar frequencies and phases so no two bars move in step.
    private static let speeds: [(Double, Double)] = [(5.1, 7.9), (6.3, 4.4), (4.7, 9.2), (7.4, 5.6), (5.8, 8.3)]
    private static let phases: [Double] = [0.0, 1.7, 3.1, 0.9, 2.4]

    init(spec: BarSpec) {
        self.spec = spec
        super.init(frame: NSRect(x: 0, y: 0, width: spec.totalWidth, height: spec.height))
        wantsLayer = true
        for _ in 0..<BarSpec.count {
            let bar = CAGradientLayer()
            bar.startPoint = CGPoint(x: 0.5, y: 1)   // layers here count up from the bottom
            bar.endPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = spec.width / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: spec.totalWidth, height: spec.height) }

    private var restHeight: CGFloat { max(spec.width, spec.height * 0.2) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: CGFloat(index) * (spec.width + spec.spacing) + spec.width / 2, y: bounds.midY)
            bar.bounds.size = CGSize(width: spec.width, height: restHeight)
        }
        CATransaction.commit()
    }

    func update(playing: Bool, colors: [NSColor]) {
        let colors = colors.map(\.cgColor)
        if colors != self.colors {
            // A new song's colors blend in rather than snap.
            CATransaction.begin()
            CATransaction.setAnimationDuration(self.colors.isEmpty ? 0 : 0.5)
            bars.forEach { $0.colors = colors }
            CATransaction.commit()
            self.colors = colors
        }

        guard playing != self.playing else { return }
        let wasPlaying = self.playing
        self.playing = playing
        for (index, bar) in bars.enumerated() {
            if playing {
                bar.removeAnimation(forKey: "settle")
                bar.add(Self.dance(index: index, spec: spec), forKey: "dance")
            } else if wasPlaying == true {
                // Settle from wherever the bar is down to rest.
                let current = bar.presentation()?.bounds.height ?? restHeight
                bar.removeAnimation(forKey: "dance")
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = current
                settle.toValue = restHeight
                settle.duration = 0.3
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(settle, forKey: "settle")
            }
        }
    }

    /// One loop of the bar's motion, sampled from two summed sine waves and smoothed by the compositor.
    private static func dance(index: Int, spec: BarSpec) -> CAAnimation {
        let (a, b) = speeds[index]
        let phase = phases[index]
        let duration = 2.0 + Double(index) * 0.23
        let samples = 18
        var heights = (0..<samples).map { step -> NSNumber in
            let t = duration * Double(step) / Double(samples)
            let wave = 0.6 * sin(t * a + phase) + 0.4 * sin(t * b + phase * 1.3)
            return NSNumber(value: Double(max(spec.width, spec.height * (0.3 + 0.7 * abs(wave)))))
        }
        heights.append(heights[0])   // close the loop
        let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
        animation.values = heights
        animation.duration = duration
        animation.calculationMode = .cubic
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// Progress bar that can be dragged to seek. Thin at rest; like the system scrubber, it thickens
/// while the pointer is over it or it's being dragged.
struct ScrubBar: View {
    let fraction: Double
    let scrubFraction: Double?
    let isActive: Bool
    let onScrub: (Double?) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let shown = min(max(scrubFraction ?? fraction, 0), 1)
            let height = isActive ? Metrics.scrubberActiveHeight : Metrics.scrubberHeight
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(isActive ? 1 : 0.9))
                    .frame(width: max(height, width * shown))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .animation(.snappy(duration: 0.25), value: isActive)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(min(max(value.location.x / max(width, 1), 0), 1))
                    }
                    .onEnded { value in
                        onCommit(min(max(value.location.x / max(width, 1), 0), 1))
                        onScrub(nil)
                    }
            )
        }
    }
}

/// SF Symbol button with a soft disc behind it on hover, a brighter one while `active` (a toggle
/// that's on); dips slightly while pressed.
struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    let hitSize: CGSize
    let highlighted: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .frame(width: hitSize.width, height: hitSize.height)
                .background {
                    Circle()
                        .fill(.white.opacity((active ? 0.2 : 0) + (highlighted ? 0.16 : 0)))
                        .frame(width: hitSize.height + 2, height: hitSize.height + 2)
                        .animation(.easeOut(duration: 0.15), value: highlighted)
                        .animation(.easeOut(duration: 0.2), value: active)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}

/// A button in the open notch, positioned by its center in content coordinates (inside the padding),
/// with the hover highlight driven by the tracked pointer.
struct NotchButton: View {
    let model: IslandModel
    let symbol: String
    var size: CGFloat = 17
    var color: Color = .white.opacity(0.8)
    let center: CGPoint
    var hit = CGSize(width: 30, height: 36)
    var enabled = true
    let action: () -> Void

    var body: some View {
        // Pointer positions are tracked in body coordinates, which include the padding.
        let hovered = model.isHovering(CGPoint(x: center.x + Metrics.padding, y: center.y + model.geometry.contentTop),
                                       radius: hit.width / 2)
        ControlButton(symbol: symbol, size: size, weight: .regular, color: color, hitSize: hit,
                      highlighted: enabled && hovered, active: false, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .position(center)
    }
}

extension NSImage {
    /// A plain sRGB bitmap of it at 2x. App icons straight from macOS carry many sizes and color
    /// profiles, which throws off the snapshot renderer's colors for the whole picture.
    var flattened: NSImage {
        let pixels = NSSize(width: size.width * 2, height: size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .retagging(with: .sRGB) else { return self }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
