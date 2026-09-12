import XCTest
import AppKit
import SwiftUI
@testable import Weekleft

final class WidgetGalleryTests: XCTestCase {
    @MainActor func testNativePlacementGuide() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_GALLERY"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = WidgetGalleryControls(selection: "Лимиты · Средний").padding(24)
        let host = NSHostingView(rootView: view.frame(width: 540, height: 240).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua); host.frame = CGRect(x: 0, y: 0, width: 540, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("manual-guide.png"))
        window.contentView = nil
    }
}
