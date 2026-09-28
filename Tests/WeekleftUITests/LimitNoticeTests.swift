import XCTest
import UserNotifications
@testable import Weekleft
@testable import WeekleftCore

final class LimitNoticeTests: XCTestCase {
    @MainActor func testLowAndRestoredLimitNotices() throws {
        let suite = "Lunavect.LimitNotice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = now.addingTimeInterval(2 * 3600)
        var requests: [UNNotificationRequest] = []
        func features() -> AppFeatures {
            let f = AppFeatures(defaults: defaults, now: { now }, playSound: { _ in },
                                sendBanner: { request, callback in requests.append(request); callback(nil) })
            f.banners = true; f.sounds = true; f.notificationAllowed = true
            return f
        }
        let first = features()
        XCTAssertTrue(first.limits)
        XCTAssertEqual(first.limitThreshold, 10)
        let low = [UsageSnapshot(provider: .claude, fiveHour: try QuotaWindow(usedPercent: 92, durationMinutes: 300, resetsAt: reset), fetchedAt: now, source: "test")]
        first.observeLimits(low)
        XCTAssertEqual(requests.map(\.content.title), [L("{0}: осталось {1}% на 5 часов", "Claude", "8")])
        XCTAssertEqual(requests.first?.content.body, L("Сброс: {0}", AppFeatures.resetText(reset, now: now)))
        XCTAssertNotNil(requests.first?.content.sound)
        first.observeLimits(low)
        XCTAssertEqual(requests.count, 1)
        first.stop()

        // A relaunch keeps the cycle: no repeated warning, but the return is announced.
        let second = features()
        second.observeLimits(low)
        XCTAssertEqual(requests.count, 1)
        now = reset.addingTimeInterval(5)
        second.observeLimits([])
        XCTAssertEqual(requests.last?.content.title, L("Лимит {0} снова доступен", "Claude"))
        XCTAssertEqual(requests.last?.content.body, L("Пятичасовое окно обновилось"))
        second.stop()

        let muted = features()
        muted.limits = false
        now = now.addingTimeInterval(60)
        muted.observeLimits([UsageSnapshot(provider: .codex, weekly: try QuotaWindow(usedPercent: 99, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)), fetchedAt: now, source: "test")])
        XCTAssertEqual(requests.count, 2)
        muted.limitThreshold = 20
        muted.limitThreshold = 15
        XCTAssertEqual(AppFeatures(defaults: defaults).limitThreshold, 20)
        XCTAssertEqual(AppFeatures(defaults: defaults).limits, false)
        muted.stop()
    }

    /// Q-05: `/usage` showed "Resets Sep 27 at 11:59pm" for a reset at 00:00:00 in
    /// Vienna (probe 812239140, status line 812239200). "Available again" must not be
    /// announced, and a limited session must not name a passed time, before 00:00:00.
    @MainActor func testLimitReturnWaitsForTheEndOfTheMinuteTheProbeShowed() throws {
        let suite = "Lunavect.LimitMinute." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shownMinute = Date(timeIntervalSinceReferenceDate: 812_239_140), reset = Date(timeIntervalSinceReferenceDate: 812_239_200)
        var now = shownMinute.addingTimeInterval(-600)
        var requests: [UNNotificationRequest] = []
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { _ in },
                                   sendBanner: { request, callback in requests.append(request); callback(nil) })
        features.banners = true; features.notificationAllowed = true
        defer { features.stop() }
        func probe(weekly: Int) throws -> UsageSnapshot {
            try ClaudeUsageText.parse("Current week (all models)\n\(weekly)% used\nResets Sep 27 at 11:59pm (Europe/Vienna)\nEsc to cancel",
                                      now: now, timeZone: XCTUnwrap(TimeZone(identifier: "Europe/Vienna")))
        }
        let exhausted = try probe(weekly: 100)
        features.observeLimits([exhausted])
        XCTAssertEqual(requests.map(\.content.title), [L("{0}: осталось {1}% на неделю", "Claude", "0")])
        now = shownMinute.addingTimeInterval(30)
        XCTAssertEqual(features.limitResetTime(for: .claude, now: now), reset, "A limited session names the certain reset")
        features.observeLimits([exhausted])
        XCTAssertEqual(requests.count, 1, "Inside the shown minute the limit has not certainly returned")
        now = reset
        features.observeLimits([exhausted])
        XCTAssertEqual(requests.last?.content.title, L("Лимит {0} снова доступен", "Claude"))
        XCTAssertEqual(requests.count, 2)
    }
}
