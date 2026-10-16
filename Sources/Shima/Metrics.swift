import AppKit
import SwiftUI

/// Shima's layout system, in points. A 4pt grid, one outer padding, and concentric corners: the open
/// notch's 28pt bottom radius minus its 16pt padding gives the 12pt radius used for everything inside.
enum Metrics {
    /// The transparent panel the notch lives in; larger than the notch so springs can overshoot.
    static let window = CGSize(width: 440, height: 250)

    static let padding: CGFloat = 16
    static let innerRadius: CGFloat = 12

    // Sizes that depend on the display (its menu bar, a camera housing) are in `NotchGeometry`.

    /// The island's gap from the top of the screen, and its closed height: iPhone's proportions
    /// rather than the menu bar's, so it reaches a little past the menu bar.
    static let islandGap: CGFloat = 6
    static let islandHeight: CGFloat = 32

    // MARK: Closed

    /// Closed with something to show (music, shelf, lock): wings on both sides of the notch.
    static let wing: CGFloat = 34
    /// Brief alerts with a word on one side and a reading on the other need wider wings.
    static let alertWing: CGFloat = 70
    /// An upcoming event's title needs the widest wings.
    static let eventWing: CGFloat = 92
    static let notificationContentHeight: CGFloat = 72
    static let replyRowHeight: CGFloat = 32
    static let notificationIcon: CGFloat = 38
    static let compactArtRadius: CGFloat = 5
    static let compactBars = BarSpec(width: 2.5, spacing: 2, height: 12)
    static let compactSymbol: CGFloat = 13
    /// Fixed box for the padlock so the open shackle grows rightward without the body shifting.
    static let lockIconBox: CGFloat = 16

    /// The Touch ID square's side, and the fingerprint in it.
    static let touchIDSide: CGFloat = 112
    static let touchIDGlyph: CGFloat = 50

    // MARK: Open

    static let openWidth: CGFloat = 344
    static let sectionHeight: CGFloat = 126
    static let dropTileHeight: CGFloat = 88
    static let dropTileSpacing: CGFloat = 12

    // Player (y measured from the top of its content, i.e. below the top padding)
    static let art: CGFloat = 52
    static let artTextGap: CGFloat = 12
    static let bars = BarSpec(width: 3, spacing: 2.5, height: 16)
    static let scrubberCenterY: CGFloat = 72
    static let scrubberHeight: CGFloat = 4
    static let scrubberActiveHeight: CGFloat = 8
    static let timeGap: CGFloat = 8
    /// The bottom row of both sections: transport (or shelf status) centered, a button at each edge.
    static let controlsCenterY: CGFloat = 108
    static let skipOffset: CGFloat = 52
    /// Center of the edge buttons, from either side of the content area.
    static let edgeButtonInset: CGFloat = 15

    /// The timer's length picker, within the page's content area.
    static let timerRuler = CGRect(x: 0, y: 46, width: openWidth - 2 * padding, height: 66)

    // Shelf page: five columns of tiles in a grid that scrolls vertically.
    static let shelfThumb: CGFloat = 44
    static let shelfTileWidth: CGFloat = 60
    static let shelfTileHeight: CGFloat = 62
    static let shelfSpacing: CGFloat = 3
    /// Tall enough to show a row and a peek of the next, which says the grid scrolls.
    static let shelfGridHeight: CGFloat = 90
}

struct NotchSpec: Equatable {
    let body: CGSize
    let ear: CGSize
    let bottom: CGSize
    /// Radius of the top corners: none for the notch, which meets the top edge; the island's.
    var top: CGFloat = 0
    /// Distance from the top of the screen: none for the notch; the island's gap.
    var topInset: CGFloat = 0

    /// The same shape, shorter by `amount` but no shorter than `minimum`: pushed back toward the top.
    func shortened(by amount: CGFloat, to minimum: CGFloat) -> NotchSpec {
        let height = max(minimum, body.height - max(0, amount))
        return NotchSpec(body: CGSize(width: body.width, height: height), ear: ear, bottom: bottom, top: top, topInset: topInset)
    }

    /// The body's rect in panel coordinates (top-left origin, centered; flush with the top edge, or
    /// just below it as an island).
    var bodyRect: CGRect {
        CGRect(x: (Metrics.window.width - body.width) / 2, y: topInset, width: body.width, height: body.height)
    }
}

struct BarSpec {
    static let count = 5

    let width: CGFloat
    let spacing: CGFloat
    let height: CGFloat

    var totalWidth: CGFloat { CGFloat(Self.count) * width + CGFloat(Self.count - 1) * spacing }
}

/// Apple's standard springs: `snappy` to open (a touch of settle) and `smooth` to close (none).
/// Content is choreographed around the shape: the old content is gone before the shape visibly
/// moves, and the new content sharpens in once the shape is most of the way there.
enum Motion {
    static let open = Animation.snappy(duration: 0.45)
    static let close = Animation.smooth(duration: 0.45)
    /// Changes while closed: music starting, the shelf filling, the screen locking.
    static let compact = Animation.snappy(duration: 0.45)
    /// Notch to island and back: a little slower, with a touch of bounce as it settles.
    static let morph = Animation.spring(duration: 0.65, bounce: 0.22)
    static let contentIn = Animation.easeOut(duration: 0.16).delay(0.09)
    static let contentOut = Animation.easeOut(duration: 0.07)
    /// Closed content returns once the shape has nearly finished closing.
    static let compactIn = Animation.easeOut(duration: 0.16).delay(0.2)
}
