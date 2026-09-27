import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// C-01: quota receipts reload only widgets that show quotas. C-02: the
/// installed host does not reassert its registration while other copies of
/// the same bundle are registered.
final class WidgetReloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetReloadTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("snapshot.json")
    }

    func testQuotaReceiptsDoNotReloadTheActivityWidget() throws {
        let clock = ReloadClock(now), quota = ReloadCount(), activity = ReloadCount()
        let persistence = SnapshotPersistence(url: try url(), reload: { quota.increment() }, reloadActivity: { activity.increment() },
                                              clock: { clock.now })
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        var state = SharedState(snapshots: [UsageSnapshot(provider: .codex, weekly: try QuotaWindow(usedPercent: 40, durationMinutes: 10080,
            resetsAt: now.addingTimeInterval(86400)), fetchedAt: now)], preferences: preferences)
        _ = persistence.flush(state)
        XCTAssertEqual([quota.value, activity.value], [1, 1], "First delivery reaches every widget")
        // A new percentage and a receipt every minute for an hour.
        for minute in 1...60 {
            clock.now = now.addingTimeInterval(Double(minute) * 60)
            state.snapshots[0].fetchedAt = clock.now
            if minute == 30 { state.snapshots[0].weekly = try QuotaWindow(usedPercent: 41, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)) }
            _ = persistence.flush(state)
        }
        XCTAssertGreaterThan(quota.value, 10, "Limits and overview widgets keep their receipt cadence")
        XCTAssertEqual(activity.value, 1, "Activity widgets do not reread history for a quota receipt")
        // Appearance and source selection are shown by every widget.
        state.preferences.transparency = 0.8; _ = persistence.flush(state)
        state.preferences.enabledProviders = [.codex, .claude]; _ = persistence.flush(state)
        XCTAssertEqual(activity.value, 3)
        // Subscription dates are not shown by activity widgets.
        state.preferences.subscriptionDates = ["codex": "2026-09-01"]; _ = persistence.flush(state)
        XCTAssertEqual(activity.value, 3)
    }

    @MainActor func testDuplicateRegisteredCopiesSuppressReassertion() async {
        let defaults = UserDefaults(suiteName: "WidgetReloadTests." + UUID().uuidString)!
        let target = WidgetRegistrationTarget(app: URL(fileURLWithPath: "/Applications/Lunavect.app"), version: "200")
        // Registration domain only: nothing is persisted for this fixture.
        defaults.register(defaults: [WidgetRegistration.stampKey: target.stamp])
        let checks = ReloadCount(), reloads = ReloadCount()
        let duplicate = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in XCTFail("Current build"); return false },
            reassert: { _ in checks.increment(); return true }, reload: { reloads.increment() }, pause: {}, settle: { _ in },
            registeredCopies: { [URL(fileURLWithPath: "/Applications/Lunavect.app"), URL(fileURLWithPath: "/Users/fixture/Applications/Lunavect.app")] })
        duplicate.start(); await duplicate.waitUntilFinished()
        XCTAssertEqual(checks.value, 0, "Another registered copy makes a reassertion a trigger, not a repair")
        XCTAssertEqual(reloads.value, 0)
        var delays: [Duration] = []
        let single = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in XCTFail("Current build"); return false },
            reassert: { _ in checks.increment(); return true }, reload: { reloads.increment() }, pause: {}, settle: { delays.append($0) },
            registeredCopies: { [URL(fileURLWithPath: "/Applications/./Lunavect.app")] })
        single.start(); await single.waitUntilFinished()
        XCTAssertEqual(delays, [.seconds(5), .seconds(115)], "Checks at 5 s and 2 min after launch")
        XCTAssertEqual(checks.value, 2)
        XCTAssertEqual(reloads.value, 2)
    }
}

private final class ReloadClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { get { lock.withLock { date } } set { lock.withLock { date = newValue } } }
}
private final class ReloadCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
