import AppKit
import SwiftUI

/// What a notch needs to know about the display it's on: whether there's a camera housing to cover,
/// and how tall the menu bar is. Each display's notch has its own, so a MacBook's notch and an
/// external display's can differ; every size that depends on the display is worked out from it.
struct NotchGeometry: Equatable {
    /// The display has a camera housing. Nothing can be drawn there, so content keeps clear of it.
    var hasHardwareNotch: Bool
    /// The camera housing's size, from the display's areas beside it.
    var cameraHousing: CGSize?
    /// The camera housing's height where there is one, otherwise the menu bar's, so the closed notch
    /// ends where windows begin.
    var automaticClosedHeight: CGFloat
    /// Notch or island, as chosen for this display.
    var style: NotchStyle

    init(screen: NSScreen?) {
        guard let screen else {
            hasHardwareNotch = false
            automaticClosedHeight = 24
            style = AppSettings.shared.notchStyle
            return
        }
        style = AppSettings.shared.preference(for: screen.displayKey).style
        hasHardwareNotch = screen.safeAreaInsets.top > 0
        if hasHardwareNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            cameraHousing = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        if Self.simulatesCameraHousing {
            // For checking layouts on a Mac without one: a 14-inch MacBook Pro's.
            hasHardwareNotch = true
            cameraHousing = Self.simulatedHousing
            automaticClosedHeight = Self.simulatedHousing.height
            return
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        automaticClosedHeight = hasHardwareNotch ? screen.safeAreaInsets.top : (menuBar > 0 ? menuBar : 24)   // auto-hidden menu bar
    }

    /// The main display's.
    static var main: NotchGeometry { NotchGeometry(screen: NSScreen.screens.first) }

    /// SHIMA_SIMULATE_NOTCH lays every display out as if it had a camera housing.
    static let simulatesCameraHousing = ProcessInfo.processInfo.environment["SHIMA_SIMULATE_NOTCH"] != nil
    static let simulatedHousing = CGSize(width: 200, height: 32)

    /// The closed height in use: automatic (the notch or menu bar; for the island, its own), or the
    /// custom height from Settings. Views reading it re-render when the setting changes.
    var closedHeight: CGFloat {
        let settings = AppSettings.shared
        if settings.notchHeightMode == .custom { return CGFloat(settings.customNotchHeight) }
        return isIsland ? Metrics.islandHeight : automaticClosedHeight
    }

    // MARK: Style

    /// Floating below the top edge with every corner rounded, like iPhone's Dynamic Island, rather
    /// than hanging from it. Displays with a camera housing always use the notch.
    var isIsland: Bool { style == .island && !hasHardwareNotch }
    var topInset: CGFloat { isIsland ? Metrics.islandGap : 0 }

    /// The notch as specified, or as an island: no flares into the top edge, the top corners rounded
    /// like the bottom ones, and closed states a full pill.
    private func shaped(body: CGSize, ear: CGSize, bottom: CGSize) -> NotchSpec {
        guard isIsland else { return NotchSpec(body: body, ear: ear, bottom: bottom) }
        let radius = body.height <= closedHeight + 0.5 ? body.height / 2 : bottom.width
        return NotchSpec(body: body, ear: .zero, bottom: CGSize(width: radius, height: radius), top: radius,
                         topInset: topInset)
    }

    // MARK: Closed

    /// The idle notch's width: the camera housing's, where there is one; an island is iPhone's width.
    var notchWidth: CGFloat {
        if let housing = cameraHousing { return max(housing.width, 150) }
        return (isIsland ? 126 : 184) * AppSettings.shared.notchWidth.scale
    }
    /// Brief alerts put a word beside the notch; beside a camera housing, the wing must hold it all.
    var alertWing: CGFloat { hasHardwareNotch ? 100 : Metrics.alertWing }
    /// Small concave flares into the top edge, like the hardware notch's.
    private static let closedEar = CGSize(width: 6, height: 6)

    var idle: NotchSpec {
        shaped(body: CGSize(width: notchWidth, height: closedHeight), ear: Self.closedEar, bottom: CGSize(width: 10, height: 10))
    }
    var compact: NotchSpec {
        shaped(body: CGSize(width: notchWidth + 2 * Metrics.wing, height: closedHeight),
               ear: Self.closedEar, bottom: CGSize(width: 12, height: 12))
    }
    var alert: NotchSpec {
        shaped(body: CGSize(width: notchWidth + 2 * alertWing, height: closedHeight),
               ear: Self.closedEar, bottom: CGSize(width: 12, height: 12))
    }
    var event: NotchSpec {
        shaped(body: CGSize(width: notchWidth + 2 * Metrics.eventWing, height: closedHeight),
               ear: Self.closedEar, bottom: CGSize(width: 12, height: 12))
    }

    /// A device that just connected announces itself in a banner as wide as an alert and taller,
    /// with its content below the camera housing where there is one.
    var banner: NotchSpec {
        shaped(body: CGSize(width: notchWidth + 2 * Metrics.alertWing, height: bannerContentTop + bannerContentHeight),
               ear: Self.closedEar, bottom: CGSize(width: 20, height: 20))
    }
    var bannerContentTop: CGFloat { hasHardwareNotch ? closedHeight : 0 }
    var bannerContentHeight: CGFloat { hasHardwareNotch ? 50 : max(closedHeight + 26, 54) }

    /// A notification opens below the notch, as wide as the open notch, with its content below the
    /// camera housing where there is one.
    var notificationBanner: NotchSpec {
        shaped(body: CGSize(width: Metrics.openWidth, height: bannerContentTop + Metrics.notificationContentHeight),
               ear: CGSize(width: 10, height: 10), bottom: CGSize(width: 22, height: 22))
    }
    /// Replying adds a row for the reply box under the message.
    var notificationReplyBanner: NotchSpec {
        shaped(body: CGSize(width: Metrics.openWidth,
                            height: bannerContentTop + Metrics.notificationContentHeight + Metrics.replyRowHeight + 12),
               ear: CGSize(width: 10, height: 10), bottom: CGSize(width: 24, height: 24))
    }

    /// How wide a brief alert's leading content may be: its wing, beside a camera housing; otherwise
    /// it may run across the middle.
    var leadingWingWidth: CGFloat {
        hasHardwareNotch ? alertWing - compactInset - 4 : .infinity
    }

    /// Leading and trailing content in a wing sits this far in, matching the top and bottom margin.
    var compactInset: CGFloat { (closedHeight - compactArt) / 2 }
    var compactArt: CGFloat { min(18, closedHeight - 10) }

    // MARK: Open

    private static let openEar = CGSize(width: 12, height: 12)
    private static let openBottom = CGSize(width: 28, height: 28)

    /// Where the open notch's content starts: below the camera housing where there is one.
    var contentTop: CGFloat {
        guard hasHardwareNotch else { return Metrics.padding }
        return max(closedHeight, cameraHousing?.height ?? 0) + 8
    }
    var openHeight: CGFloat { contentTop + Metrics.sectionHeight + Metrics.padding }

    var expanded: NotchSpec {
        shaped(body: CGSize(width: Metrics.openWidth, height: openHeight), ear: Self.openEar, bottom: Self.openBottom)
    }
    /// While files are dragged over it: two drop targets side by side.
    var drop: NotchSpec {
        shaped(body: CGSize(width: Metrics.openWidth, height: contentTop + Metrics.dropTileHeight + Metrics.padding),
               ear: Self.openEar, bottom: Self.openBottom)
    }
}

private struct NotchGeometryKey: EnvironmentKey {
    static let defaultValue = NotchGeometry.main
}

extension EnvironmentValues {
    /// The display's geometry, for the notch's views.
    var notchGeometry: NotchGeometry {
        get { self[NotchGeometryKey.self] }
        set { self[NotchGeometryKey.self] = newValue }
    }
}
