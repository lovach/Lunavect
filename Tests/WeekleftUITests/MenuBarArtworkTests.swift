import XCTest
import AppKit
import ImageIO
@testable import Weekleft

final class MenuBarArtworkTests: XCTestCase {
    @MainActor func testClaudeWholeCycleHasNativeScalesAndBoundedCache() throws {
        ClawdAnimation.resetFrameCache()
        let count = Int(ceil(ClawdAnimation.cycleDuration * 24))
        var inspected = Set<ObjectIdentifier>()
        var bounds = [Int: (min: Int, max: Int)]()
        let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CLAUDE_CYCLE"]
        let destination = output.flatMap { CGImageDestinationCreateWithURL(URL(fileURLWithPath: $0) as CFURL, "public.png" as CFString, count, nil) }
        if output != nil { XCTAssertNotNil(destination) }
        if let destination {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        }
        let first = try XCTUnwrap(ClawdAnimation.image(at: 0, size: 28))
        for index in 0..<count {
            try autoreleasepool {
                let image = try XCTUnwrap(ClawdAnimation.image(at: Double(index) / 24, size: 28))
                XCTAssertEqual(image.size, NSSize(width: 41, height: 28))
                let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
                XCTAssertEqual(reps.map(\.pixelsWide), [41, 82])
                XCTAssertEqual(reps.map(\.pixelsHigh), [28, 56])
                if inspected.insert(ObjectIdentifier(image)).inserted {
                    for rep in reps {
                        let bytes = try XCTUnwrap(rep.bitmapData)
                        XCTAssertEqual(rep.samplesPerPixel, 4)
                        let alpha = rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3
                        var visible = 0
                        for y in 0..<rep.pixelsHigh {
                            for x in 0..<rep.pixelsWide where bytes[y * rep.bytesPerRow + x * 4 + alpha] > 16 {
                                visible += 1
                                let previous = bounds[rep.pixelsHigh] ?? (rep.pixelsHigh, 0)
                                bounds[rep.pixelsHigh] = (min(previous.min, y), max(previous.max, y))
                            }
                        }
                        XCTAssertGreaterThan(visible, 25, "Character remains visible throughout the cycle")
                        for (x, y) in [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1)] {
                            XCTAssertEqual(bytes[y * rep.bytesPerRow + x * 4 + alpha], 0, "No opaque backdrop")
                        }
                    }
                }
                if let destination, let cg = reps.last?.cgImage {
                    CGImageDestinationAddImage(destination, cg, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 1.0 / 24]] as CFDictionary)
                }
                XCTAssertLessThanOrEqual(ClawdAnimation.cachedPixelBytes, ClawdAnimation.cacheByteLimit)
            }
        }
        if let destination { XCTAssertTrue(CGImageDestinationFinalize(destination)) }
        XCTAssertTrue(first === ClawdAnimation.image(at: 0, size: 28), "A full cycle must not flush its initial frame")
        print("Claude cycle: \(count) samples, \(inspected.count) distinct cached images, \(ClawdAnimation.cachedPixelBytes) pixel bytes; vertical alpha bounds: \(bounds)")
        // Other preview sizes must not grow the cache without bound.
        for size: CGFloat in [44, 88] {
            for index in 0..<43 { _ = ClawdAnimation.image(at: Double(index) / 12, size: size) }
        }
        XCTAssertLessThanOrEqual(ClawdAnimation.cachedPixelBytes, ClawdAnimation.cacheByteLimit)
    }

    @MainActor func testClaudeWalkingTranslatesPixelsWithoutChangingTheirAlpha() throws {
        let start = 19.0 / 12 + 80 + 9.0 / 12
        let base = try XCTUnwrap(ClawdAnimation.image(at: start + 0.00001, size: 28))
        let moved = try XCTUnwrap(ClawdAnimation.image(at: start + 1.60001, size: 28))
        for scale in [1, 2] {
            let a = try XCTUnwrap(base.representations[scale - 1] as? NSBitmapImageRep)
            let b = try XCTUnwrap(moved.representations[scale - 1] as? NSBitmapImageRep)
            let ab = try XCTUnwrap(a.bitmapData), bb = try XCTUnwrap(b.bitmapData)
            let aa = a.bitmapFormat.contains(.alphaFirst) ? 0 : 3
            let ba = b.bitmapFormat.contains(.alphaFirst) ? 0 : 3
            var expected: [UInt8] = [], actual: [UInt8] = []
            for y in 0..<a.pixelsHigh {
                for x in 0..<a.pixelsWide {
                    let sourceX = x - 4 * scale
                    expected.append(sourceX >= 0 ? ab[y * a.bytesPerRow + sourceX * 4 + aa] : 0)
                    actual.append(bb[y * b.bytesPerRow + x * 4 + ba])
                }
            }
            XCTAssertEqual(actual, expected, "Walking moves one intact sprite on the \(scale)x pixel grid")
        }
    }

    @MainActor func testClaudeTemplatePreservesBothRasterScales() throws {
        let original = try XCTUnwrap(ClawdAnimation.image(at: 5, size: 28))
        let template = MenuBarArtwork.styled(original, systemColor: true)
        XCTAssertTrue(template.isTemplate)
        XCTAssertFalse(original.isTemplate)
        XCTAssertEqual(template.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }, [41, 82])
        XCTAssertEqual(template.size, original.size)
    }

    @MainActor func testRenderClaudePhasesAtCurrentSize() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CLAUDE"] else { throw XCTSkip("Opt-in Claude phase rendering") }
        _ = NSApplication.shared
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        board.appearance = NSAppearance(named: .darkAqua)
        board.wantsLayer = true; board.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        defer { window.contentView = nil }
        for (index, elapsed) in [0.0, 1.0, 5.0, 82.0, 85.0, 89.0].enumerated() {
            let image = try XCTUnwrap(ClawdAnimation.image(at: elapsed, size: 28))
            let view = MenuBarStatusContent(frame: NSRect(x: 94, y: CGFloat(258 - index * 47), width: 270, height: 32))
            view.running = 1; view.thinkingPhrase = "finding flow"
            view.pixelAlignedArtwork = true
            view.artwork.image = image; view.iconWidth = image.size.width
            view.frame.size.width = view.preferredWidth
            board.addSubview(view); view.needsLayout = true
            let label = NSTextField(labelWithString: ClawdAnimation.pose(at: elapsed).action.rawValue)
            label.font = .systemFont(ofSize: 11)
            label.frame = NSRect(x: 12, y: view.frame.minY + 7, width: 80, height: 18)
            board.addSubview(label)
        }
        board.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
        board.cacheDisplay(in: board.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }

    @MainActor func testSystemColourPersistsWithoutChangingColourArtwork() throws {
        let name = "Lunavect.MenuBarTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MenuBarAppearance(defaults: defaults)
        XCTAssertFalse(settings.systemColor)
        settings.systemColor = true
        XCTAssertTrue(MenuBarAppearance(defaults: defaults).systemColor)
        let colour = try XCTUnwrap(MenuBarArtwork.image(.lunavect, frame: 0))
        let template = MenuBarArtwork.styled(colour, systemColor: true)
        XCTAssertTrue(template.isTemplate)
        XCTAssertFalse(colour.isTemplate, "Template rendering must not mutate cached colour frames")
        XCTAssertTrue(MenuBarArtwork.styled(colour, systemColor: false) === colour)
    }
    @MainActor func testFoldMotionClosesTheLoopAndKeepsFacesInSlot() {
        let first = MenuBarScenes.pose(frame: 0), last = MenuBarScenes.pose(frame: MenuBarScenes.frameCount)
        XCTAssertEqual(first.lift, last.lift); XCTAssertEqual(first.spread, last.spread)
        XCTAssertEqual(first.spread, 0)
        XCTAssertGreaterThan(MenuBarScenes.pose(frame: MenuBarScenes.frameCount / 2).spread, 2)
        for frame in 0..<MenuBarScenes.frameCount {
            let pose = MenuBarScenes.pose(frame: frame)
            XCTAssertLessThan(27 * pose.scale / 2 + pose.spread, 17)
        }
    }
    @MainActor func testRenderAnimation() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_MOTION"] else { throw XCTSkip("Opt-in animation rendering") }
        let url = URL(fileURLWithPath: output + ".gif")
        let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, MenuBarScenes.frameCount, nil))
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<MenuBarScenes.frameCount {
            let artwork = try XCTUnwrap(MenuBarArtwork.image(.lunavect, frame: frame, size: 88))
            let preview = NSImage(size: NSSize(width: 160, height: 112), flipped: false) { bounds in
                NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
                artwork.draw(in: NSRect(x: (160-artwork.size.width)/2, y: 12, width: artwork.size.width, height: artwork.size.height))
                return true
            }
            let data = try XCTUnwrap(preview.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let cg = try XCTUnwrap(bitmap.cgImage)
            CGImageDestinationAddImage(gif, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: MenuBarScenes.cycleDuration / Double(MenuBarScenes.frameCount)]] as CFDictionary)
            if [0, 36, 72, 108].contains(frame) {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "-\(frame).png"))
            }
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))
    }
}
