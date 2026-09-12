import AppKit
import ImageIO

/// The user's selected typing scene from the original local Codex companion.
/// Keep the source alpha, proportions and per-frame timing; no recoloring/mask.
@MainActor enum CodexAnimation {
    static let durations: [TimeInterval] = [0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
    static var cycleDuration: TimeInterval { durations.reduce(0, +) }
    private static let frames: [NSImage] = {
        guard let url = AnimationResources.url(forResource: "codex-companion", withExtension: "webp"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              sheet.width == 1536, sheet.height == 2288 else { return [] }
        return (0..<6).compactMap { column in
            guard let frame = sheet.cropping(to: CGRect(x: column * 192, y: 7 * 208, width: 192, height: 208)) else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: 192, height: 208))
        }
    }()
    private static var rendered: [String: NSImage] = [:]

    static func frame(at elapsed: TimeInterval) -> Int {
        var t = max(0, elapsed).truncatingRemainder(dividingBy: cycleDuration)
        for (index, duration) in durations.enumerated() {
            if t < duration { return index }
            t -= duration
        }
        return 0
    }
    static func image(at elapsed: TimeInterval, size: CGFloat) -> NSImage? {
        let index = frame(at: elapsed)
        guard frames.indices.contains(index) else { return nil }
        let key = "\(index)-\(size)"
        if let cached = rendered[key] { return cached }
        let source = frames[index]
        let image = NSImage(size: NSSize(width: size * 192 / 208, height: size), flipped: false) { bounds in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            return true
        }
        image.isTemplate = false
        rendered[key] = image
        return image
    }
}
