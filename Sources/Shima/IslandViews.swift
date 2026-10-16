import SwiftUI

/// What the notch is showing. Closed, it shows the most important thing going on (lock, music,
/// shelf) in wings beside the notch; open, it shows one section (Now Playing or Shelf).
enum NotchContent: Equatable {
    case idle, music, shelf, lock, drop, open, touchID, notification, notificationReply, status, battery, deviceBanner,
         device, drive, event, timer, agent, agentAlert, lockMusic

    /// Closed, the most time-sensitive thing wins: a battery alert, a timer that just finished, an
    /// event about to start, a running timer, then music, then the shelf.
    static func resolve(model: IslandModel, media: MediaController, shelf: ShelfStore, timer: NotchTimer) -> NotchContent {
        if model.lockPhase != .unlocked {
            // Music keeps its controls on the lock screen, until a finger is on the sensor.
            let music = AppSettings.shared.lockScreenMusic && model.lockPhase == .locked && media.hasMedia
                && (media.isPlaying || model.lockMusicKept)
            return music && (model.lockFinger ?? .resting) == .resting ? .lockMusic : .lock
        }
        if model.isDropping { return .drop }
        if model.isExpanded { return .open }
        if model.touchID != nil { return .touchID }
        if let notification = model.notification {
            // A chat grows its reply box under the pointer, and keeps it while you reply.
            let showsBox = model.replyPhase != .none || (notification.canReply && model.pointer != nil)
            return showsBox ? .notificationReply : .notification
        }
        if AppSettings.shared.agentActivity, AgentMonitor.shared.alert != nil { return .agentAlert }
        if model.statusAlert != nil { return .status }
        if model.batteryAlert != nil { return .battery }
        if let device = model.deviceAlert { return device.isBanner ? .deviceBanner : .device }
        if model.driveAlert != nil { return .drive }
        if timer.state == .finished { return .timer }
        if model.upcomingEvent != nil { return .event }
        return closed(media: media, shelf: shelf, timer: timer)
    }

    static func closed(media: MediaController, shelf: ShelfStore, timer: NotchTimer) -> NotchContent {
        let settings = AppSettings.shared
        if timer.isActive { return .timer }
        if settings.agentActivity && !AgentMonitor.shared.working.isEmpty { return .agent }
        if settings.showMusicWhenClosed && media.hasMedia && media.isPlaying { return .music }
        return settings.shelfEnabled && !shelf.isEmpty ? .shelf : .idle
    }

    func spec(in geometry: NotchGeometry) -> NotchSpec {
        switch self {
        case .idle: geometry.idle
        case .music, .shelf, .lock, .device: geometry.compact
        case .battery, .timer, .status, .agent, .agentAlert: geometry.alert
        case .deviceBanner, .drive: geometry.banner
        case .notification: geometry.notificationBanner
        case .notificationReply: geometry.notificationReplyBanner
        case .event: geometry.event
        case .touchID: geometry.touchIDSquare
        case .lockMusic: geometry.lockMusicBanner
        case .drop: geometry.drop
        case .open: geometry.expanded
        }
    }
}

/// The black notch. Content never travels between states: the shape springs to its new size while
/// the old content vanishes almost at once, and the new content sharpens in place once the shape
/// is most of the way there (timings in `Motion`).
struct IslandRootView: View {
    let model: IslandModel
    let media: MediaController
    let outputs: AudioOutputController
    let shelf: ShelfStore
    let calendar: CalendarMonitor
    let timer: NotchTimer

