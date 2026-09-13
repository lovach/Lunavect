import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class ActivityStatisticsSelectionTests: XCTestCase {
    @MainActor func testNativeSelectionScopePreservesEquivalentChartsAndResetsChangedCharts() throws {
        _ = NSApplication.shared
        let model = SelectionScopeModel(), probe = SelectionScopeProbe()
        let host = NSHostingView(rootView: SelectionScopeHarness(model: model, probe: probe))
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            }
        }
        let selected = Date(timeIntervalSince1970: 1_800_000_000)
        func pin() throws {
            try XCTUnwrap(probe.pin)(selected)
            settle()
            XCTAssertEqual(probe.chart, selected)
            XCTAssertEqual(probe.detail, selected)
        }
        func assertCleared() {
            settle()
            XCTAssertNil(probe.chart, "A changed chart must discard its local pin")
            XCTAssertNil(probe.detail, "The breakdown must follow the chart's selection")
        }
        settle(); try pin()
        model.providers = [.claude, .codex]
        settle()
        XCTAssertEqual(probe.chart, selected)
        XCTAssertEqual(probe.detail, selected, "Enabling Codex cannot clear details of the unchanged Claude chart")
        model.providers = [.claude]
        model.source = .all
        settle()
        XCTAssertEqual(probe.chart, selected)
        XCTAssertEqual(probe.detail, selected, "Equivalent source filters must keep selection consistent")

        model.providers = [.claude, .codex]
        assertCleared()
        try pin(); model.period = .month
        assertCleared()
        try pin(); model.providers = []
        settle()
        XCTAssertNil(probe.detail, "Removing every source must clear a stale breakdown even while the chart is absent")
        model.providers = [.codex]
        assertCleared()
    }

    func testEverySourceResolvesWithZeroOneOrTwoProviders() {
        for enabled: [ProviderID] in [[], [.claude], [.codex], [.claude, .codex]] {
            for source in [ActivitySource.all, .claude, .codex, .comparison] {
                let resolved = ActivityStatisticsView.resolvedSource(source, enabledProviders: enabled)
                let shown = resolved.providers(from: enabled)
                XCTAssertEqual(resolved, resolved.canonical)
                XCTAssertTrue(Set(shown).isSubset(of: Set(enabled)))
                XCTAssertEqual(shown.isEmpty, enabled.isEmpty, "A connected source must remain reachable: \(source), \(enabled)")
                if source.canonical == .all {
                    XCTAssertEqual(resolved, .all, "The combined default must keep following enabled providers")
                } else if let provider = source.provider, enabled.contains(provider) {
                    XCTAssertEqual(resolved, source, "An available explicit choice must be preserved")
                }
            }
        }
    }

    func testDisconnectedWidgetSourceShowsRemainingHistoryWithoutInventingData() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var history = ActivityHistory()
        history.append(start: now.addingTimeInterval(-180), end: now.addingTimeInterval(-120), providers: 1)
        history.append(start: now.addingTimeInterval(-120), end: now.addingTimeInterval(-60), providers: 3)
        history.append(start: now.addingTimeInterval(-60), end: now, providers: 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(history)
        for disabled in ProviderID.allCases {
            let remaining = ProviderID.allCases.filter { $0 != disabled }
            let requested = try XCTUnwrap(ActivitySource(rawValue: disabled.rawValue))
            for period in ActivityPeriod.allCases {
                let route = requested.widgetURL(period: period)
                let source = try XCTUnwrap(ActivitySource.from(widgetURL: route))
                let resolved = ActivityStatisticsView.resolvedSource(source, enabledProviders: remaining)
                let chart = ActivityChartData(history: history, now: now, period: period, providers: resolved.providers(from: remaining))
                XCTAssertEqual(chart.series.map(\.provider), remaining)
                XCTAssertEqual(chart.summary.totals.active, 120)
                XCTAssertTrue(chart.points.contains { $0.totals.observed == 0 }, "Unobserved periods stay unknown")
            }
        }
        XCTAssertEqual(try encoder.encode(history), original, "Resolving a disabled filter must not remove history")
    }

    @MainActor func testHostedStatisticsReconcilesOnOpenProviderChangeAndWidgetRoute() throws {
        _ = NSApplication.shared
        let suite = "Lunavect.StatisticsSelection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ActivitySource.codex.rawValue, forKey: "statisticsSource")
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude]
        let store = AppStore(state: SharedState(snapshots: [], preferences: preferences), savesChanges: false,
                             activityHistory: ActivityHistory(), activityDetails: ActivityDetails(), isolated: true, defaults: defaults)
        let host = NSHostingView(rootView: ActivityStatisticsView(store: store).defaultAppStorage(defaults))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        settle()
        XCTAssertEqual(defaults.string(forKey: "statisticsSource"), "claude", "Opening with an old disconnected filter must persist recovery")

        store.preferences.enabledProviders = [.codex]
        settle()
        XCTAssertEqual(defaults.string(forKey: "statisticsSource"), "codex", "The reverse disconnection must recover while the view stays open")

        let route = ActivitySource.claude.widgetURL(period: .month)
        defaults.set(try XCTUnwrap(ActivitySource.from(widgetURL: route)).rawValue, forKey: "statisticsSource")
        settle()
        XCTAssertEqual(defaults.string(forKey: "statisticsSource"), "codex", "An incoming widget route cannot strand an already open view")

        store.preferences.enabledProviders = []
        settle()
        XCTAssertEqual(defaults.string(forKey: "statisticsSource"), "all")
        store.preferences.enabledProviders = [.claude, .codex]
        settle()
        XCTAssertEqual(defaults.string(forKey: "statisticsSource"), "all", "Reconnecting must preserve the combined choice")

        // A fresh hosted view reads the reconciled persistent selection, as after reopening the app.
        window.contentView = nil
        defaults.set("codex", forKey: "statisticsSource")
        store.preferences.enabledProviders = [.claude]
        let reopened = NSHostingView(rootView: ActivityStatisticsView(store: store).defaultAppStorage(defaults))
        reopened.frame = host.frame; window.contentView = reopened
        reopened.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(defaults.string(forKey: "statisticsSource"), "claude")
        XCTAssertTrue(store.activityHistory.intervals.isEmpty, "Recovery must not create activity")
    }
}

