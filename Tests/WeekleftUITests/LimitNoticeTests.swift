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
}