    var body: some View {
        let content = NotchContent.resolve(model: model, media: media, shelf: shelf, timer: timer)
        let lift = content == .notification || content == .notificationReply ? model.notificationLift : 0
        let spec = content.spec(in: model.geometry).shortened(by: lift, to: model.geometry.closedHeight)
        let shape = NotchShape(ear: spec.ear, bottom: spec.bottom, top: spec.top)

        ZStack(alignment: .top) {
            switch content {
            case .open:
                OpenNotch(model: model, media: media, outputs: outputs, shelf: shelf, calendar: calendar, timer: timer)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.contentIn))
            case .drop:
                DropTargets(model: model)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.contentIn))
            case .music:
                MusicCompact(media: media)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.compactIn))
            case .shelf:
                ShelfCompact(count: shelf.items.count)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.compactIn))
            case .agent:
                AgentWorking(sessions: AgentMonitor.shared.working)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.compactIn))
            case .agentAlert:
                if let session = AgentMonitor.shared.alert {
                    AgentAlert(session: session)
                        .id(session.id + "\(session.state)")
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .touchID:
                if let phase = model.touchID {
                    TouchIDSquare(phase: phase, misses: model.touchIDMisses)
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.contentIn))
                }
            case .status:
                if let alert = model.statusAlert {
                    StatusCompact(alert: alert)
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .drive:
                if let drive = model.driveAlert {
                    DriveBanner(model: model, drive: drive)
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .battery:
                if let alert = model.batteryAlert {
                    BatteryCompact(alert: alert)
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .notification, .notificationReply:
                if let notification = model.notification {
                    // Pushed up by a swipe, the message rises with the fingers and fades.
                    NotificationBanner(model: model, notification: notification)
                        .id(notification.id)
                        .frame(width: spec.body.width, height: content.spec(in: model.geometry).body.height)
                        .offset(y: -lift * 0.5)
                        .opacity(1 - min(1, lift / 70))
                        .frame(width: spec.body.width, height: spec.body.height, alignment: .top)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .deviceBanner:
                if let alert = model.deviceAlert {
                    DeviceBanner(alert: alert)
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .device:
                if let alert = model.deviceAlert {
                    DeviceCompact(alert: alert)
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .timer:
                TimerCompact(timer: timer)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.compactIn))
            case .event:
                if let event = model.upcomingEvent {
                    EventCompact(event: event)
                        .frame(width: spec.body.width, height: spec.body.height)
                        .transition(.notchContent(in: Motion.compactIn))
                }
            case .lockMusic:
                LockMusicBanner(model: model, media: media)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.compactIn))
            case .lock:
                LockCompact(open: model.lockPhase.showsOpenShackle, finger: model.lockFinger, misses: model.lockMisses)
                    .frame(width: spec.body.width, height: spec.body.height)
                    .transition(.notchContent(in: Motion.compactIn))
            case .idle:
                EmptyView()
            }
        }
        .frame(width: spec.body.width, height: spec.body.height, alignment: .top)
        .padding(.horizontal, spec.ear.width)
        .background(shape.fill(.black))
        .clipShape(shape)
        // Hidden with nothing to show, if asked (a camera housing is there regardless); pointing at
        // where it would be still opens it.
        .opacity(hiddenWhenIdle(content) ? 0 : 1)
        .scaleEffect(hiddenWhenIdle(content) ? 0.85 : 1, anchor: .top)
        .animation(.smooth(duration: 0.35), value: hiddenWhenIdle(content))
        // Changes that happen on their own while closed (music starting, the shelf filling) spring
        // too; opening and closing bring their own animation.
        .animation(Motion.compact, value: NotchContent.closed(media: media, shelf: shelf, timer: timer))
        .animation(Motion.compact, value: shelf.items.count)
        // Resizing it in Settings springs to the new size, like switching between notch and island.
        .animation(Motion.morph, value: AppSettings.shared.notchWidth)
        .animation(Motion.morph, value: AppSettings.shared.notchHeightMode)
        .animation(Motion.morph, value: AppSettings.shared.customNotchHeight)
        .padding(.top, spec.topInset)
        .environment(\.notchGeometry, model.geometry)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension IslandRootView {
    func hiddenWhenIdle(_ content: NotchContent) -> Bool {
        content == .idle && AppSettings.shared.hideWhenIdle && !model.geometry.hasHardwareNotch
    }
}

