import AppKit
import SwiftUI
import WeekleftCore
import XCTest
@testable import Weekleft

final class WidgetDesignRenderingTests: XCTestCase {
    // Value-only production views; fictional history and no stores or visible windows.
    @MainActor func testRenderActivityWidgetDesigns() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_WIDGET_DESIGN"] else {
            throw XCTSkip("Opt-in native widget design comparison")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        NSTimeZone.default = calendar.timeZone
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 19)))
        let today = calendar.startOfDay(for: now)
        var history = ActivityHistory()
        var recovered: [ActivityInterval] = []
        for (index, values) in [(75, 140), (120, 110), (0, 180), (45, 780), (55, 210), (100, 385), (35, 120)].enumerated() {
            let start = today.addingTimeInterval(Double((index - 6) * 86400 + 8 * 3600))
            for (minutes, provider) in [(values.0, 1), (values.1, 2)] where minutes > 0 {
                recovered.append(ActivityInterval(start: start, end: start.addingTimeInterval(Double(minutes * 60)), providers: provider))
            }
        }
        history.mergeRecovered(recovered, now: now, limited: false)
        let snapshots = try ProviderID.allCases.map { id in
            try UsageSnapshot(provider: id,
                weekly: QuotaWindow(usedPercent: id == .claude ? 35 : 58, durationMinutes: 10080, resetsAt: now.addingTimeInterval(id == .claude ? 18000 : 486000)),
                fiveHour: QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600)), fetchedAt: now)
        }
        var preferences = WidgetPreferences()
        preferences.subscriptionDates = ["claude": "2026-10-02", "codex": "2026-10-09"]
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] ?? "ru"
        for selected in [false, true] {
            for layout: (String, LunavectWidgetContent, LunavectWidgetSize) in [
                ("limits", .limits, .medium), ("small", .activity, .small), ("medium", .activity, .medium),
                ("large", .activity, .large), ("overview", .overview, .large)] {
                if selected && layout.1 == .limits { continue }
                let date = selected ? today.addingTimeInterval(-86400) : nil
                let card = LunavectWidgetCard(snapshots: snapshots, preferences: preferences, history: history,
                    content: layout.1, family: layout.2, now: now, selectedDate: date,
                    resetButton: AnyView(ActivitySelectionResetLabel()),
                    pointNavigation: { _, _ in AnyView(HStack(spacing: 2) {
                        Image(systemName: "chevron.left").frame(width: 26, height: 26)
                        ActivitySelectionResetLabel()
                        Image(systemName: "chevron.right").frame(width: 26, height: 26)
                    }.font(.system(size: 10))) })
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                try render(card, size: layout.2.dimensions,
                           to: directory.appendingPathComponent("\(language)-\(layout.0)-\(selected ? "selected" : "summary").png"))
            }
        }
        // Adversarial states for the two dense layouts: large totals, unavailable and one provider.
        for providers in [[ProviderID.claude], [.claude, .codex]] {
            preferences.enabledProviders = providers; preferences.showFiveHour = true
            for available in [false, true] {
                for layout in [LunavectWidgetSize.small, .large] {
                    let card = LunavectWidgetCard(snapshots: available ? snapshots : [], preferences: preferences,
                        history: available ? history : ActivityHistory(), content: layout == .small ? .activity : .overview,
                        family: layout, now: now, activityUnavailable: !available)
                    try render(card, size: layout.dimensions,
                        to: directory.appendingPathComponent("\(language)-\(layout.rawValue)-\(providers.count)-\(available ? "data" : "unavailable").png"))
                }
            }
        }
    }
    @MainActor private func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark).environment(\.locale, L10n.locale))
        renderer.scale = 2; renderer.proposedSize = ProposedViewSize(size)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
