import XCTest
import UserNotifications
import Carbon
@testable import Weekleft
@testable import WeekleftCore

final class FailureNoticeTests: XCTestCase {
    @MainActor func testLimitFailureNoticeNamesTheKindAndWhenItReturns() throws {
        let suite = "Lunavect.FailureNotice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        var now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 10, minute: 0)))
        let reset = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12, minute: 20)))
        var played: [SessionNoticeKind] = []
        var requests: [UNNotificationRequest] = []
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { played.append($0) },
                                   sendBanner: { request, callback in requests.append(request); callback(nil) })
        features.banners = true; features.sounds = true; features.notificationAllowed = true
        XCTAssertTrue(features.failure)
        features.useSnapshots([UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
                                             fiveHour: try QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: reset), fetchedAt: now, source: "test")])
        XCTAssertEqual(features.limitResetTime(for: .claude, now: now), reset)
        // Available again only when every exhausted window has reset; stale data is not used.
        let weeklyReset = now.addingTimeInterval(3 * 86400)
        features.useSnapshots([UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: weeklyReset),
                                             fiveHour: try QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: reset), fetchedAt: now, source: "test")])
        XCTAssertEqual(features.limitResetTime(for: .claude, now: now), weeklyReset)
        features.useSnapshots([UsageSnapshot(provider: .claude, fiveHour: try QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: reset),
                                             fetchedAt: now.addingTimeInterval(-1800), source: "test")])
        XCTAssertNil(features.limitResetTime(for: .claude, now: now))
        features.useSnapshots([UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: weeklyReset),
                                             fiveHour: try QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: reset), fetchedAt: now, source: "test")])
        var row = AgentSession(provider: .claude, sessionID: "limit", title: "Render the tour", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        features.observe([row])
        now += 1
        row.phase = .failed; row.failure = .limit; row.observedAt = now
        features.observe([row])
        let banner = try XCTUnwrap(requests.last)
        XCTAssertEqual(banner.content.title, L("Лимит исчерпан"))
        XCTAssertEqual(banner.content.body, "Claude · Render the tour · " + L("снова доступен в {0}", AppFeatures.resetText(reset, now: now)))
        XCTAssertNotNil(banner.content.sound)
        XCTAssertTrue(played.isEmpty, "a delivered banner carries its own sound")

        features.failure = false
        now += 1; row.phase = .running; row.failure = nil; row.observedAt = now; features.observe([row])
        now += 1; row.phase = .failed; row.failure = .network; row.observedAt = now; features.observe([row])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(AppFeatures(defaults: defaults).failure, false)
    }
    @MainActor func testASessionsNewerNoticeReplacesItsBannerWhileOtherNoticesStaySeparate() throws {
        let suite = "Lunavect.NoticeIdentity." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var requests: [UNNotificationRequest] = []
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { _ in },
                                   sendBanner: { request, callback in requests.append(request); callback(nil) })
        features.banners = true; features.notificationAllowed = true
        var first = AgentSession(provider: .claude, sessionID: "first", title: "Render the tour", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        var second = AgentSession(provider: .codex, sessionID: "second", title: "Update the README", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        features.observe([first, second])
        now += 1; first.phase = .permission; first.observedAt = now
        features.observe([first, second])
        now += 1; first.phase = .ready; first.observedAt = now; second.phase = .ready; second.observedAt = now
        features.observe([first, second])
        func notices(_ row: AgentSession) -> [UNNotificationRequest] {
            requests.filter { $0.content.userInfo["sessionID"] as? String == row.id }
        }
        XCTAssertEqual(notices(first).map(\.content.title), [L("Нужно разрешение"), L("Ответ готов")])
        XCTAssertEqual(Set(notices(first).map(\.identifier)).count, 1, "Approval granted: the completion replaces the approval banner")
        XCTAssertEqual(notices(first).map(\.content.threadIdentifier), [first.id, first.id])
        XCTAssertEqual(notices(second).count, 1)
        XCTAssertNotEqual(notices(second).first?.identifier, notices(first).first?.identifier)
        let sessionIdentifiers = Set(requests.map(\.identifier))
        features.testNotification(); features.testNotification()
        let tests = requests.suffix(2).map(\.identifier)
        XCTAssertEqual(Set(tests).count, 2, "Test notifications never replace each other")
        XCTAssertTrue(sessionIdentifiers.isDisjoint(with: tests))
    }
}

final class PanelShortcutTests: XCTestCase {
    func testStandardCommandsCannotBecomeTheGlobalShortcut() {
        let command = UInt32(cmdKey), shift = UInt32(shiftKey), control = UInt32(controlKey), option = UInt32(optionKey)
        for key: UInt32 in [8, 9, 13, 12, 6, 49] { XCTAssertTrue(PanelShortcut.isReserved(keyCode: key, modifiers: command), "⌘\(key)") }
        XCTAssertTrue(PanelShortcut.isReserved(keyCode: 6, modifiers: command | shift), "⌘⇧Z redo")
        XCTAssertTrue(PanelShortcut.isReserved(keyCode: 49, modifiers: control), "⌃Space input source")
        XCTAssertFalse(PanelShortcut.isReserved(keyCode: 37, modifiers: command | option), "⌥⌘L is free")
        XCTAssertFalse(PanelShortcut.isReserved(keyCode: 8, modifiers: control | option), "⌃⌥C is free")
        XCTAssertFalse(PanelShortcut.isReserved(keyCode: 46, modifiers: command | shift | option), "⌥⇧⌘M is free")
    }
}