/// Flush with the top edge, concave flares into it, rounded bottom corners. `ear` and `bottom` are
/// each curve's horizontal and vertical extent; both are smooth cubics rather than circular arcs.
struct NotchShape: Shape {
    var ear: CGSize
    var bottom: CGSize
    /// Radius of convex top corners (the island); zero for the notch, which flares into the top edge.
    var top: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(ear.width, ear.height), AnimatablePair(AnimatablePair(bottom.width, bottom.height), top)) }
        set {
            ear = CGSize(width: newValue.first.first, height: newValue.first.second)
            bottom = CGSize(width: newValue.second.first.first, height: newValue.second.first.second)
            top = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ew = ear.width
        let eh = min(ear.height, rect.height / 2)
        let tr = min(top, rect.height / 2, (rect.width - 2 * ew) / 2)
        let bw = min(bottom.width, (rect.width - 2 * ew) / 2)
        let bh = min(bottom.height, rect.height - eh - tr)
        let left = rect.minX + ew        // body edges
        let right = rect.maxX - ew
        let top = rect.minY
        let base = rect.maxY

        // Each top corner is one curve that's a concave flare into the top edge with ears (the notch),
        // a rounded corner with a top radius (the island), and a blend of the two in between, so one
        // can turn into the other.
        var path = Path()
        path.move(to: CGPoint(x: right + ew - tr, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + eh + tr),
                      control1: CGPoint(x: right + 0.45 * ew - 0.45 * tr, y: top),
                      control2: CGPoint(x: right, y: top + 0.45 * eh + 0.45 * tr))
        path.addLine(to: CGPoint(x: right, y: base - bh))
        path.addCurve(to: CGPoint(x: right - bw, y: base),
                      control1: CGPoint(x: right, y: base - 0.45 * bh),
                      control2: CGPoint(x: right - 0.45 * bw, y: base))
        path.addLine(to: CGPoint(x: left + bw, y: base))
        path.addCurve(to: CGPoint(x: left, y: base - bh),
                      control1: CGPoint(x: left + 0.45 * bw, y: base),
                      control2: CGPoint(x: left, y: base - 0.45 * bh))
        path.addLine(to: CGPoint(x: left, y: top + eh + tr))
        path.addCurve(to: CGPoint(x: left - ew + tr, y: top),
                      control1: CGPoint(x: left, y: top + 0.45 * eh + 0.45 * tr),
                      control2: CGPoint(x: left - 0.45 * ew + 0.45 * tr, y: top))
        path.closeSubpath()
        return path
    }
}

/// Content arrives blurred and transparent, a few points high, and settles into place.
private struct NotchContentModifier: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: shown ? 0 : 10)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -3)
    }
}

private extension AnyTransition {
    static func notchContent(in entrance: Animation) -> AnyTransition {
        let change = AnyTransition.modifier(active: NotchContentModifier(shown: false),
                                            identity: NotchContentModifier(shown: true))
        return .asymmetric(insertion: change.animation(entrance), removal: change.animation(Motion.contentOut))
    }
}

// MARK: Closed

/// Artwork leading, waveform trailing, each inset by the same margin as from the top.
private struct MusicCompact: View {
    @Environment(\.notchGeometry) var geometry
    let media: MediaController

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: media.artwork, key: media.artworkKey,
                        size: geometry.compactArt, radius: Metrics.compactArtRadius)
            Spacer(minLength: 0)
            Waveform(isPlaying: media.isPlaying, colors: media.waveformColors, spec: Metrics.compactBars)
        }
        .padding(.horizontal, geometry.compactInset)
    }
}

/// The shelf has files and nothing else is going on: a tray leading, the count trailing.
private struct ShelfCompact: View {
    @Environment(\.notchGeometry) var geometry
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: Metrics.compactSymbol, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: Metrics.compactSymbol, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, geometry.compactInset + 2)
    }
}

/// Plugged in, or low battery: the word on the leading side, the level and a battery on the trailing.
private struct BatteryCompact: View {
    @Environment(\.notchGeometry) var geometry
    let alert: BatteryAlert

    private var title: String {
        switch alert.kind {
        case .charging: alert.isCharging || alert.level < 100 ? "Charging" : "Fully Charged"
        case .low: "Low Battery"
        }
    }

    private var tint: Color { alert.kind == .low ? .red : .green }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: Metrics.compactSymbol, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: geometry.leadingWingWidth, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("\(alert.level)%")
                    .font(.system(size: Metrics.compactSymbol, weight: .semibold).monospacedDigit())
                    .foregroundStyle(alert.kind == .low ? tint : .white)
                BatteryGlyph(level: alert.level, tint: tint)
            }
        }
        .padding(.horizontal, geometry.compactInset + 4)
    }
}

/// A notification that just arrived, laid out like the system's banner: the app's icon, the title
/// with "now", then the subtitle and message. Clicking it opens it. A chat, under the pointer, grows
/// a reply box beneath the message; clicking the box starts the reply.
private struct NotificationBanner: View {
    @Environment(\.notchGeometry) var geometry
    let model: IslandModel
    let notification: NotchNotification

    private var replying: Bool { model.replyPhase != .none }
    private var showsBox: Bool { replying || (notification.canReply && model.pointer != nil) }

