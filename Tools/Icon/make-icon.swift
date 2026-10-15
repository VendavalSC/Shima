// Draws Shima's icon (島, island): one white object on a gradient, in the macOS icon shape.
// Writes AppIcon.icns and a 1024px PNG for each design asked for.
//
//   swiftc -O Tools/Icon/make-icon.swift -o build/make-icon && build/make-icon Resources [design]
import AppKit
import QuartzCore

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
               locations: stops.map(\.0))!
}

/// The macOS icon outline: the 824pt rounded square with Apple's continuous corners, drawn by Core
/// Animation (which knows the curve).
func outlineImage(color: CGColor) -> CGImage {
    let layer = CALayer()
    layer.frame = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let shape = CALayer()
    shape.frame = body
    shape.cornerRadius = body.width * 0.2237
    shape.cornerCurve = .continuous
    shape.backgroundColor = color
    layer.addSublayer(shape)
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    layer.render(in: ctx)
    return ctx.makeImage()!
}

func maskImage() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(outlineImage(color: CGColor(gray: 1, alpha: 1)), in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    return ctx.makeImage()!
}

// MARK: Glyphs (each a set of shapes, filled white one by one so overlaps join rather than cut)

/// A beach parasol: a low dome whose rim dips between the ribs, on a pole leaning a little, planted
/// in a gentle dune.
func parasol() -> [CGPath] {
    let center = CGPoint(x: 512, y: 548)
    let radius: CGFloat = 262
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
    let tip = CGPath(roundedRect: CGRect(x: center.x - 15, y: center.y + radius * 0.84 - 8, width: 30, height: 46),
                     cornerWidth: 15, cornerHeight: 15, transform: nil)
    let pole = CGPath(roundedRect: CGRect(x: center.x - 15, y: 268, width: 30, height: center.y - 268 + 10),
                      cornerWidth: 15, cornerHeight: 15, transform: nil)
    // The dune.
    let dune = CGMutablePath()
    dune.move(to: CGPoint(x: 236, y: 238))
    dune.addCurve(to: CGPoint(x: 788, y: 238), control1: CGPoint(x: 380, y: 352), control2: CGPoint(x: 644, y: 352))
    dune.addQuadCurve(to: CGPoint(x: 236, y: 238), control: CGPoint(x: 512, y: 214))
    dune.closeSubpath()
    return [canopy.copy(using: [lean])!, tip.copy(using: [lean])!, pole.copy(using: [lean])!, dune]
}

extension CGPath {
    func copy(using transforms: [CGAffineTransform]) -> CGPath? {
        var transform = transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
        return copy(using: &transform)
    }
}

/// A small island: a rounded mound with one palm tree.
func palmIsland() -> [CGPath] {
    var shapes: [CGPath] = []
    // The mound, sitting low.
    let mound = CGMutablePath()
    mound.move(to: CGPoint(x: 230, y: 250))
    mound.addCurve(to: CGPoint(x: 794, y: 250), control1: CGPoint(x: 330, y: 430), control2: CGPoint(x: 694, y: 430))
    mound.addQuadCurve(to: CGPoint(x: 230, y: 250), control: CGPoint(x: 512, y: 224))
    mound.closeSubpath()
    shapes.append(mound)
    // The trunk: a gentle curve, thicker at the base.
    let trunk = CGMutablePath()
    trunk.move(to: CGPoint(x: 462, y: 330))
    trunk.addCurve(to: CGPoint(x: 548, y: 668), control1: CGPoint(x: 466, y: 480), control2: CGPoint(x: 500, y: 600))
    trunk.addLine(to: CGPoint(x: 578, y: 660))
    trunk.addCurve(to: CGPoint(x: 516, y: 330), control1: CGPoint(x: 536, y: 590), control2: CGPoint(x: 514, y: 470))
    trunk.closeSubpath()
    shapes.append(trunk)
    // The fronds: leaves arching out from the crown and drooping at their tips.
    let crown = CGPoint(x: 562, y: 672)
    let fronds: [(angle: CGFloat, length: CGFloat, droop: CGFloat)] = [
        (.pi - 0.15, 250, 120), (.pi * 0.72, 210, 30), (.pi * 0.42, 180, 10), (0.55, 220, 40), (0.05, 250, 125),
    ]
    for frond in fronds {
        let reach = CGPoint(x: crown.x + cos(frond.angle) * frond.length, y: crown.y + sin(frond.angle) * frond.length)
        let tip = CGPoint(x: reach.x, y: reach.y - frond.droop)
        let mid = CGPoint(x: (crown.x + reach.x) / 2, y: (crown.y + reach.y) / 2 + 26)
        let dx = tip.x - crown.x, dy = tip.y - crown.y
        let length = max(hypot(dx, dy), 1)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let leaf = CGMutablePath()
        leaf.move(to: crown)
        leaf.addQuadCurve(to: tip, control: CGPoint(x: mid.x + normal.x * 52, y: mid.y + normal.y * 52))
        leaf.addQuadCurve(to: crown, control: CGPoint(x: mid.x - normal.x * 4, y: mid.y - normal.y * 4))
        leaf.closeSubpath()
        shapes.append(leaf)
    }
    return shapes
}

struct Design {
    let name: String
    let glyph: () -> [CGPath]
    let colors: [(CGFloat, CGColor)]
}

let designs: [Design] = [
    Design(name: "parasol-ocean", glyph: parasol, colors: [(0, rgb(0x0A5BD8)), (1, rgb(0x52C8FA))]),
    Design(name: "island-ocean", glyph: palmIsland, colors: [(0, rgb(0x0A5BD8)), (1, rgb(0x52C8FA))]),
    Design(name: "parasol-sunset", glyph: parasol, colors: [(0, rgb(0xF2456E)), (1, rgb(0xFFA458))]),
]

func drawIcon(_ design: Design, in ctx: CGContext) {
    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.3))
    ctx.draw(outlineImage(color: design.colors[0].1), in: full)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.clip(to: full, mask: maskImage())
    ctx.drawLinearGradient(gradient(design.colors), start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    // The glyph: white, with a whisper of gradient and a soft shadow so it sits on the color.
    // Drawn in a layer of its own so the shadow falls from the whole glyph, not each piece.
    let shapes = design.glyph()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x000000, 0.18))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for shape in shapes {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0xE6ECF6)), (1, rgb(0xFFFFFF))]),
                               start: CGPoint(x: 0, y: 220), end: CGPoint(x: 0, y: 860),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    ctx.restoreGState()
}

func render(_ design: Design, size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(design, in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let chosen = CommandLine.arguments.count > 2 ? designs.filter { $0.name == CommandLine.arguments[2] } : designs
for design in chosen {
    writePNG(render(design, size: 1024), to: output.appendingPathComponent("icon-\(design.name).png"))
}
if chosen.count == 1, let design = chosen.first {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        writePNG(render(design, size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        writePNG(render(design, size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
    try! iconutil.run()
    iconutil.waitUntilExit()
}
print("wrote \(chosen.map(\.name)) to \(output.path)")
