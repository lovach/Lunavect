import AppKit
import SwiftUI
import WeekleftCore
import XCTest
@testable import Weekleft

/// Only invoked by check-native-renders.py after its sandbox preflight passes.
/// No app stores, client integrations, NSApplication or windows are constructed.
final class NativeRenderSmokeTests: XCTestCase {
    @MainActor private var effectiveAccessibility: [String: String] = [:]
    @MainActor func testRenderSyntheticStates() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LUNAVECT_NATIVE_RENDER_ISOLATION"] == "passed",
              let path = env["LUNAVECT_NATIVE_RENDER_OUTPUT"],
              let syntheticHome = env["CFFIXED_USER_HOME"],
              let forbidden = env["LUNAVECT_NATIVE_RENDER_FORBIDDEN"] else {
            throw XCTSkip("Opt-in isolated render: use scripts/check-native-renders.py --run")
        }
        #if !DEBUG
        throw XCTSkip("The preview-language override requires a DEBUG test build")
        #else
        let language = try XCTUnwrap(env["LUNAVECT_PREVIEW_LANGUAGE"])
        guard ["ru", "de"].contains(language), L10n.selection == language,
              Bundle.main.object(forInfoDictionaryKey: "WeekleftAppGroup") == nil,
              URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path == URL(fileURLWithPath: syntheticHome).standardizedFileURL.path else {
            throw XCTSkip("Synthetic home/language requirements not met; no views were evaluated")
        }
        // Recheck the boundary inside the actual XCTest process before evaluating views.
        XCTAssertThrowsError(try Data(contentsOf: URL(fileURLWithPath: forbidden)))
        XCTAssertThrowsError(try Data("synthetic".utf8).write(to: URL(fileURLWithPath: forbidden)))
        guard !FileManager.default.isReadableFile(atPath: forbidden) else {
            throw XCTSkip("Sandbox did not deny the synthetic sentinel; no views were evaluated")
        }
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 9, minute: 56))!
        var preferences = WidgetPreferences()
        preferences.enabledProviders = [.claude, .codex]
        preferences.showFiveHour = true
        var singleProviderPreferences = preferences
        singleProviderPreferences.enabledProviders = [.claude]
        let layouts: [(name: String, content: LunavectWidgetContent, family: LunavectWidgetSize, preferences: WidgetPreferences)] = [
            ("limits", .limits, .medium, preferences),
            ("limits-small", .limits, .small, preferences),
            ("limits-single-claude", .limits, .medium, singleProviderPreferences),
            ("limits-single-claude-small", .limits, .small, singleProviderPreferences),
            // The overview widget supports only systemLarge (344 × 344 points).
            ("overview-large", .overview, .large, preferences),
        ]
        let current = try snapshots(now: now)
        let unknown = ProviderID.allCases.map { UsageSnapshot(provider: $0) }
        var stale = current
        stale[0] = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 84, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
            fiveHour: QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: now.addingTimeInterval(-100)),
            fetchedAt: now.addingTimeInterval(-8 * 3600), source: "Synthetic fixture")
        XCTAssertTrue(stale[0].isStale(now: now))
        XCTAssertTrue(try XCTUnwrap(stale[0].fiveHour).isExpired(at: now))
        XCTAssertTrue(unknown.allSatisfy { $0.weekly == nil && $0.fetchedAt == nil })

        let start = calendar.startOfDay(for: now)
        var history = ActivityHistory()
        for (hour, minutes, provider) in [(0, 27, 1), (1, 24, 2), (2, 60, 0), (3, 60, 0), (8, 50, 3), (9, 54, 3)] {
            let begin = start.addingTimeInterval(Double(hour * 3600))
            history.append(start: begin, end: begin.addingTimeInterval(Double(minutes * 60)), providers: provider, observedProviders: 3)
        }
        let chart = ActivityChartData(history: history, now: now, period: .day, providers: [.claude, .codex], calendar: calendar)
        XCTAssertEqual(chart.points[2].totals.active, 0)
        XCTAssertGreaterThan(chart.points[2].totals.observed, 0)
        XCTAssertEqual(chart.points[5].totals.observed, 0)
        XCTAssertEqual(chart.points[9].totals.active, 54 * 60)
        for series in chart.series {
            let values = ActivityTrendSamples.values(for: series, period: .day, now: now)
            XCTAssertEqual(values[2], 0)
            XCTAssertNil(values[5])
            XCTAssertNil(values[9])
        }

        for scheme in [ColorScheme.light, .dark] {
            let suffix = "\(language)-\(scheme == .dark ? "dark" : "light")"
            for (state, snapshots) in [("current", current), ("unknown", unknown), ("stale-expired", stale)] {
                for layout in layouts {
                    let card = LunavectWidgetCard(snapshots: snapshots, preferences: layout.preferences,
                        history: layout.content == .overview && state != "unknown" ? history : ActivityHistory(),
                        content: layout.content, family: layout.family, now: now, period: .day)
                    try render(card, size: layout.family.dimensions, scheme: scheme, language: language,
                               calendar: calendar, to: URL(fileURLWithPath: path).appendingPathComponent("\(layout.name)-\(state)-\(suffix).png"))
                }
            }
            try render(ActivityDetailChart(data: chart, chartHeight: 220).padding(16),
                       size: CGSize(width: 620, height: 540), scheme: scheme, language: language, calendar: calendar,
                       to: URL(fileURLWithPath: path).appendingPathComponent("activity-contour-day-\(suffix).png"))
        }
        let environmentPath = try XCTUnwrap(env["LUNAVECT_NATIVE_RENDER_ENVIRONMENT"])
        try JSONSerialization.data(withJSONObject: effectiveAccessibility, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: environmentPath))
        #endif
    }

    private func snapshots(now: Date) throws -> [UsageSnapshot] {
        try ProviderID.allCases.enumerated().map { index, provider in
            UsageSnapshot(provider: provider,
                weekly: try QuotaWindow(usedPercent: index == 0 ? 32 : 46, durationMinutes: 10080, resetsAt: now.addingTimeInterval(Double((3 + index) * 86400))),
                fiveHour: try QuotaWindow(usedPercent: index == 0 ? 16 : 9, durationMinutes: 300, resetsAt: now.addingTimeInterval(Double((2 + index) * 3600))),
                fetchedAt: now, source: "Synthetic fixture")
        }
    }

    @MainActor private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, language: String,
                                            calendar: Calendar, to url: URL) throws {
        let root = NativeRenderEnvironmentCapture(content: view) { values in
            if !self.effectiveAccessibility.isEmpty { XCTAssertEqual(self.effectiveAccessibility, values) }
            self.effectiveAccessibility = values
        }.frame(width: size.width, height: size.height)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true }
        let renderer = ImageRenderer(content: root)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        let cgImage = try XCTUnwrap(renderer.cgImage, "ImageRenderer could not render this view without a window")
        XCTAssertEqual(cgImage.width, Int(size.width * 2))
        XCTAssertEqual(cgImage.height, Int(size.height * 2))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

/// These environment values are read-only in public SwiftUI. Record what the
/// isolated renderer actually observed instead of claiming to override them.
@MainActor struct NativeRenderEnvironmentCapture<Content: View>: View {
    let content: Content
    let record: ([String: String]) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let _ = record(["contrast": contrast == .increased ? "increased" : "standard",
                        "reduce_motion": String(reduceMotion), "reduce_transparency": String(reduceTransparency)])
        content
    }
}