    var body: some View {
        VStack(spacing: 0) {
            message
                .frame(height: Metrics.notificationContentHeight)
            if showsBox {
                ReplyRow(model: model, notification: notification)
                    .frame(height: Metrics.replyRowHeight)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, geometry.bannerContentTop)
        .contentShape(Rectangle())
        .onTapGesture { if !replying { model.onNotificationAction?(.open) } }
    }

    private var message: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: Waveform.drawsStill ? AppIcons.icon(forApp: notification.app).flattened : AppIcons.icon(forApp: notification.app))
                .resizable()
                .interpolation(.high)
                .frame(width: Metrics.notificationIcon, height: Metrics.notificationIcon)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 8) {
                    Text(notification.title.isEmpty ? notification.app : notification.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if !notification.subtitle.isEmpty {
                    Text(notification.subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(notification.subtitle.isEmpty && !showsBox ? 2 : 1)
                }
            }
        }
    }
}

/// The reply box: before you click it, a prompt; then what you're typing (the keys go to the system's
/// reply box; this shows it) with a caret, and a send button. Once sent, a check.
private struct ReplyRow: View {
    let model: IslandModel
    let notification: NotchNotification

    private var empty: Bool { model.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                if model.replyPhase == .sent {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Sent").foregroundStyle(.white.opacity(0.8)).padding(.leading, 4)
                } else if model.replyText.isEmpty {
                    if model.replyPhase == .typing { Caret() }
                    Text("Reply to \(notification.title.isEmpty ? notification.app : notification.title)…")
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .padding(.leading, model.replyPhase == .typing ? 2 : 0)
                } else {
                    Text(model.replyText)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Caret()
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: Metrics.replyRowHeight)
            .background(Capsule().fill(.white.opacity(model.replyPhase == .none ? 0.1 : 0.14)))
            .contentShape(Capsule())
            .onTapGesture { if model.replyPhase == .none { model.onNotificationAction?(.reply) } }

            if model.replyPhase != .sent {
                Button { model.onNotificationAction?(.send) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white, empty ? Color.white.opacity(0.2) : Color.blue)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(empty)
                .animation(.easeOut(duration: 0.15), value: empty)
            }
        }
    }
}

/// A text caret, blinking at the system's pace while the reply box is open.
private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.blue)
                .frame(width: 2, height: 16)
                .opacity(on ? 1 : 0)
        }
        .frame(width: 2)
    }
}

/// Headphones that just connected, announced: the product turning, "Connected" over the name,
/// and the battery as a ring with the level inside, filling as soon as the level is known.
private struct DeviceBanner: View {
    @Environment(\.notchGeometry) var geometry
    let alert: DeviceAlert

