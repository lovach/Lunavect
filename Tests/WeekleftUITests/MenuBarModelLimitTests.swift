import XCTest
import WeekleftCore
@testable import Weekleft

/// A Claude model's weekly window (for example Fable) appears in the limits popover
/// only when it has less left than the weekly limit for all models, so the popover
/// shows the limit that runs out first without growing for every model.
final class MenuBarModelLimitTests: XCTestCase {
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
    private func claude(weekly: Double? = 27, fable: Double, fableFetchedAgo: TimeInterval = 60, fableReset: TimeInterval = 6 * 86400) throws -> UsageSnapshot {
        let week = now.addingTimeInterval(6 * 86400)
        return UsageSnapshot(provider: .claude,
            weekly: try weekly.map { try QuotaWindow(usedPercent: $0, durationMinutes: 10080, resetsAt: week) },
            fiveHour: try QuotaWindow(usedPercent: 2, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
            fetchedAt: now.addingTimeInterval(-60), source: "Claude Code /usage",
            modelQuotas: [ModelQuota(name: "Fable", window: try QuotaWindow(usedPercent: fable, durationMinutes: 10080, resetsAt: now.addingTimeInterval(fableReset)),
                                     fetchedAt: now.addingTimeInterval(-fableFetchedAgo))])
    }
    private func lines(_ snapshot: UsageSnapshot, period: MenuBarLimitsPeriod = .weekly) throws -> [MenuBarLimitEntry.ModelLine] {
        var preferences = MenuBarLimitsPreferences(enabled: true)
        preferences.period = period
        return try XCTUnwrap(MenuBarLimitEntry.make(snapshots: [snapshot], providers: [.claude], preferences: preferences, now: now).first).modelLines
    }

    func testAModelSpendingFasterThanTheWeekIsShownWithItsRemainingShare() throws {
        let shown = try lines(claude(fable: 85))
        XCTAssertEqual(shown.map(\.name), ["Fable"])
        XCTAssertEqual(shown.first?.value, PercentText.format(15))
        XCTAssertEqual(shown.first?.remaining, 15)
    }

    func testAModelSpendingSlowerOrEquallyIsNotShown() throws {
        XCTAssertTrue(try lines(claude(fable: 16)).isEmpty, "The owner's case of 28.09: 16 % against 27 %")
        XCTAssertTrue(try lines(claude(fable: 27)).isEmpty)
    }

    func testOnlyTheWeeklyPeriodShowsModelLimits() throws {
        XCTAssertTrue(try lines(claude(fable: 85), period: .fiveHour).isEmpty)
    }

    func testSavedModelDataKeepsItsMarkAndAPassedResetHidesIt() throws {
        let saved = try lines(claude(fable: 85, fableFetchedAgo: 2 * 3600))
        XCTAssertEqual(saved.first?.value, PercentText.format(15) + "*", "Saved data is marked like the value above it")
        XCTAssertTrue(try lines(claude(fable: 85, fableReset: -60)).isEmpty, "A reset that passed says nothing about the current window")
    }

    func testWithoutAKnownWeeklyLimitNoComparisonIsMade() throws {
        XCTAssertTrue(try lines(claude(weekly: nil, fable: 85)).isEmpty)
    }

    func testTheDescriptionNamesTheModelLimit() throws {
        let entry = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: [claude(fable: 85)], providers: [.claude],
                                                         preferences: MenuBarLimitsPreferences(enabled: true), now: now).first)
        XCTAssertTrue(entry.detail.contains(L("Неделя · {0}", "Fable")), entry.detail)
        XCTAssertTrue(entry.detail.contains(L("Тратится быстрее общего недельного лимита")), entry.detail)
    }
}
