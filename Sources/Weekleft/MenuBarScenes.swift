import AppKit

/// Animate the selected Tide artwork, retaining its light and proportions.
@MainActor enum MenuBarScenes {
    static let cycleDuration = 6.0
    static let frameCount = 144

    struct Pose {
        let lift: CGFloat
        let spread: CGFloat
        let scale: CGFloat
    }
    static func pose(frame: Int) -> Pose {
        let t = Double((frame % frameCount + frameCount) % frameCount) / Double(frameCount)
        // Position and velocity match at the loop seam. A gentle breath opens the two faces
        // once per cycle while the whole object continues to hover.
        let breath = pow((1 - cos(t * .pi * 2)) / 2, 2)
        return Pose(lift: CGFloat(sin(t * .pi * 2)) * 0.8,
                    spread: CGFloat(breath) * 2.4, scale: 1 + CGFloat(breath) * 0.07)
    }
    static func draw(_ icon: MenuBarIcon, frame: Int) {
        guard icon == .lunavect,
              let left = AppArtwork.brandMarkLeft,
              let right = AppArtwork.brandMarkRight else { return }
        let pose = pose(frame: frame)
        NSGraphicsContext.current?.imageInterpolation = .high
        let side = 27 * pose.scale
        let y = (22 - side) / 2 + pose.lift
        // Each transparent layer contains a complete curved object on the same
        // canvas. Splitting the bitmap at its midpoint would cut the tilted tips.
        for (image, direction) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
            let destination = NSRect(x: 17 - side / 2 + direction * pose.spread,
                                     y: y, width: side, height: side)
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
    }
}
