import SwiftUI

/// The Timer page. Idle: the chosen length and Start above a ruler you slide to set it. Running or
/// paused: the countdown in the middle with Cancel and Pause on either side, like the Clock app.
/// Finished: Done, with Stop and Repeat.
struct TimerSection: View {
    let model: IslandModel
    let timer: NotchTimer

    private var width: CGFloat { Metrics.openWidth - 2 * Metrics.padding }
    private static let middle: CGFloat = 60

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch timer.state {
            case .idle: presets
            case .running(let end): active(running: true) { countdown(until: end) }
            case .paused(let remaining): active(running: false) { Text(Self.format(remaining)) }
            case .finished: finished
            }
        }
        .frame(width: width, height: Metrics.sectionHeight, alignment: .topLeading)
        .animation(.snappy(duration: 0.3), value: timer.state)
    }

    private var presets: some View {
        ZStack(alignment: .topLeading) {
            Text(Self.lengthText(timer.pickedMinutes))
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(timer.pickedMinutes)))
                .animation(.snappy(duration: 0.2), value: timer.pickedMinutes)
                .frame(height: 36)

            NotchCapsuleButton(model: model, center: CGPoint(x: width - 38, y: 18), size: CGSize(width: 76, height: 30),
                               fill: .orange.opacity(0.25)) {
                timer.settlePicker()
                withAnimation(.snappy(duration: 0.3)) { timer.start(minutes: timer.pickedMinutes) }
            } label: {
                Text("Start").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            }

            TimerRuler(timer: timer)
                .frame(width: width, height: Metrics.timerRuler.height)
                .offset(y: Metrics.timerRuler.minY)
        }
    }

    /// "25 min", "1 hr, 30 min", in the user's language.
    static func lengthText(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func active<Time: View>(running: Bool, @ViewBuilder time: () -> Time) -> some View {
        ZStack(alignment: .topLeading) {
            NotchRoundButton(model: model, center: CGPoint(x: 26, y: Self.middle), diameter: 52, fill: .white.opacity(0.14)) {
                withAnimation(.snappy(duration: 0.3)) { timer.stop() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            }
            .help("Cancel")

            VStack(spacing: 2) {
                time()
                    .font(.system(size: 38, weight: .light).monospacedDigit())
                    .foregroundStyle(running ? .white : .white.opacity(0.6))
                Group {
                    if running, case .running(let end) = timer.state {
                        Label(end.formatted(.dateTime.hour().minute()), systemImage: "bell.fill")
                    } else {
                        Text("Paused")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: width)
            .position(x: width / 2, y: Self.middle)

            NotchRoundButton(model: model, center: CGPoint(x: width - 26, y: Self.middle), diameter: 52,
                             fill: .orange.opacity(0.25)) {
                withAnimation(.snappy(duration: 0.3)) { running ? timer.pause() : timer.resume() }
            } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.orange)
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(running ? "Pause" : "Resume")
        }
    }

    private var finished: some View {
        ZStack(alignment: .topLeading) {
            NotchRoundButton(model: model, center: CGPoint(x: 26, y: Self.middle), diameter: 52, fill: .white.opacity(0.14)) {
                withAnimation(.snappy(duration: 0.3)) { timer.stop() }
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            }
            .help("Stop")

            VStack(spacing: 2) {
                Text("Done")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Timer · \(Self.format(timer.duration))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: width)
            .position(x: width / 2, y: Self.middle)

            NotchRoundButton(model: model, center: CGPoint(x: width - 26, y: Self.middle), diameter: 52,
                             fill: .orange.opacity(0.25)) {
                withAnimation(.snappy(duration: 0.3)) { timer.repeatLast() }
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 17, weight: .semibold)).foregroundStyle(.orange)
            }
            .help("Repeat")
        }
    }

    /// Counts down on its own: the system redraws the text, nothing here ticks.
    private func countdown(until end: Date) -> Text {
        Text(timerInterval: Date()...max(end, Date()), countsDown: true)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// The timer in the closed notch: an orange timer and the live countdown, as on iPhone; a ringing
/// bell when it's done.
struct TimerCompact: View {
    @Environment(\.notchGeometry) var geometry
    let timer: NotchTimer

    var body: some View {
        HStack(spacing: 0) {
            leading
                .font(.system(size: Metrics.compactSymbol, weight: .semibold))
            Spacer(minLength: 0)
            trailing
                .font(.system(size: Metrics.compactSymbol, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, geometry.compactInset + 4)
    }

    @ViewBuilder private var leading: some View {
        switch timer.state {
        case .finished:
            Image(systemName: "bell.fill").symbolEffect(.wiggle, options: .repeating)
        case .paused:
            Image(systemName: "pause.fill").foregroundStyle(.orange.opacity(0.7))
        default:
            Image(systemName: "timer")
        }
    }

    @ViewBuilder private var trailing: some View {
        switch timer.state {
        case .running(let end):
            Text(timerInterval: Date()...max(end, Date()), countsDown: true)
        case .paused(let remaining):
            Text(TimerSection.format(remaining)).foregroundStyle(.white.opacity(0.6))
        case .finished:
            Text("Done")
        case .idle:
            EmptyView()
        }
    }
}

/// The length picker: a ruler with a tick per minute (taller, labeled ticks every five) that slides
/// under a fixed orange line. Drag it, scroll over it, or click a tick; it settles on a whole minute,
/// with a haptic click as each minute passes the line. The chosen stretch is lit; the ends fade.
struct TimerRuler: View {
    let timer: NotchTimer

    static let spacing: CGFloat = 8

    var body: some View {
        RulerTicks(value: timer.pickerMinutes)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if timer.dragOrigin == nil { timer.dragOrigin = timer.pickerMinutes }
                        guard let origin = timer.dragOrigin, abs(drag.translation.width) >= 3 else { return }
                        let before = timer.pickedMinutes
                        timer.pickerMinutes = origin
                        timer.movePicker(by: -Double(drag.translation.width / Self.spacing))
                        if timer.pickedMinutes != before { Haptics.tick() }
                    }
                    .onEnded { drag in
                        let origin = timer.dragOrigin ?? timer.pickerMinutes
                        timer.dragOrigin = nil
                        withAnimation(.snappy(duration: 0.35)) {
                            if abs(drag.translation.width) < 3 {
                                // A click: bring the clicked tick to the line.
                                timer.pickerMinutes = origin
                                timer.movePicker(by: Double((drag.location.x - Metrics.timerRuler.width / 2) / Self.spacing))
                                Haptics.tick()
                            }
                            timer.settlePicker()
                        }
                    }
            )
    }
}

/// The ruler's drawing, animatable so it glides when the value settles or jumps. Like a dial under a
/// loupe, ticks swell and brighten as they near the line, and thin out and fade toward the ends.
private struct RulerTicks: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    /// How far either side of the line ticks are magnified.
    private static let loupe: CGFloat = 30

    var body: some View {
        Canvas { context, size in
            let spacing = TimerRuler.spacing
            let mid = size.width / 2
            let baseline = size.height - 20
            let visible = Int((mid / spacing).rounded(.up)) + 1
            let first = max(NotchTimer.minuteRange.lowerBound, Int(value) - visible)
            let last = min(NotchTimer.minuteRange.upperBound, Int(value) + visible)
            guard first <= last else { return }
            for minute in first...last {
                let x = mid + CGFloat(Double(minute) - value) * spacing
                // Eased fade over the outer fifth of each side.
                let edge = min(max(min(x, size.width - x) / (size.width * 0.2), 0), 1)
                let fade = edge * edge * (3 - 2 * edge)
                guard fade > 0.01 else { continue }
                let distance = abs(x - mid) / Self.loupe
                let near = exp(-distance * distance)   // 1 at the line, gone by ~2 loupes
                let major = minute % 5 == 0
                let width: CGFloat = major ? 2 : 1.5
                let height = (major ? 16 : 9) + 9 * near
                let chosen = Double(minute) <= value + 0.5
                let opacity = chosen ? 0.7 + 0.3 * near : (major ? 0.5 : 0.28) + 0.4 * near
                let tick = Path(roundedRect: CGRect(x: x - width / 2, y: baseline - height, width: width, height: height),
                                cornerRadius: width / 2)
                context.fill(tick, with: .color((chosen ? Color.orange : .white).opacity(opacity * fade)))
                if major {
                    let label = Text("\(minute)")
                        .font(.system(size: 10, weight: near > 0.5 ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle((chosen ? Color.orange : .white).opacity((0.5 + 0.5 * near) * fade))
                    context.draw(label, at: CGPoint(x: x, y: baseline + 10))
                }
            }
            // The line, standing a little above the tallest tick.
            let line = Path(roundedRect: CGRect(x: mid - 1.5, y: baseline - 33, width: 3, height: 35), cornerRadius: 1.5)
            context.fill(line, with: .color(.orange))
        }
    }
}

enum Haptics {
    /// A light click, as on a detent, if haptics are on in Settings.
    static func tick() {
        guard AppSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// A capsule button in the open notch, positioned by its center in content coordinates, brightening
/// under the pointer.
struct NotchCapsuleButton<Label: View>: View {
    let model: IslandModel
    let center: CGPoint
    let size: CGSize
    let fill: Color
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        let hovered = model.pointer.map { pointer in
            CGRect(x: center.x - size.width / 2 + Metrics.padding, y: center.y - size.height / 2 + model.geometry.contentTop,
                   width: size.width, height: size.height).contains(pointer)
        } ?? false
        Button(action: action) {
            label
                .frame(width: size.width, height: size.height)
                .background(Capsule().fill(fill))
                .overlay(Capsule().fill(.white.opacity(hovered ? 0.08 : 0)))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(PressScaleStyle())
        .position(center)
    }
}

/// A round button in the open notch, positioned by its center in content coordinates, brightening
/// under the pointer.
struct NotchRoundButton<Label: View>: View {
    let model: IslandModel
    let center: CGPoint
    let diameter: CGFloat
    let fill: Color
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        let hovered = model.isHovering(CGPoint(x: center.x + Metrics.padding, y: center.y + model.geometry.contentTop),
                                       radius: diameter / 2)
        Button(action: action) {
            label
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(fill))
                .overlay(Circle().fill(.white.opacity(hovered ? 0.08 : 0)))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(PressScaleStyle())
        .position(center)
    }
}