    var body: some View {
        HStack(spacing: 10) {
            DeviceArt(alert: alert, size: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(alert.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if alert.battery != nil || alert.awaitingBattery {
                BatteryRing(level: alert.battery, diameter: 30, lineWidth: 3.5, showsLevel: true)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(height: geometry.bannerContentHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, geometry.bannerContentTop)
    }
}

/// Headphones that just connected, settled into the wings: the product leading, the ring trailing.
private struct DeviceCompact: View {
    @Environment(\.notchGeometry) var geometry
    let alert: DeviceAlert

    var body: some View {
        HStack(spacing: 0) {
            DeviceArt(alert: alert, size: geometry.closedHeight - 4)
                .padding(.leading, -3)
            Spacer(minLength: 0)
            if alert.battery != nil || alert.awaitingBattery {
                BatteryRing(level: alert.battery, diameter: 15, lineWidth: 2.5, showsLevel: false)
            }
        }
        .padding(.horizontal, geometry.compactInset + 2)
    }
}

/// A battery level as a ring, the way iPhone shows AirPods: green, red when low. Until the level is
/// known it's an empty track; then it fills.
private struct BatteryRing: View {
    let level: Int?
    let diameter: CGFloat
    let lineWidth: CGFloat
    let showsLevel: Bool

    var body: some View {
        let tint: Color = (level ?? 100) <= 20 ? .red : .green
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(level.map { max($0, 2) } ?? 0) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLevel, let level {
                Text("\(level)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                    .transition(.opacity)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.smooth(duration: 0.7), value: level)
    }
}

/// A quick status: the symbol and name on one side, the state on the other, tinted when on.
private struct StatusCompact: View {
    @Environment(\.notchGeometry) var geometry
    let alert: StatusAlert

    var body: some View {
        HStack(spacing: 0) {
            // The name where it fits (beside a camera housing it may not); the symbol always.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    symbol
                    Text(alert.title).foregroundStyle(.white).lineLimit(1).fixedSize()
                }
                symbol
            }
            .frame(maxWidth: geometry.leadingWingWidth, alignment: .leading)
            Spacer(minLength: 0)
            Text(alert.state)
                .foregroundStyle(alert.isOn ? alert.tint : .white.opacity(0.5))
                .contentTransition(.numericText())
        }
        .font(.system(size: Metrics.compactSymbol, weight: .semibold))
        .padding(.horizontal, geometry.compactInset + 4)
    }

    private var symbol: some View {
        Image(systemName: alert.symbol)
            .foregroundStyle(alert.isOn ? alert.tint : .white.opacity(0.6))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// A drive that just connected: its symbol, "Connected" over its name, and Eject; then what came
/// of ejecting it.
private struct DriveBanner: View {
    @Environment(\.notchGeometry) var geometry
    let model: IslandModel
    let drive: DriveAlert

    private var headline: String {
        switch drive.phase {
        case .connected: "Connected"
        case .ejecting: "Ejecting…"
        case .ejected: "Safe to disconnect"
        case .inUse: "Can't eject, it's in use"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: drive.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(drive.phase == .inUse ? Color.orange : .white.opacity(0.55))
                    .contentTransition(.opacity)
                Text(drive.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: geometry.bannerContentHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, geometry.bannerContentTop)
        .animation(.snappy(duration: 0.3), value: drive.phase)
    }

    @ViewBuilder private var trailing: some View {
        switch drive.phase {
        case .connected, .inUse:
            Button { model.onEjectDrive?() } label: {
                Image(systemName: "eject.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.16)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .help("Eject")
        case .ejecting:
            ProgressView().controlSize(.small).tint(.white).frame(width: 30, height: 30)
        case .ejected:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// An event about to start: its calendar's color and its title leading, the time until it starts
/// trailing. With a hardware notch the title stays within the left wing, clear of the camera;
/// without one it may run across the middle.
private struct EventCompact: View {
    @Environment(\.notchGeometry) var geometry
    let event: UpcomingEvent

    private var titleWidth: CGFloat {
        let inset = geometry.compactInset + 4
        if geometry.hasHardwareNotch { return Metrics.eventWing - inset }
        return geometry.event.body.width - 2 * inset - 84   // leave room for the countdown
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 3, height: Metrics.compactSymbol + 1)
                Text(event.title)
                    .font(.system(size: Metrics.compactSymbol, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: titleWidth, alignment: .leading)
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { _ in
                // The timeline's date is the minute boundary; count from the actual time.
                let minutes = Int((event.start.timeIntervalSinceNow / 60).rounded(.up))
                Text(minutes > 0 ? "in \(minutes) min" : "Now")
                    .font(.system(size: Metrics.compactSymbol, weight: .semibold).monospacedDigit())
                    .foregroundStyle(minutes > 0 ? .white.opacity(0.7) : event.color)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .padding(.horizontal, geometry.compactInset + 4)
    }
}

/// The system's battery shape: an outlined body filled to the level, with a small terminal.
private struct BatteryGlyph: View {
    let level: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, 21 * CGFloat(min(max(level, 0), 100)) / 100))
                    .padding(2)
            }
            .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(.white.opacity(0.4))
                .frame(width: 1.5, height: 4)
        }
    }
}

/// Coding agents at work: a small spinning arc and the project on the leading side, how long it's
/// been going on the trailing side (or how many are working, with more than one).
private struct AgentWorking: View {
    @Environment(\.notchGeometry) var geometry
    let sessions: [AgentSession]

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                AgentSpinner()
                Text(sessions.count == 1 ? sessions[0].project : "\(sessions.count) agents")
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: geometry.leadingWingWidth, alignment: .leading)
            Spacer(minLength: 0)
            if let first = sessions.min(by: { $0.since < $1.since }) {
                TimelineView(.periodic(from: first.since, by: 1)) { context in
                    Text(Duration.seconds(max(0, context.date.timeIntervalSince(first.since)))
                        .formatted(.time(pattern: .minuteSecond)))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: Metrics.compactSymbol, weight: .semibold))
        .padding(.horizontal, geometry.compactInset + 4)
    }
}

/// A short arc going round, in the agents' warm orange.
private struct AgentSpinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle()
                .trim(from: 0, to: 0.62)
                .stroke(AngularGradient(colors: [.orange.opacity(0), .orange], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(223)),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: 12, height: 12)
    }
}

/// A coding agent that needs you (orange, until you answer) or just finished (a green check, for a
/// few seconds). Clicking brings up the app it runs in.
private struct AgentAlert: View {
    @Environment(\.notchGeometry) var geometry
    let session: AgentSession

    private var needsYou: Bool { session.state == .needsYou }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: needsYou ? "hand.raised.fill" : "checkmark.circle.fill")
                    .foregroundStyle(needsYou ? Color.orange : .green)
                Text(session.project)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: geometry.leadingWingWidth, alignment: .leading)
            Spacer(minLength: 0)
            Text(needsYou ? "Needs you" : "Done")
                .foregroundStyle(needsYou ? Color.orange : .white.opacity(0.6))
        }
        .font(.system(size: Metrics.compactSymbol, weight: .semibold))
        .padding(.horizontal, geometry.compactInset + 4)
        .contentShape(Rectangle())
        .onTapGesture { AgentMonitor.shared.open(session) }
    }
}

