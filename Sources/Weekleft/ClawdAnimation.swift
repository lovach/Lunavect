import AppKit
import ImageIO

/// Original Clawd poses, with transparent source geometry. No color key or
/// foreground mask: black eyes and gray laptop parts are real scene content.
@MainActor enum ClawdAnimation {
    enum Action: String { case settle, type, stand, walk, wave, rest }
    struct Pose {
        let action: Action
        let frame: Int
        var offsetX: CGFloat = 0
    }
    // Common source coordinates preserve body scale and ground position across
    // laptop, walking and waving. The full raised laptop fits inside this frame.
    private static let viewport = CGRect(x: 711, y: 676, width: 1750, height: 1200)
    static let typingDuration = 80.0
    private static let settleDuration = 19.0 / 12
    private static let standDuration = 9.0 / 12
    private static let walkDuration = 6.4
    private static let waveDuration = 1.36
    private static let restDuration = 3.0
    static var cycleDuration: TimeInterval {
        settleDuration + typingDuration + standDuration + walkDuration + waveDuration + restDuration
    }

    /// Loop just the typing poses, not the complete take-out/put-away movie.
    /// The menu-bar owner supplies elapsed time from this animation's start.
    static func pose(at elapsed: TimeInterval) -> Pose {
        var t = max(0, elapsed).truncatingRemainder(dividingBy: cycleDuration)
        if t < settleDuration { return Pose(action: .settle, frame: min(18, Int(t * 12))) }
        t -= settleDuration
        if t < typingDuration { return Pose(action: .type, frame: 19 + Int(t * 12) % 15) }
        t -= typingDuration
        if t < standDuration { return Pose(action: .stand, frame: 34 + min(8, Int(t * 12))) }
        t -= standDuration
        if t < walkDuration {
            // Four gait loops: walk a few pixels across our fixed slot and back.
            // Both endpoints have zero velocity; text beside the icon stays put.
            let progress = t / walkDuration
            let offset = CGFloat((1 - cos(progress * 2 * .pi)) * 175)
            return Pose(action: .walk, frame: Int(t / 0.08) % 20, offsetX: offset)
        }
        t -= walkDuration
        if t < waveDuration { return Pose(action: .wave, frame: min(16, Int(t / 0.08))) }
        return Pose(action: .rest, frame: 0)
    }

    private struct Fill {
        let color: NSColor
        let path: NSBezierPath
    }
    private static let laptop: [[Fill]] = decodeLaptop()
    // Keep compressed sources, not an array of decoded full-canvas frames.
    private static let walking = gifSource("clawd-walking")
    private static let waving = gifSource("clawd-waving")
    private struct FrameKey: Hashable {
        let action: Action
        let frame: Int
        let height: Int
        let halfPointOffset: Int
    }
    private struct CachedFrame {
        let image: NSImage
        let bytes: Int
        var used: UInt64
    }
    private static var rendered: [FrameKey: CachedFrame] = [:]
    private static var cacheClock: UInt64 = 0
    static let cacheByteLimit = 8 * 1024 * 1024
    private(set) static var cachedPixelBytes = 0

    static func resetFrameCache() {
        rendered.removeAll(); cachedPixelBytes = 0; cacheClock = 0
    }

    private static func cached(_ key: FrameKey) -> NSImage? {
        guard var entry = rendered[key] else { return nil }
        cacheClock &+= 1; entry.used = cacheClock; rendered[key] = entry
        return entry.image
    }

    private static func retain(_ image: NSImage, for key: FrameKey) {
        let bytes = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .reduce(0) { $0 + $1.bytesPerRow * $1.pixelsHigh }
        guard bytes <= cacheByteLimit else { return }
        while cachedPixelBytes + bytes > cacheByteLimit,
              let oldest = rendered.min(by: { $0.value.used < $1.value.used }) {
            cachedPixelBytes -= oldest.value.bytes; rendered.removeValue(forKey: oldest.key)
        }
        cacheClock &+= 1
        rendered[key] = CachedFrame(image: image, bytes: bytes, used: cacheClock)
        cachedPixelBytes += bytes
    }

