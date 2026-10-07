import XCTest
import WeekleftCore
@testable import Weekleft

/// P-I4: every limits card shows a weekly window as the menu bar does: the
/// value, dimming of saved data, the state sentence and the mark for data that
/// did not update (R2-P-05). Fixed clock and synthetic snapshots only.
final class WidgetLimitsDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Shown: Equatable {
        var value: String
        var dimmed: Bool
        var showsStatus: Bool
        var needsAttention: Bool
    }

    func testEveryLimitsCardShowsAWeeklyWindowLikeTheMenuBar() throws {
        func codex(used: Double? = nil, reset: TimeInterval? = 86400, fetched: TimeInterval? = 0, unlimited: Bool? = nil) throws -> UsageSnapshot {
            UsageSnapshot(provider: .codex,
                          weekly: try used.map { try QuotaWindow(usedPercent: $0, durationMinutes: 10080, resetsAt: reset.map { now.addingTimeInterval($0) }) },
                          fetchedAt: fetched.map { now.addingTimeInterval($0) }, source: "Codex CLI", unlimited: unlimited)
        }
        let cases: [(String, UsageSnapshot, Shown)] = [
            ("no limits", try codex(unlimited: true), Shown(value: "∞", dimmed: false, showsStatus: true, needsAttention: false)),
            ("current", try codex(used: 30), Shown(value: PercentText.format(70), dimmed: false, showsStatus: false, needsAttention: false)),
            ("saved", try codex(used: 30, fetched: -7200), Shown(value: PercentText.format(70), dimmed: true, showsStatus: true, needsAttention: true)),
            // 0 % cannot change before the reset: it keeps its countdown and is not marked.
            ("exhausted", try codex(used: 100, fetched: -7200), Shown(value: PercentText.format(0), dimmed: false, showsStatus: false, needsAttention: false)),
            ("reset passed", try codex(used: 40, reset: -60, fetched: -7200), Shown(value: "—", dimmed: false, showsStatus: true, needsAttention: true)),
            ("window not reported", try codex(), Shown(value: "—", dimmed: false, showsStatus: true, needsAttention: true)),
            ("never observed", try codex(fetched: nil), Shown(value: "—", dimmed: false, showsStatus: true, needsAttention: false)),
            // A window that has not started (0 %, no reset yet) is full and says when it starts (V: mutation M16).
            ("not started", try codex(used: 0, reset: nil), Shown(value: PercentText.format(100), dimmed: false, showsStatus: true, needsAttention: false)),
            ("not started, saved", try codex(used: 0, reset: nil, fetched: -7200), Shown(value: PercentText.format(100), dimmed: true, showsStatus: true, needsAttention: true)),
        ]
        let claude = UsageSnapshot(provider: .claude,
                                   weekly: try QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                                   fetchedAt: now, source: "Claude Code /usage")
        var both = WidgetPreferences(); both.enabledProviders = [.claude, .codex]
        var codexOnly = WidgetPreferences(); codexOnly.enabledProviders = [.codex]
        for (name, snapshot, expected) in cases {
            let menu = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: [snapshot], providers: [.codex],
                                                            preferences: MenuBarLimitsPreferences(), now: now).first)
            XCTAssertEqual(menu.value.replacingOccurrences(of: "*", with: ""), expected.value, "\(name): menu bar value")
            XCTAssertEqual(menu.stale, expected.dimmed, "\(name): menu bar marks saved data")
            let snapshots = [claude, snapshot]
            let medium = WeekleftCard(snapshots: snapshots, preferences: both, now: now)
            let small = SmallLimitsCard(snapshots: snapshots, preferences: both, now: now)
            let cards: [(String, WidgetQuotaDisplay, Bool?)] = [
                ("medium", medium.display(snapshot), medium.marksAttention),
                ("small", small.display(snapshot), small.marksAttention),
                ("single provider", SingleProviderLimitsCard(snapshot: snapshot, preferences: codexOnly, now: now).display, nil),
                ("overview", OverviewLimitsCard(snapshots: snapshots, preferences: both, now: now).display(snapshot), nil),
            ]
            for (card, display, headerMark) in cards {
                // The overview draws no attention mark of its own.
                let attention = card == "overview" ? expected.needsAttention : display.needsAttention
                XCTAssertEqual(Shown(value: display.value, dimmed: display.dimmed, showsStatus: display.showsStatus, needsAttention: attention),
                               expected, "\(name): \(card) card")
                if let headerMark { XCTAssertEqual(headerMark, expected.needsAttention, "\(name): \(card) header mark") }
            }
        }
    }
}

