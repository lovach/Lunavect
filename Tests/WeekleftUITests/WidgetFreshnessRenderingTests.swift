import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class WidgetFreshnessRenderingTests: XCTestCase {
    @MainActor func testRenderStaleClaudeAlongsideFreshCodex() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_FRESHNESS"] else { throw XCTSkip("Opt-in native widget rendering") }
        try LegacyRenderIsolation.require()
        let now = LegacyRenderIsolation.now
        let snapshots = [
            UsageSnapshot(provider: .claude,
                weekly: try QuotaWindow(usedPercent: 84, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
                fiveHour: try QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: now.addingTimeInterval(-100)),
                fetchedAt: now.addingTimeInterval(-8 * 3600), source: "Claude Code statusLine"),
            UsageSnapshot(provider: .codex,
                weekly: try QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: now.addingTimeInterval(6 * 86400)),
                // A different window's reset must not dim the current weekly value.
                fiveHour: try QuotaWindow(usedPercent: 40, durationMinutes: 300, resetsAt: now.addingTimeInterval(-60)),
                fetchedAt: now, source: "Codex CLI")
        ]
        var prefs = WidgetPreferences(); prefs.showFiveHour = true
        prefs.subscriptionDates = ["claude": "2026-10-02", "codex": "2026-10-09"]
        let language = try LegacyRenderIsolation.language()
        try LegacyRenderIsolation.render(WeekleftCard(snapshots: snapshots, preferences: prefs, now: now),
            size: CGSize(width: 344, height: 172), to: URL(fileURLWithPath: output + "-" + language + ".png"))
    }
}