    static func image(at elapsed: TimeInterval, size: CGFloat) -> NSImage? {
        let pose = pose(at: elapsed)
        let height = max(1, Int(size.rounded()))
        let action: Action = [.walk, .wave].contains(pose.action) ? pose.action : .settle
        // One half point is one pixel on Retina. Each representation subsequently
        // rounds this position to its own pixel grid without resampling the body.
        let offset = Int((pose.offsetX * CGFloat(height) / viewport.height * 2).rounded())
        let key = FrameKey(action: action, frame: pose.frame, height: height, halfPointOffset: offset)
        if let image = cached(key) { return image }
        let baseKey = FrameKey(action: action, frame: pose.frame, height: height, halfPointOffset: 0)
        let base: NSImage
        if let image = cached(baseKey) { base = image }
        else {
            guard let image = prepare(action: action, frame: pose.frame, height: height) else { return nil }
            retain(image, for: baseKey); base = image
        }
        guard offset != 0 else { return base }
        let image = NSImage(size: base.size)
        for rep in base.representations.compactMap({ $0 as? NSBitmapImageRep }) {
            guard let cg = rep.cgImage, let context = bitmapContext(width: rep.pixelsWide, height: rep.pixelsHigh) else { return nil }
            let scale = CGFloat(rep.pixelsHigh) / base.size.height
            let pixels = (CGFloat(offset) / 2 * scale).rounded()
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: pixels, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
            guard let shifted = context.makeImage() else { return nil }
            let shiftedRep = NSBitmapImageRep(cgImage: shifted); shiftedRep.size = base.size
            image.addRepresentation(shiftedRep)
        }
        retain(image, for: key)
        return image
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func prepare(action: Action, frame: Int, height: Int) -> NSImage? {
        autoreleasepool {
            // Transparent padding rounds the canvas, not the character's proportions.
            let width = Int(ceil(CGFloat(height) * viewport.width / viewport.height))
            let dimensions = NSSize(width: width, height: height)
            let image = NSImage(size: dimensions)
            var gif: CGImage?
            var gifBounds = CGRect.zero
            if action == .walk || action == .wave {
                guard let source = action == .walk ? walking : waving,
                      frame < CGImageSourceGetCount(source),
                      let full = CGImageSourceCreateImageAtIndex(source, frame, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                // The shared viewport extends below the GIF canvas. Preserve that
                // transparent margin instead of stretching the intersected crop.
                gifBounds = viewport.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
                guard let crop = full.cropping(to: gifBounds) else { return nil }
                gif = crop
            } else if !laptop.indices.contains(frame) { return nil }
            for scale in [1, 2] {
                guard let context = bitmapContext(width: width * scale, height: height * scale) else { return nil }
                if let gif {
                    // Crop the original first, then downsample once to the final pixels.
                    context.interpolationQuality = .high
                    let factor = CGFloat(height * scale) / viewport.height
                    context.draw(gif, in: CGRect(x: (gifBounds.minX - viewport.minX) * factor,
                                                 y: CGFloat(height * scale) - (gifBounds.maxY - viewport.minY) * factor,
                                                 width: gifBounds.width * factor, height: gifBounds.height * factor))
                } else {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    context.translateBy(x: 0, y: CGFloat(height * scale))
                    let factor = CGFloat(height * scale) / viewport.height
                    context.scaleBy(x: factor, y: -factor)
                    context.translateBy(x: -viewport.minX, y: -viewport.minY)
                    for fill in laptop[frame] {
                        fill.color.setFill(); pixelAligned(fill.path).fill()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                }
                guard let pixels = context.makeImage() else { return nil }
                let rep = NSBitmapImageRep(cgImage: pixels); rep.size = dimensions
                image.addRepresentation(rep)
            }
            return image
        }
    }

    /// This artwork contains only straight segments. Snap their vertices in
    /// the fixed frame's pixel space once, never the moving status item's space.
    /// Antialiasing remains enabled for the laptop's diagonal edges.
    private static func pixelAligned(_ source: NSBezierPath) -> NSBezierPath {
        guard let context = NSGraphicsContext.current?.cgContext else { return source }
        let result = NSBezierPath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<source.elementCount {
            let element = source.element(at: index, associatedPoints: &points)
            if element == .closePath { result.close(); continue }
            // decodeLaptop accepts only move/line/close from the source subset.
            let device = context.convertToDeviceSpace(points[0])
            let aligned = context.convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y.rounded()))
            if element == .moveTo { result.move(to: aligned) }
            else if element == .lineTo { result.line(to: aligned) }
        }
        return result
    }

    /// This source is a particularly small Lottie subset: static closed paths,
    /// identity transforms and hold-keyframed fill opacity. Read those exact
    /// paths, without a third-party playback engine or a hand-drawn imitation.
    private static func decodeLaptop() -> [[Fill]] {
        guard let url = AnimationResources.url(forResource: "clawd-laptop", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = json["layers"] as? [[String: Any]] else { return [] }
        return (0..<43).map { frame in
            var fills: [Fill] = []
            for layer in layers.reversed() {
                for group in layer["shapes"] as? [[String: Any]] ?? [] {
                    guard let items = group["it"] as? [[String: Any]],
                          let fill = items.first(where: { $0["ty"] as? String == "fl" }),
                          let colorProperty = fill["c"] as? [String: Any],
                          let color = colorProperty["k"] as? [Double], color.count == 4,
                          let opacityProperty = fill["o"] as? [String: Any] else { continue }
                    let opacity: Double
                    if let keys = opacityProperty["k"] as? [[String: Any]] {
                        opacity = (keys.last(where: { ($0["t"] as? Double ?? 0) <= Double(frame) })?["s"] as? [Double])?.first ?? 0
                    } else { opacity = opacityProperty["k"] as? Double ?? 0 }
                    guard opacity > 0 else { continue }
                    let path = NSBezierPath()
                    for item in items where item["ty"] as? String == "sh" {
                        guard let ks = item["ks"] as? [String: Any],
                              let shape = ks["k"] as? [String: Any],
                              let vertices = shape["v"] as? [[Double]],
                              let first = vertices.first, first.count == 2 else { continue }
                        path.move(to: NSPoint(x: first[0], y: first[1]))
                        for vertex in vertices.dropFirst() where vertex.count == 2 {
                            path.line(to: NSPoint(x: vertex[0], y: vertex[1]))
                        }
                        path.close()
                    }
                    fills.append(Fill(color: NSColor(calibratedRed: color[0], green: color[1], blue: color[2],
                                                     alpha: color[3] * opacity / 100), path: path))
                }
            }
            return fills
        }
    }

    private static func gifSource(_ name: String) -> CGImageSource? {
        guard let url = AnimationResources.url(forResource: name, withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return source
    }
}
