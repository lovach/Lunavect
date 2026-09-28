import AppKit
import SwiftUI
import XCTest
import WeekleftCore
@testable import Weekleft

/// A Claude model window that runs out first in the limits popover, next to the
/// Settings limits card. Opt-in, inside the render sandbox.
@MainActor final class ModelLimitRenderingTests: XCTestCase {
    func testRenderModelLimitInPopoverAndSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_FABLE"] else { throw XCTSkip("Opt-in isolated native rendering") }
        try LegacyRenderIsolation.require()
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        func claude(fable: Double) throws -> UsageSnapshot {
            let week = now.addingTimeInterval(6 * 86400 + 13 * 3600)
            return UsageSnapshot(provider: .claude,
                weekly: try QuotaWindow(usedPercent: 27, durationMinutes: 10080, resetsAt: week),
                fiveHour: try QuotaWindow(usedPercent: 2, durationMinutes: 300, resetsAt: now.addingTimeInterval(4 * 3600 + 28 * 60)),
                fetchedAt: now.addingTimeInterval(-60), source: "Claude Code /usage",
                modelQuotas: [ModelQuota(name: "Fable", window: try QuotaWindow(usedPercent: fable, durationMinutes: 10080, resetsAt: week), fetchedAt: now.addingTimeInterval(-60))])
        }
        let codex = UsageSnapshot(provider: .codex,
            weekly: try QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: now.addingTimeInterval(4 * 86400)),
            fiveHour: try QuotaWindow(usedPercent: 5, durationMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600)),
            fetchedAt: now.addingTimeInterval(-60), source: "Codex app-server")
        for scheme in [ColorScheme.dark, .light] {
            let tone = scheme == .dark ? "dark" : "light"
            for (name, fable) in [("fable-16", 16.0), ("fable-85", 85.0)] {
                let snapshots = [try claude(fable: fable), codex]
                let model = MenuBarLimitsPanelModel()
                model.entries = MenuBarLimitEntry.make(snapshots: snapshots, providers: ProviderID.allCases, preferences: .init(enabled: true), now: now)
                try render(MenuBarLimitsPopover(model: model, onPeriod: { _ in }, onRefresh: {}, onMenu: {}, onSettings: {}),
                           width: 340, scheme: scheme, to: output.appendingPathComponent("popover-\(name)-\(tone).png"))
            }
            let fixture = try LegacyRenderFixture(snapshots: [try claude(fable: 16), codex], now: now)
            defer { fixture.stop() }
            try render(LimitsOverview(store: fixture.environment.store, onConnections: {}).padding(16).defaultAppStorage(fixture.environment.defaults),
                       width: 560, scheme: scheme, to: output.appendingPathComponent("settings-limits-\(tone).png"))
        }
    }

    private func render<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme, to url: URL) throws {
        let root = view.frame(width: width).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var size = CGSize(width: width, height: 200)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<3 {
            for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded() }
            size.height = ceil(host.fittingSize.height); host.frame = CGRect(origin: .zero, size: size)
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
