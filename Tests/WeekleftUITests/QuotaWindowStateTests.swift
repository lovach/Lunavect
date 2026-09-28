import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

/// One window state and one text per state on every surface (01-quota.md §3,
/// owner decisions 3, 4, 5 and 8): menu bar, widgets and settings.
final class QuotaWindowStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var savedLanguage: Any?
    override func setUp() {
        super.setUp()
        savedLanguage = L10n.defaults.object(forKey: "languageCode")
        L10n.defaults.set("en", forKey: "languageCode")
    }
    override func tearDown() {
        L10n.defaults.set(savedLanguage, forKey: "languageCode")
        super.tearDown()
    }
    private func entry(_ snapshot: UsageSnapshot, at date: Date? = nil) throws -> MenuBarLimitEntry {
        try XCTUnwrap(MenuBarLimitEntry.make(snapshots: [snapshot], providers: [snapshot.provider],
                                             preferences: MenuBarLimitsPreferences(enabled: true), now: date ?? now).first)
    }
    private func probe(used: Double, reset: Date?, fetchedAgo: TimeInterval) throws -> UsageSnapshot {
        try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: used, durationMinutes: 10080, resetsAt: reset, resetPrecision: .minute),
                          fetchedAt: now.addingTimeInterval(-fetchedAgo), source: "Claude Code /usage")
    }

    // Decision 3: 0 % cannot change before the reset, so it is shown without "*" and with its countdown.
    func testExhaustedWindowShowsZeroWithoutStarAndKeepsTheCountdown() throws {
        let exhausted = try probe(used: 100, reset: now.addingTimeInterval(2 * 86400), fetchedAgo: 3 * 3600)
        let shown = try entry(exhausted)
        XCTAssertEqual(shown.value, "0%")
        XCTAssertFalse(shown.stale)
        XCTAssertEqual(shown.remaining, 0)
        XCTAssertNotNil(shown.resetDate)
        XCTAssertNotEqual(shown.countdown, "—")
        XCTAssertFalse(shown.detail.contains("last received"), shown.detail)
    }

    // Q-13, decision 4, matrix L1: after the reset without new data, a dash and one explanation everywhere.
    func testResetPassedShowsADashAndTheSameExplanationOnEverySurface() throws {
        let reset = now.addingTimeInterval(-600)
        let passed = try probe(used: 100, reset: reset, fetchedAgo: 3600)
        let shown = try entry(passed)
        XCTAssertEqual(shown.value, "—", "Neither the old 0% nor an invented 100%")
        XCTAssertNil(shown.remaining)
        let menuNote = try XCTUnwrap(shown.detail.components(separatedBy: "\n").first { $0.hasPrefix("Reset at ") }, shown.detail)
        XCTAssertTrue(menuNote.contains("waiting for the new window"), menuNote)
        XCTAssertFalse(shown.detail.contains("No data"))
        XCTAssertEqual(widgetQuotaStatus(passed, now: now), menuNote, "Widgets use the same sentence")
        XCTAssertEqual(passed.status(of: passed.weekly, now: now).note(now: now), menuNote, "Settings use the same sentence")
    }

    // Decision 5: an unstarted window is a known 100 % with no countdown.
    func testInactiveWindowSaysItStartsWithTheFirstRequest() throws {
        let inactive = try probe(used: 0, reset: nil, fetchedAgo: 60)
        let shown = try entry(inactive)
        XCTAssertEqual(shown.value, "100%")
        XCTAssertFalse(shown.stale)
        XCTAssertTrue(shown.detail.contains("Starts with the first request"), shown.detail)
        XCTAssertEqual(widgetQuotaStatus(inactive, now: now), "Starts with the first request")
    }

    // Decision 8: Codex without windows is "No limits", not missing data.
    func testUnlimitedCodexIsShownAsNoLimits() throws {
        let unlimited = UsageSnapshot(provider: .codex, fetchedAt: now.addingTimeInterval(-60), source: "Codex CLI", unlimited: true)
        let shown = try entry(unlimited)
        XCTAssertEqual(shown.value, "∞")
        XCTAssertTrue(shown.detail.contains("No limits"), shown.detail)
        XCTAssertEqual(widgetQuotaStatus(unlimited, now: now), "No limits")
    }

    // 01-quota.md §6 п.21: the widget re-renders after the reset grace instead of keeping the old value.
    func testWidgetTimelineHasAnEntryAfterEachResetGrace() throws {
        let reset = now.addingTimeInterval(5400)
        let claude = try probe(used: 100, reset: reset, fetchedAgo: 0)
        let codex = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 12, durationMinutes: 10080, resetsAt: reset),
                                      fetchedAt: now, source: "Codex CLI")
        let dates = WidgetTimelineSchedule.dates(from: now, snapshots: [claude, codex])
        XCTAssertTrue(dates.contains(reset))
        XCTAssertTrue(dates.contains(reset.addingTimeInterval(30)), "A probe reset is the end of the shown minute; its grace is 30 s")
        XCTAssertTrue(dates.contains(reset.addingTimeInterval(5)))
        let later = try entry(claude, at: reset.addingTimeInterval(30))
        XCTAssertEqual(later.value, "—")
        XCTAssertTrue(widgetQuotaStatus(claude, now: reset.addingTimeInterval(30)).hasPrefix("Reset at "))
    }

    // Q-17: model buckets from /usage keep their own freshness inside a statusLine snapshot.
    @MainActor func testLimitResetUsesFreshModelBucketsInsideAStatusLineSnapshot() throws {
        let suite = "Lunavect.ModelBucketReset." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reset = now.addingTimeInterval(3600)
        let features = AppFeatures(defaults: defaults, isolated: true)
        let bucket = ModelQuota(name: "Model", window: try QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: reset), fetchedAt: now.addingTimeInterval(-60))
        features.useSnapshots([UsageSnapshot(provider: .claude,
            weekly: try QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: now.addingTimeInterval(4 * 86400)),
            fetchedAt: now, source: "Claude Code statusLine", modelQuotas: [bucket])])
        XCTAssertEqual(features.limitResetTime(for: .claude, now: now), reset)
        let old = ModelQuota(name: "Model", window: bucket.window, fetchedAt: now.addingTimeInterval(-901))
        features.useSnapshots([UsageSnapshot(provider: .claude, fetchedAt: now, source: "Claude Code statusLine", modelQuotas: [old])])
        XCTAssertNil(features.limitResetTime(for: .claude, now: now), "An old bucket stays old")
    }

    /// Opt-in visual check of the window states on the popover, widgets and settings:
    /// LUNAVECT_RENDER_QUOTA_STATES=<directory> swift test --filter testRenderQuotaWindowStates
    @MainActor func testRenderQuotaWindowStates() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_QUOTA_STATES"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exhausted = try probe(used: 100, reset: now.addingTimeInterval(2 * 86400 + 3 * 3600), fetchedAgo: 3 * 3600)
        let passed = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(-600)),
                                       fetchedAt: now.addingTimeInterval(-7200), source: "Codex CLI")
        let inactive = try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil),
                                         fiveHour: QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil),
                                         fetchedAt: now.addingTimeInterval(-60), source: "Claude Code /usage")
        let unlimited = UsageSnapshot(provider: .codex, fetchedAt: now.addingTimeInterval(-60), source: "Codex CLI", unlimited: true)
        func render<V: View>(_ view: V, size: CGSize?, name: String) throws {
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
        for language in ["ru", "en", "de", "fr"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for (set, data) in [("exhausted-passed", [exhausted, passed]), ("inactive-unlimited", [inactive, unlimited])] {
                let model = MenuBarLimitsPanelModel()
                model.entries = MenuBarLimitEntry.make(snapshots: data, providers: ProviderID.allCases, preferences: .init(enabled: true), now: now)
                try render(MenuBarLimitsPopover(model: model, onPeriod: { _ in }, onRefresh: {}, onMenu: {}, onSettings: {})
                    .background(Color(nsColor: .windowBackgroundColor)), size: nil, name: "\(language)-\(set)-popover")
                var preferences = WidgetPreferences(); preferences.showFiveHour = true
                try render(WeekleftCard(snapshots: data, preferences: preferences, now: now).background(Color(white: 0.14)),
                           size: CGSize(width: 344, height: 172), name: "\(language)-\(set)-widget-medium")
                for snapshot in data {
                    var single = preferences; single.enabledProviders = [snapshot.provider]
                    try render(WeekleftCard(snapshots: data, preferences: single, now: now).background(Color(white: 0.14)),
                               size: CGSize(width: 344, height: 172), name: "\(language)-\(set)-single-\(snapshot.provider.rawValue)")
                    try render(SingleProviderLimitsCard(snapshot: snapshot, preferences: preferences, now: now, compact: true).background(Color(white: 0.14)),
                               size: CGSize(width: 164, height: 164), name: "\(language)-\(set)-small-\(snapshot.provider.rawValue)")
                    try render(LimitsProviderSummary(snapshot: snapshot, showFiveHour: true, now: now).frame(width: 520).padding(12)
                        .background(Color(nsColor: .windowBackgroundColor)), size: nil, name: "\(language)-\(set)-settings-\(snapshot.provider.rawValue)")
                }
                var both = WidgetPreferences(); both.enabledProviders = [.claude, .codex]
                let store = AppStore(state: SharedState(snapshots: data, preferences: both), savesChanges: false, isolated: true)
                try render(LimitsOverview(store: store, claudeNote: L("Статусная строка не работает в Claude Desktop; лимиты обновляются через /usage"), onConnections: {})
                    .frame(width: 560).padding(12).background(Color(nsColor: .windowBackgroundColor)), size: nil, name: "\(language)-\(set)-limits-page")
                let bar = MenuBarLimitsContent(frame: NSRect(x: 0, y: 0, width: 192, height: 24))
                bar.entries = model.entries; bar.showsResetCountdown = true
                bar.frame.size.width = bar.preferredWidth
                let board = NSView(frame: NSRect(x: 0, y: 0, width: bar.frame.width + 16, height: 32))
                board.appearance = NSAppearance(named: .darkAqua); board.wantsLayer = true
                board.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
                bar.frame.origin = NSPoint(x: 8, y: 4); board.addSubview(bar)
                let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = board; board.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
                board.cacheDisplay(in: board.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(language)-\(set)-menubar.png"))
                window.contentView = nil
            }
        }
    }
}
