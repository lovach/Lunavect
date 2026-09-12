import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class WidgetFreshnessRenderingTests: XCTestCase {
    @MainActor func testRenderStaleClaudeAlongsideFreshCodex() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_FRESHNESS"] else { throw XCTSkip("Opt-in native widget rendering") }
        _ = NSApplication.shared
        let now = Date()
        let snapshots = [
            UsageSnapshot(provider: .claude,
                weekly: try QuotaWindow(usedPercent: 84, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
                fiveHour: try QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: now.addingTimeInterval(-100)),
                fetchedAt: now.addingTimeInterval(-8 * 3600), source: "Claude Code statusLine"),
            UsageSnapshot(provider: .codex,
                weekly: try QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: now.addingTimeInterval(6 * 86400)),
                fetchedAt: now, source: "Codex CLI")
        ]
        var prefs = WidgetPreferences(); prefs.showFiveHour = true
        prefs.subscriptionDates = ["claude": "2026-10-02", "codex": "2026-10-09"]
        let oldLanguage = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        for language in ["ru", "en", "de", "es", "fr", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            let host = NSHostingView(rootView: WeekleftCard(snapshots: snapshots, preferences: prefs, now: now)
                .background(Color.black).preferredColorScheme(.dark))
            host.frame = CGRect(x: 0, y: 0, width: 344, height: 172)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "-" + language + ".png"))
            window.contentView = nil
        }
    }
}