@MainActor private final class SelectionScopeModel: ObservableObject {
    @Published var providers: [ProviderID] = [.claude]
    @Published var source = ActivitySource.claude
    @Published var period = ActivityPeriod.week
}

@MainActor private final class SelectionScopeProbe {
    var pin: ((Date?) -> Void)?
    var chart: Date?
    var detail: Date?
}

private struct SelectionScopeHarness: View {
    @ObservedObject var model: SelectionScopeModel
    let probe: SelectionScopeProbe
    @State private var detailDate: Date?
    var body: some View {
        let providers = ActivityStatisticsView.resolvedSource(model.source, enabledProviders: model.providers).providers(from: model.providers)
        let scope = ActivityChartSelectionScope(period: model.period, providers: providers, selection: $detailDate)
        VStack {
            if !providers.isEmpty {
                SelectionScopeChart(probe: probe, onSelection: { detailDate = $0 }).id(scope.id)
            }
            Color.clear.background(SelectionScopeCapture { probe.detail = detailDate })
        }.modifier(scope)
    }
}

/// Native state stands in for the chart's pin; the production modifier controls
/// its identity and the separate breakdown binding under real SwiftUI updates.
private struct SelectionScopeChart: View {
    let probe: SelectionScopeProbe
    var onSelection: (Date?) -> Void
    @State private var pinnedDate: Date?
    var body: some View {
        let binding = $pinnedDate
        Color.clear.background(SelectionScopeCapture {
            probe.chart = pinnedDate
            probe.pin = { binding.wrappedValue = $0 }
        }).onChange(of: pinnedDate) { _, date in onSelection(date) }
    }
}

private struct SelectionScopeCapture: NSViewRepresentable {
    var capture: () -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { capture() }
}