/// Touch ID: a fingerprint that a band of light sweeps up while it waits, that shakes at a finger it
/// can't read, and that gives way to a checkmark drawn in one stroke once a finger is accepted.
private struct TouchIDSquare: View {
    @Environment(\.notchGeometry) var geometry
    let phase: TouchIDPhase
    let misses: Int

    private static let pink = LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.47), Color(red: 1, green: 0.22, blue: 0.36)],
                                             startPoint: .top, endPoint: .bottom)

    var body: some View {
        let accepted = phase == .accepted
        ZStack {
            fingerprint
                .opacity(accepted ? 0 : 1)
                .scaleEffect(accepted ? 0.7 : 1)
                .blur(radius: accepted ? 4 : 0)
                .animation(.easeOut(duration: 0.2), value: accepted)
            Checkmark(progress: accepted ? 1 : 0)
                .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: Metrics.touchIDGlyph * 0.62, height: Metrics.touchIDGlyph * 0.5)
                .animation(.easeOut(duration: 0.3).delay(0.12), value: accepted)
        }
        .frame(width: Metrics.touchIDGlyph, height: Metrics.touchIDGlyph)
        .modifier(Shake(trigger: misses))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, geometry.touchIDContentTop)
    }

    /// The glyph dim, with a bright copy showing through a band that rises up it every second and a half.
    private var fingerprint: some View {
        let glyph = Image(systemName: "touchid").font(.system(size: Metrics.touchIDGlyph * 0.92, weight: .regular))
        return ZStack {
            glyph.foregroundStyle(Self.pink).opacity(0.4)
            TimelineView(.animation(paused: phase != .waiting)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                let rise = 1 - pow(1 - cycle, 2)   // eases out as it nears the top
                glyph.foregroundStyle(Self.pink)
                    .mask {
                        LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Metrics.touchIDGlyph * 0.7)
                            .offset(y: Metrics.touchIDGlyph * (0.85 - 1.7 * rise))
                    }
            }
        }
    }
}

/// A quick side-to-side shake, like a passcode that's wrong, each time `trigger` changes.
struct Shake: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { view, x in
            view.offset(x: x)
        } keyframes: { _ in
            CubicKeyframe(-7, duration: 0.07)
            CubicKeyframe(6, duration: 0.09)
            CubicKeyframe(-4, duration: 0.08)
            CubicKeyframe(2, duration: 0.07)
            CubicKeyframe(0, duration: 0.07)
        }
    }
}

/// A checkmark drawn from its short stroke to the tip of its long one as `progress` goes to 1.
private struct Checkmark: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path.trimmedPath(from: 0, to: progress)
    }
}

/// The padlock, trailing; flipping `open` animates the shackle. On Macs with Touch ID, a fingerprint
/// leads: dim at rest, lit while it reads a finger, shaking at one it can't read, and a green check
/// once it matches.
private struct LockCompact: View {
    @Environment(\.notchGeometry) var geometry
    let open: Bool
    let finger: LockFinger?
    let misses: Int

