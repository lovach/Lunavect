// Native vector artwork for the Finder installer; the approved app icon is
// supplied by Finder itself. Export at 1x and 2x for dmgbuild's Retina TIFF.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let layoutURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().appendingPathComponent("layout.json")
let layout = try JSONSerialization.jsonObject(with: Data(contentsOf: layoutURL)) as! [String: Any]
let dimensions = (layout["window_rect"] as! [[Int]])[1]
let width = CGFloat(dimensions[0]), height = CGFloat(dimensions[1])

func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

func label(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: UInt32) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(ink), .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: NSRect(x: 32, y: top, width: width - 64, height: size * 1.6),
                           withAttributes: attributes)
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let context = graphics.cgContext
    // bitmap.size already establishes the pixel-to-point scale.
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    color(0xF9FAFC).setFill()
    bounds.fill()
    // The cyan and amber light stays subtle so Finder's labels remain legible.
    for (center, tint) in [(CGPoint(x: 126, y: 245), UInt32(0xB6E6FF)),
                           (CGPoint(x: 560, y: 246), UInt32(0xFFDFC0))] {
        let glow = NSGradient(starting: color(tint, 0.65), ending: color(tint, 0))!
        glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 245, options: [])
    }

    label("Lunavect", top: 40, size: 30, weight: .semibold, ink: 0x232831)
    label("Your AI sessions. One place.", top: 81, size: 14, weight: .regular, ink: 0x69717C)

    // A restrained light trail joins the two real draggable Finder icons.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 293, y: 214))
    arrow.curve(to: NSPoint(x: 382, y: 214),
                controlPoint1: NSPoint(x: 322, y: 202),
                controlPoint2: NSPoint(x: 353, y: 202))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    color(0x667381).setStroke()
    arrow.stroke()
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: 372, y: 202))
    tip.line(to: NSPoint(x: 384, y: 214))
    tip.line(to: NSPoint(x: 369, y: 219))
    tip.lineWidth = 2.5
    tip.lineJoinStyle = .round
    tip.lineCapStyle = .round
    tip.stroke()

    label("Drag Lunavect to Applications", top: 335, size: 15, weight: .medium, ink: 0x414B58)
    label("Then open it from Applications to get started.", top: 360, size: 12, weight: .regular, ink: 0x737C89)

    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 1 ? "" : "@2x"
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: output.appendingPathComponent("background\(suffix).png"))
}
