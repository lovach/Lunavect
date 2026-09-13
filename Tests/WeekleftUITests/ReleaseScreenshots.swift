import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

/// Public media uses production views and injected, fictional state. Only the
/// sandbox launcher may run this exporter; its windows are never displayed.
final class ReleaseScreenshots: XCTestCase {
    @MainActor func testRenderPublicScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RELEASE_SCREENSHOTS"] else {
            throw XCTSkip("Opt-in public screenshots using fictional data")
        }
        try LegacyRenderIsolation.require()
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // TimelineView uses the current clock. Keep every visible session fresh
        // and derive all charts and allowances from this same capture instant.
        let preview = try LegacyRenderFixture(now: Date())
        defer { preview.stop() }
        let defaults = preview.environment.defaults
        let fixture = preview.presentation
        let sessionView = SessionsView(store: preview.environment.sessions,
            updates: preview.environment.updates, awake: preview.environment.awake,
            onSettings: {}).defaultAppStorage(defaults)
        func widget(_ content: LunavectWidgetContent, _ family: LunavectWidgetSize) -> some View {
            LunavectWidgetCard(snapshots: fixture.snapshots, preferences: fixture.preferences,
                history: fixture.history, content: content, family: family, now: fixture.now)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        for (section, name, height) in [("limits", "limits", 640), ("statistics", "readme-activity", 980)] {
            defaults.set(section, forKey: "settingsSection")
            try render(preview.settings(), size: CGSize(width: 920, height: height),
                to: output.appendingPathComponent(name + ".png"))
        }
        let entries = MenuBarLimitEntry.make(snapshots: fixture.snapshots, providers: [.claude, .codex],
            preferences: MenuBarLimitsPreferences(enabled: true), now: fixture.now)
        let menuBar = VStack(alignment: .leading, spacing: 18) {
            Text("Menu bar limits").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 20) {
                ForEach(MenuBarLimitsStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(style.title).font(.system(size: 12)).foregroundStyle(.secondary)
                        MenuBarLimitsPreview(entries: entries, style: style, iconColor: .provider)
                            .frame(height: 30).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(24)
        try render(menuBar, size: CGSize(width: 720, height: 144),
            to: output.appendingPathComponent("menu-bar.png"))
        for scheme in [ColorScheme.dark, .light] {
            let panel = sessionView.frame(width: 360, height: 355)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            let showcase = HStack(alignment: .top, spacing: 32) {
                panel
                VStack(spacing: 24) { widget(.limits, .medium); widget(.activity, .medium) }
            }
            let suffix = scheme == .dark ? "dark" : "light"
            try render(showcase.padding(24), size: CGSize(width: 784, height: 403),
                to: output.appendingPathComponent("readme-overview-\(suffix).png"), scheme: scheme, transparent: true)
            try render(panel.padding(16), size: CGSize(width: 392, height: 387),
                to: output.appendingPathComponent("readme-sessions-\(suffix).png"), scheme: scheme, transparent: true)
        }
        for (name, content, family): (String, LunavectWidgetContent, LunavectWidgetSize) in [
            ("widget-overview", .overview, .large), ("widget-activity-large", .activity, .large),
            ("widget-activity-small", .activity, .small), ("widget-limits", .limits, .medium)
        ] {
            try render(widget(content, family), size: family.dimensions,
                to: output.appendingPathComponent(name + ".png"), transparent: true)
        }
    }

    @MainActor private func render<V: View>(_ view: V, size: CGSize, to path: URL,
                                            scheme: ColorScheme = .dark, transparent: Bool = false) throws {
        let observed = NativeRenderEnvironmentCapture(content: view) { values in
            if let target = ProcessInfo.processInfo.environment["LUNAVECT_NATIVE_RENDER_ENVIRONMENT"],
               let json = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
                try? json.write(to: URL(fileURLWithPath: target))
            }
        }
        let root = observed.frame(width: size.width, height: size.height)
            .background(transparent ? Color.clear : Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).environment(\.controlActiveState, .key)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = GalleryRenderWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .windowBackgroundColor
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.07)); host.layoutSubtreeIfNeeded() }
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width * 2))
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height * 2))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}

/// Appearance for our offscreen canvas; never activates an application or window.
@MainActor private final class GalleryRenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var backingScaleFactor: CGFloat { 2 }
}