    var body: some View {
        HStack(spacing: 0) {
            if let finger {
                LockFingerprint(finger: finger)
                    .modifier(Shake(trigger: misses))
                    .padding(.leading, geometry.compactInset + 3)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Image(systemName: open ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .frame(width: Metrics.lockIconBox, alignment: .leading)
                .padding(.trailing, geometry.compactInset + 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The lock screen's small fingerprint.
private struct LockFingerprint: View {
    let finger: LockFinger

    private static let pink = LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.47), Color(red: 1, green: 0.22, blue: 0.36)],
                                             startPoint: .top, endPoint: .bottom)

    var body: some View {
        let matched = finger == .matched
        ZStack {
            let glyph = Image(systemName: "touchid").font(.system(size: 15, weight: .regular))
            glyph.foregroundStyle(Self.pink).opacity(finger == .resting ? 0.45 : 0.35)
            if finger == .reading {
                // A band of light rising through it while it reads.
                TimelineView(.animation) { context in
                    let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    glyph.foregroundStyle(Self.pink)
                        .mask {
                            LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 12)
                                .offset(y: 14 - 28 * (1 - pow(1 - cycle, 2)))
                        }
                }
            }
        }
        .opacity(matched ? 0 : 1)
        .scaleEffect(matched ? 0.6 : 1)
        .overlay {
            Checkmark(progress: matched ? 1 : 0)
                .stroke(.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 9)
        }
        .animation(.easeOut(duration: 0.22), value: finger)
        .frame(width: 16, height: 16)
    }
}

/// Music on the lock screen: the artwork, what's playing, and its controls, in a banner short enough
/// to stay above the clock.
private struct LockMusicBanner: View {
    @Environment(\.notchGeometry) var geometry
    let model: IslandModel
    let media: MediaController

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: media.artwork, key: media.artworkKey, size: 38, radius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(media.artist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                control("backward.fill", size: 14) { media.previous() }
                control(media.isPlaying ? "pause.fill" : "play.fill", size: 19) {
                    model.lockMusicKept = true
                    media.togglePlayPause()
                }
                .contentTransition(.symbolEffect(.replace))
                control("forward.fill", size: 14) { media.next() }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .padding(.top, geometry.bannerContentTop)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Open

/// The open notch's pages side by side, swiped between with two fingers. Pages follow the fingers
/// and, as they move away from the middle, recede: a little smaller, softer and dimmer. Dots at the
/// bottom show where you are and can be clicked.
private struct OpenNotch: View {
    let model: IslandModel
    let media: MediaController
    let outputs: AudioOutputController
    let shelf: ShelfStore
    let calendar: CalendarMonitor
    let timer: NotchTimer

    var body: some View {
        let pages = NotchSection.available(calendarAccess: calendar.hasAccess)
        let index = pages.firstIndex(of: model.section) ?? 0
        let width = Metrics.openWidth
        ZStack(alignment: .topLeading) {
            ForEach(Array(pages.enumerated()), id: \.element) { position, page in
                let offset = CGFloat(position - index) * width + model.pageDrag
                let distance = min(abs(offset) / width, 1)
                pageView(page)
                    .frame(width: width - 2 * Metrics.padding, height: Metrics.sectionHeight, alignment: .topLeading)
                    .padding(.horizontal, Metrics.padding)
                    .padding(.top, model.geometry.contentTop)
                    .padding(.bottom, Metrics.padding)
                    .scaleEffect(1 - 0.08 * distance)
                    .blur(radius: 6 * distance)
                    .opacity(1 - 0.7 * distance)
                    .offset(x: offset)
                    .allowsHitTesting(position == index)
            }
            if pages.count > 1 {
                // Out of the way at rest: they show while swiping, and briefly as the notch opens.
                PageDots(pages: pages, current: pages[index]) { page in
                    withAnimation(.snappy(duration: 0.42)) { model.section = page }
                }
                .opacity(model.pageDotsVisible ? 1 : 0)
                .allowsHitTesting(model.pageDotsVisible)
                .position(x: width / 2, y: model.geometry.openHeight - 9)
            }
        }
        .frame(width: width, height: model.geometry.openHeight, alignment: .topLeading)
    }

    @ViewBuilder private func pageView(_ page: NotchSection) -> some View {
        switch page {
        case .player: PlayerSection(model: model, media: media, outputs: outputs)
        case .calendar: CalendarSection(calendar: calendar)
        case .reminders: RemindersSection(model: model, reminders: RemindersMonitor.shared)
        case .weather: WeatherSection(weather: WeatherMonitor.shared)
        case .timer: TimerSection(model: model, timer: timer)
        case .system: SystemSection()
        case .shelf: ShelfSection(model: model, shelf: shelf)
        }
    }
}

/// Small dots for the pages; the current one stretches into a short capsule.
private struct PageDots: View {
    let pages: [NotchSection]
    let current: NotchSection
    let select: (NotchSection) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(pages) { page in
                Capsule()
                    .fill(.white.opacity(page == current ? 0.9 : 0.3))
                    .frame(width: page == current ? 12 : 5, height: 5)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { select(page) }
            }
        }
        .animation(.snappy(duration: 0.3), value: current)
    }
}

/// Artwork, title and waveform; a scrubber with times; transport controls centered, with the output
/// picker at the trailing edge. Coordinates are within the content area (inside the padding).
private struct PlayerSection: View {
    let model: IslandModel
    let media: MediaController
    let outputs: AudioOutputController

    private var width: CGFloat { Metrics.openWidth - 2 * Metrics.padding }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: Metrics.artTextGap) {
                ArtworkView(image: media.artwork, key: media.artworkKey,
                            size: Metrics.art, radius: Metrics.innerRadius)
                    .onTapGesture { media.openSourceApp() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.hasMedia ? media.title : "Not Playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(media.hasMedia ? media.artist : "Play something to see it here")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 12)
            }
            .frame(width: width - Metrics.bars.totalWidth - 12, height: Metrics.art, alignment: .leading)

            Waveform(isPlaying: media.isPlaying, colors: media.waveformColors, spec: Metrics.bars)
                .opacity(media.hasMedia ? 1 : 0)
                .position(x: width - Metrics.bars.totalWidth / 2, y: Metrics.art / 2)

            ProgressRow(model: model, media: media, isActive: isOverScrubber)
                .frame(width: width, height: 24)
                .position(x: width / 2, y: Metrics.scrubberCenterY)
                .disabled(!media.hasMedia)
                .opacity(media.hasMedia ? 1 : 0.35)

            controls
        }
        .frame(width: width, height: Metrics.sectionHeight, alignment: .topLeading)
    }