/// The medium widget of one provider: the week as a large figure, the other limits as tiles under its bar
/// (owner 07.10.2026: the small widget's rows stretched over the medium one looked weak).
final class SingleProviderTilesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func claude(week: Bool = true) throws -> UsageSnapshot {
        guard week else { return UsageSnapshot(provider: .claude) }
        return UsageSnapshot(provider: .claude,
            weekly: try QuotaWindow(usedPercent: 77, durationMinutes: 10080, resetsAt: now.addingTimeInterval(4 * 86400)),
            fiveHour: try QuotaWindow(usedPercent: 19, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)), fetchedAt: now, source: "fixture",
            modelQuotas: [ModelQuota(name: "Fable", window: try QuotaWindow(usedPercent: 35, durationMinutes: 10080, resetsAt: now.addingTimeInterval(4 * 86400)), fetchedAt: now)])
    }
    private func preferences(five: Bool = true, models: Bool = true, planInDays: Int? = nil) -> WidgetPreferences {
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude]
        preferences.showFiveHour = five; preferences.showModelLimits = models
        if let planInDays, let date = Calendar.current.date(byAdding: .day, value: planInDays, to: now) {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            preferences.subscriptionDates["claude"] = "\(parts.year!)-\(parts.month!)-\(parts.day!)"
        }
        return preferences
    }
    private func titles(_ snapshot: UsageSnapshot, _ preferences: WidgetPreferences) -> [String] {
        SingleProviderLimitsCard.tiles(snapshot, preferences: preferences, now: now).map(\.title)
    }

    func testTilesFollowTheSettingsAndTheResetFillsTheRoomLeft() throws {
        let snapshot = try claude()
        XCTAssertEqual(titles(snapshot, preferences(planInDays: 28)), [L("5 часов"), "Fable", L("Подписка")], "three tiles leave no room for the reset")
        XCTAssertEqual(titles(snapshot, preferences(models: false)), [L("Сброс"), L("5 часов")])
        XCTAssertEqual(titles(snapshot, preferences(five: false, models: false)), [L("Сброс")], "the tiles are never empty while the reset is known")
        let tiles = SingleProviderLimitsCard.tiles(snapshot, preferences: preferences(planInDays: 28), now: now)
        XCTAssertEqual(tiles[0].value, PercentText.format(81)); XCTAssertEqual(tiles[0].remaining, 81)
        XCTAssertEqual(tiles[1].value, PercentText.format(65)); XCTAssertEqual(tiles[1].remaining, 65)
        XCTAssertNil(tiles[2].remaining, "a date has no meter")
        XCTAssertEqual(tiles[2].help, PlanEndState.of(preferences(planInDays: 28), provider: .claude, now: now)?.full)
    }

    func testWithoutDataTheResetIsNotInventedAndAPlanNearItsEndIsColoured() throws {
        let waiting = SingleProviderLimitsCard.tiles(try claude(week: false), preferences: preferences(models: false), now: now)
        XCTAssertEqual(waiting.map(\.title), [L("5 часов")]); XCTAssertEqual(waiting.first?.value, "—"); XCTAssertNil(waiting.first?.remaining)
        let soon = SingleProviderLimitsCard.tiles(try claude(), preferences: preferences(planInDays: 3), now: now)
        XCTAssertNotNil(soon.last?.color, "a plan about to end stands out")
        XCTAssertNil(SingleProviderLimitsCard.tiles(try claude(), preferences: preferences(planInDays: 28), now: now).last?.color)
    }
}

/// 0.2.7: Claude's weekly model limit (Fable) in widgets, behind its own setting.
final class WidgetModelLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func claude(fableUsed: Double?, fetchedAgo: TimeInterval = 0) throws -> UsageSnapshot {
        let week = try QuotaWindow(usedPercent: 34, durationMinutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400))
        var snapshot = UsageSnapshot(provider: .claude, weekly: week, fetchedAt: now, source: "Claude Code /usage")
        snapshot.modelQuotas = try fableUsed.map { [ModelQuota(name: "Fable", window: try QuotaWindow(usedPercent: $0, durationMinutes: 10080,
            resetsAt: now.addingTimeInterval(5 * 86400)), fetchedAt: now.addingTimeInterval(-fetchedAgo))] }
        return snapshot
    }

    func testFableAppearsOnlyWhenTheSettingIsOn() throws {
        var preferences = WidgetPreferences()
        XCTAssertFalse(preferences.showModelLimits, "off by default")
        XCTAssertEqual(WidgetModelLimit.lines(try claude(fableUsed: 20), preferences: preferences, now: now), [])
        preferences.showModelLimits = true
        XCTAssertEqual(WidgetModelLimit.lines(try claude(fableUsed: 20), preferences: preferences, now: now), [.init(name: "Fable", value: "80%", remaining: 80)])
        XCTAssertEqual(WidgetModelLimit.lines(try claude(fableUsed: 20, fetchedAgo: QuotaFreshness.maximumAge + 1), preferences: preferences, now: now),
                       [.init(name: "Fable", value: "80%*", remaining: 80)], "a saved value keeps its meter")
        XCTAssertEqual(WidgetModelLimit.lines(try claude(fableUsed: nil), preferences: preferences, now: now), [])
        XCTAssertEqual(WidgetModelLimit.lines(UsageSnapshot(provider: .codex), preferences: preferences, now: now), [])
    }

    func testSettingIsKeptAndOlderPreferencesDecode() throws {
        let old = try JSONDecoder().decode(WidgetPreferences.self, from: Data(#"{"showFiveHour":true}"#.utf8))
        XCTAssertFalse(old.showModelLimits)
        var preferences = WidgetPreferences(); preferences.showModelLimits = true
        XCTAssertTrue(try JSONDecoder().decode(WidgetPreferences.self, from: JSONEncoder().encode(preferences)).showModelLimits)
        XCTAssertEqual(claudeModelLimitNames([try claude(fableUsed: 20)]), "Fable")
        XCTAssertNil(claudeModelLimitNames([try claude(fableUsed: nil)]))
    }

    func testCancelledInstallerAuthorizationIsNotAFailedCheck() {
        for code in [1001, 4007, 4008] {
            XCTAssertTrue(AppUpdates.endsQuietly(NSError(domain: "SUSparkleErrorDomain", code: code)), "\(code)")
        }
        XCTAssertFalse(AppUpdates.endsQuietly(NSError(domain: "SUSparkleErrorDomain", code: 4005)))
        XCTAssertFalse(AppUpdates.endsQuietly(NSError(domain: NSURLErrorDomain, code: 4007)))
    }
}
