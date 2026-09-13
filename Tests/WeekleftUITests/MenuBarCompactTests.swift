import AppKit
import SwiftUI
import WeekleftCore
import XCTest
@testable import Weekleft

final class MenuBarCompactTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func snapshots(used: Double = 79, stale: Bool = false) throws -> [UsageSnapshot] {
        try ProviderID.allCases.map { provider in
            try UsageSnapshot(provider: provider,
                weekly: QuotaWindow(usedPercent: provider == .claude ? 95 : used, durationMinutes: 10080,
                                    resetsAt: now.addingTimeInterval(6 * 86400)),
                fetchedAt: now.addingTimeInterval(stale ? -3600 : 0))
        }
    }
    @MainActor func testCompactChoicePersistsAndShrinksNativeItemWithoutValueJitter() throws {
        let suite = "Lunavect.CompactTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = MenuBarAppearance(defaults: defaults)
        appearance.limits = .init(enabled: true, style: .percentages, iconColor: .provider, showsResetCountdown: true)
        XCTAssertEqual(MenuBarAppearance(defaults: defaults).limits.style, .percentages)
        let controller = MenuBarLimitsController(autosaveName: nil) {}
        defer { controller.stop() }
        controller.update(snapshots: try snapshots(), providers: ProviderID.allCases, preferences: .init(enabled: true), now: now)
        let wide = try XCTUnwrap(controller.statusItem).length
        controller.update(snapshots: try snapshots(), providers: ProviderID.allCases, preferences: appearance.limits, now: now)
        let compact = try XCTUnwrap(controller.statusItem).length
        XCTAssertLessThan(compact, wide)
        XCTAssertEqual(controller.content.entries.map(\.value), ["5%", "21%"])
        for data in [try snapshots(used: 0, stale: true), try snapshots(used: 100), []] {
            controller.update(snapshots: data, providers: ProviderID.allCases, preferences: appearance.limits, now: now)
            XCTAssertEqual(controller.statusItem?.length, compact)
        }
        XCTAssertEqual(controller.content.entries.map(\.value), ["—", "—"])
        appearance.limits.style = .bars
        XCTAssertTrue(appearance.limits.showsResetCountdown, "Switching formats must preserve the bar countdown choice")
        controller.update(snapshots: try snapshots(), providers: ProviderID.allCases, preferences: appearance.limits, now: now)
        XCTAssertEqual(controller.statusItem?.length, wide)
    }

    /// Offscreen production AppKit/SwiftUI views with synthetic values and a
    /// private defaults suite. Never writes the user's language or settings.
    @MainActor func testRenderCompactIndicatorAndSettings() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_COMPACT_LIMITS"] else {
            throw XCTSkip("Opt-in offscreen compact limits rendering")
        }
        _ = NSApplication.shared
        let language = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] ?? "en"
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Lunavect.CompactRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = MenuBarAppearance(defaults: defaults)
        appearance.limits = .init(enabled: true, style: .percentages, iconColor: .provider)
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let board = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
            board.wantsLayer = true
            board.layer?.backgroundColor = NSColor(white: dark ? 0.12 : 0.96, alpha: 1).cgColor
            board.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (row, height) in [CGFloat(22), 28, 32].enumerated() {
                for (column, style) in [MenuBarLimitsStyle.bars, .percentages].enumerated() {
                    let x = CGFloat(column) * 260 + 16, y = CGFloat(2 - row) * 62 + 10
                    let label = NSTextField(labelWithString: style.title + " · \(Int(height)) pt")
                    label.font = .systemFont(ofSize: 11); label.textColor = .labelColor
                    label.frame = NSRect(x: x, y: y + 35, width: 244, height: 20); board.addSubview(label)
                    let view = MenuBarLimitsContent(frame: NSRect(x: x, y: y, width: 230, height: height))
                    view.style = style; view.iconColor = .provider
                    view.entries = MenuBarLimitEntry.make(snapshots: try snapshots(used: row == 1 ? 0 : 79, stale: row == 1),
                        providers: ProviderID.allCases, preferences: appearance.limits, now: now)
                    view.frame.size.width = view.preferredWidth
                    board.addSubview(view)
                }
            }
            try render(board, to: directory.appendingPathComponent("compact-\(language)-\(theme).png"))
            let host = NSHostingView(rootView: MenuBarLimitsSettings(appearance: appearance, snapshots: try snapshots(), providers: ProviderID.allCases)
                .padding(20).frame(width: 570).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = board.appearance
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            XCTAssertLessThanOrEqual(host.frame.width, 571)
            try render(host, to: directory.appendingPathComponent("compact-settings-\(language)-\(theme).png"))
        }
    }
    @MainActor private func render(_ view: NSView, to url: URL) throws {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