    private var isOverScrubber: Bool {
        guard media.hasMedia else { return false }
        if model.scrubFraction != nil { return true }
        guard let pointer = model.pointer else { return false }
        let y = pointer.y - model.geometry.contentTop
        return abs(y - Metrics.scrubberCenterY) <= 12
    }

    private var controls: some View {
        let y = Metrics.controlsCenterY
        let center = width / 2
        let transport = CGSize(width: 44, height: 36)
        return ZStack {
            NotchButton(model: model, symbol: "backward.fill", size: 22, color: .white,
                        center: CGPoint(x: center - Metrics.skipOffset, y: y), hit: transport,
                        enabled: media.hasMedia) {
                model.previousTaps += 1
                media.previous()
            }
            .symbolEffect(.bounce.byLayer, value: model.previousTaps)
            NotchButton(model: model, symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 28, color: .white,
                        center: CGPoint(x: center, y: y), hit: transport, enabled: media.hasMedia) {
                media.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            NotchButton(model: model, symbol: "forward.fill", size: 22, color: .white,
                        center: CGPoint(x: center + Metrics.skipOffset, y: y), hit: transport,
                        enabled: media.hasMedia) {
                model.nextTaps += 1
                media.next()
            }
            .symbolEffect(.bounce.byLayer, value: model.nextTaps)
            NotchButton(model: model, symbol: outputs.current?.symbol ?? "airplayaudio",
                        center: CGPoint(x: width - Metrics.edgeButtonInset, y: y)) {
                model.isMenuOpen = true
                outputs.showMenu()
                model.isMenuOpen = false
            }
            .contentTransition(.symbolEffect(.replace))
            .help("Sound Output")
        }
        .frame(width: width, height: Metrics.sectionHeight)
    }
}

private struct ProgressRow: View {
    let model: IslandModel
    let media: MediaController
    let isActive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(media.duration, 0)
            let elapsed = model.scrubFraction.map { $0 * duration } ?? media.elapsed(at: context.date)
            let fraction = duration > 0 ? elapsed / duration : 0

            HStack(spacing: Metrics.timeGap) {
                Text(Self.format(elapsed))
                    .frame(minWidth: 30, alignment: .leading)
                ScrubBar(fraction: fraction, scrubFraction: model.scrubFraction, isActive: isActive,
                         onScrub: { model.scrubFraction = $0 },
                         onCommit: { media.seek(to: $0 * duration) })
                Text("-" + Self.format(max(duration - elapsed, 0)))
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(isActive ? 0.9 : 0.5))
            .animation(.smooth(duration: 0.2), value: isActive)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
