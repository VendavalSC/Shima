import AppKit

/// Shima's parasol, as a menu bar icon: the app icon's glyph in one color, which macOS tints to suit
/// the menu bar. Drawn from the same shapes as the icon (Tools/Icon), with a sturdier pole and tip so
/// they still read at 16 points.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shapes = parasol()
            let bounds = shapes.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
            let scale = min(rect.width / bounds.width, (rect.height - 1) / bounds.height)
            context.translateBy(x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.black.cgColor)
            // One at a time, so where shapes overlap they don't cancel out.
            for shape in shapes {
                context.addPath(shape)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shima"
        return image
    }()

    /// The parasol leaning over a dune, in the icon's 1024-point space.
    private static func parasol() -> [CGPath] {
        let center = CGPoint(x: 512, y: 548)
        let radius: CGFloat = 262
        let pole: CGFloat = 58
        let lean = CGAffineTransform(translationX: 512, y: 300).rotated(by: -0.17).translatedBy(x: -512, y: -300)
        // The canopy: a slightly flattened dome; four scallops arc up into it along the rim.
        let canopy = CGMutablePath()
        let flatten = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: 1, y: 0.84).translatedBy(x: -center.x, y: -center.y)
        canopy.move(to: CGPoint(x: center.x - radius, y: center.y), transform: flatten)
        canopy.addArc(center: center, radius: radius, startAngle: .pi, endAngle: 0, clockwise: true, transform: flatten)
        let scallops = 4
        let width = 2 * radius / CGFloat(scallops)
        for i in (0..<scallops).reversed() {
            let right = CGPoint(x: center.x - radius + width * CGFloat(i + 1), y: center.y)
            let left = CGPoint(x: right.x - width, y: center.y)
            canopy.addQuadCurve(to: left, control: CGPoint(x: (left.x + right.x) / 2, y: center.y + 58))
        }
        canopy.closeSubpath()
        let tip = CGPath(roundedRect: CGRect(x: center.x - pole / 2, y: center.y + radius * 0.84 - 10, width: pole, height: 60),
                         cornerWidth: pole / 2, cornerHeight: pole / 2, transform: nil)
        let stick = CGPath(roundedRect: CGRect(x: center.x - pole / 2, y: 268, width: pole, height: center.y - 268 + 10),
                           cornerWidth: pole / 2, cornerHeight: pole / 2, transform: nil)
        // The dune.
        let dune = CGMutablePath()
        dune.move(to: CGPoint(x: 236, y: 238))
        dune.addCurve(to: CGPoint(x: 788, y: 238), control1: CGPoint(x: 380, y: 372), control2: CGPoint(x: 644, y: 372))
        dune.addQuadCurve(to: CGPoint(x: 236, y: 238), control: CGPoint(x: 512, y: 200))
        dune.closeSubpath()
        var leaning = lean
        return [canopy.copy(using: &leaning)!, tip.copy(using: &leaning)!, stick.copy(using: &leaning)!, dune]
    }
}
