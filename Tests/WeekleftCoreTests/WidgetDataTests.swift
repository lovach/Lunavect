import Darwin
import XCTest
@testable import WeekleftCore

/// Widget-facing data: the timeline schedule, bounded shared readers, the
/// activity entry state, App Group resolution and the private background switch.
final class WidgetDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetDataTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func snapshot(fetched: Date?, reset: Date?) throws -> UsageSnapshot {
        UsageSnapshot(provider: .codex, weekly: try QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: reset), fetchedAt: fetched, source: "fixture")
    }

    // MARK: WidgetTimelineSchedule.dates (audit 04 §4 item 1, matrix W1/W2)

    func testTimelineIncludesUpcomingResetStalenessAndMidnightWithinOneDay() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let reset = now.addingTimeInterval(1800), fetched = now.addingTimeInterval(-60)
        let dates = WidgetTimelineSchedule.dates(from: now, snapshots: [try snapshot(fetched: fetched, reset: reset)], calendar: calendar)
        XCTAssertEqual(dates.first, now, "The first entry is the current state")
        XCTAssertEqual(dates, dates.sorted()); XCTAssertEqual(Set(dates).count, dates.count)
        XCTAssertTrue(dates.contains(reset), "An entry at the reset stops showing the old quota")
        XCTAssertTrue(dates.contains(fetched.addingTimeInterval(901)), "An entry marks the observation stale")
        XCTAssertTrue(dates.contains(calendar.startOfDay(for: now.addingTimeInterval(86400))))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(900)))
        XCTAssertTrue(dates.allSatisfy { $0 >= now && $0 <= now.addingTimeInterval(86400) })
    }

    func testTimelineDropsPastAndDistantEventsButIsNeverEmpty() throws {
        let past = try snapshot(fetched: now.addingTimeInterval(-3 * 86400), reset: now.addingTimeInterval(-60))
        let distant = try snapshot(fetched: nil, reset: now.addingTimeInterval(25 * 3600))
        let dates = WidgetTimelineSchedule.dates(from: now, snapshots: [past, distant])
        XCTAssertFalse(dates.contains(now.addingTimeInterval(-60)))
        XCTAssertFalse(dates.contains(now.addingTimeInterval(25 * 3600)))
        XCTAssertFalse(dates.isEmpty)
        XCTAssertFalse(WidgetTimelineSchedule.dates(from: now, snapshots: []).isEmpty)
    }

    func testTimelineMidnightFollowsDaylightSavingDaysInVienna() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        let formatter = ISO8601DateFormatter()
        // 23:30 CET before the 23-hour day, and 23:30 CEST before the 25-hour day.
        for (start, midnight) in [("2026-03-28T22:30:00Z", "2026-03-28T23:00:00Z"), ("2026-10-24T21:30:00Z", "2026-10-24T22:00:00Z"),
                                  ("2026-03-29T12:00:00Z", "2026-03-29T22:00:00Z"), ("2026-10-25T12:00:00Z", "2026-10-25T23:00:00Z")] {
            let date = try XCTUnwrap(formatter.date(from: start)), expected = try XCTUnwrap(formatter.date(from: midnight))
            XCTAssertTrue(WidgetTimelineSchedule.dates(from: date, snapshots: [], calendar: calendar).contains(expected), start)
        }
    }

    func testResetEntryNoLongerTreatsTheOldQuotaAsCurrent() throws {
        let reset = now.addingTimeInterval(1800)
        let value = try snapshot(fetched: now, reset: reset)
        XCTAssertFalse(value.weekly!.isExpired(at: reset.addingTimeInterval(-1)))
        XCTAssertTrue(value.weekly!.isExpired(at: reset))
        XCTAssertTrue(value.weekly!.isExpired(at: reset.addingTimeInterval(1)))
        XCTAssertTrue(value.isStale(window: value.weekly, now: reset))
        // Three days without the app: every later entry is stale and nothing new is invented.
        let old = try snapshot(fetched: now.addingTimeInterval(-3 * 86400), reset: now.addingTimeInterval(86400))
        XCTAssertTrue(old.isStale(now: now))
        XCTAssertTrue(WidgetTimelineSchedule.dates(from: now, snapshots: [old]).allSatisfy { old.isStale(now: $0) })
    }

    // MARK: B-05 bounded shared readers

    func testWidgetSelectionReaderIsBounded() throws {
        let root = try directory()
        try ActivityWidgetSelection.write(now, kind: "LunavectActivityWidget", period: .week, source: .all, directory: root)
        XCTAssertEqual(ActivityWidgetSelection.read(kind: "LunavectActivityWidget", period: .week, source: .all, directory: root), now)
        let file = root.appendingPathComponent("ActivitySelection/LunavectActivityWidget-week-all.json")
        // A valid number padded far beyond any real selection file.
        try (Data("\(now.timeIntervalSinceReferenceDate)".utf8) + Data(repeating: 0x20, count: 100_000)).write(to: file)
        XCTAssertNil(ActivityWidgetSelection.read(kind: "LunavectActivityWidget", period: .week, source: .all, directory: root))
    }

    /// Foundation already refused this FIFO before B-05; the test guards the
    /// bounded reader that replaced the stat-then-read sequence.
    func testLegacyStateReaderDoesNotBlockOnASpecialFile() throws {
        let root = try directory(), stamp = now.timeIntervalSince1970
        let row: [String: Any] = ["sessionId": UUID().uuidString, "started": true, "ts": stamp, "pid": Int(getpid()),
                                  "transcript": "/tmp/.claude/projects/fixture.jsonl", "state": "thinking", "cwd": "/tmp/fixture"]
        try JSONSerialization.data(withJSONObject: row).write(to: root.appendingPathComponent("normal.json"))
        let fifo = root.appendingPathComponent("waiting.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let finished = DispatchSemaphore(value: 0), rows = LockedRows()
        DispatchQueue.global().async {
            rows.value = SessionSources.legacyEvents(catalog: [], now: self.now, directory: root)
            finished.signal()
        }
        let completed = finished.wait(timeout: .now() + 3) == .success
        if !completed {
            // Release a reader stuck on the FIFO so the process can continue.
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK); if writer >= 0 { close(writer) }
            _ = finished.wait(timeout: .now() + 3)
        }
        XCTAssertTrue(completed, "A FIFO in the legacy state directory must not block session discovery")
        XCTAssertEqual(rows.value?.count, 1)
    }

    // MARK: Matrix A7: an unreadable history in the widget

    func testWidgetEntryMarksAnUnreadableHistoryUnavailableInsteadOfEmpty() throws {
        let root = try directory(), url = root.appendingPathComponent("activity.json")
        XCTAssertFalse(WidgetActivitySnapshot.load(from: url).unavailable, "No file yet is an empty history")
        var history = ActivityHistory(); history.append(start: now, end: now.addingTimeInterval(60), providers: 1)
        try history.save(to: url)
        let valid = WidgetActivitySnapshot.load(from: url)
        XCTAssertFalse(valid.unavailable); XCTAssertEqual(valid.history, history)
        try Data("{broken".utf8).write(to: url)
        XCTAssertTrue(WidgetActivitySnapshot.load(from: url).unavailable)
        XCTAssertEqual(try Data(contentsOf: url), Data("{broken".utf8), "The widget never repairs shared files")
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 32_000_001); try handle.close()
        let oversized = WidgetActivitySnapshot.load(from: url)
        XCTAssertTrue(oversized.unavailable)
        XCTAssertFalse(ActivityChartData(history: oversized.history, now: now).hasData)
    }

    // MARK: Audit 04 §4 item 10: App Group resolution

    func testSharedDirectoryUsesTheGroupContainerAndReportsAFallback() {
        let support = URL(fileURLWithPath: "/fixture/Application Support")
        let group = URL(fileURLWithPath: "/fixture/Group Containers/TEAM.com.lunavect.shared")
        let resolved = SnapshotStore.resolveDirectory(group: "TEAM.com.lunavect.shared", container: { $0 == "TEAM.com.lunavect.shared" ? group : nil },
                                                      applicationSupport: support)
        XCTAssertEqual(resolved.url, group.appendingPathComponent("Weekleft", isDirectory: true)); XCTAssertFalse(resolved.fellBack)
        let missing = SnapshotStore.resolveDirectory(group: "TEAM.com.lunavect.shared", container: { _ in nil }, applicationSupport: support)
        XCTAssertEqual(missing.url, support.appendingPathComponent("Weekleft", isDirectory: true))
        XCTAssertTrue(missing.fellBack, "A configured group without a container means app and widget may read different files")
        let none = SnapshotStore.resolveDirectory(group: nil, container: { _ in XCTFail("No group"); return nil }, applicationSupport: support)
        XCTAssertEqual(none.url, support.appendingPathComponent("Weekleft", isDirectory: true)); XCTAssertFalse(none.fellBack)
    }

    // MARK: C-03 private background switch

    func testHiddenDefaultDisablesThePrivateWidgetBackground() {
        var preferences = WidgetPreferences()
        XCTAssertFalse(WidgetBackgroundPolicy.usesPrivateBackground(preferences, disabled: false))
        preferences.transparentBackground = true
        XCTAssertTrue(WidgetBackgroundPolicy.usesPrivateBackground(preferences, disabled: false))
        XCTAssertFalse(WidgetBackgroundPolicy.usesPrivateBackground(preferences, disabled: true))
        XCTAssertEqual(WidgetBackgroundPolicy.disableKey, "disablePrivateWidgetBackground")
    }

    // MARK: Matrix A5: archived and compressed Codex logs

    func testArchivedCopiesAreNotCountedTwiceAndCompressedLogsAreSkippedQuietly() throws {
        let home = try directory(), sessions = home.appendingPathComponent("sessions/2026/09/20"), archived = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let end = now.timeIntervalSince1970
        let record: [String: Any] = ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t", "started_at": end - 600, "completed_at": end - 300, "duration_ms": 300_000]]
        let data = try JSONSerialization.data(withJSONObject: record) + Data([10])
        for url in [sessions.appendingPathComponent("rollout-a.jsonl"), archived.appendingPathComponent("rollout-a.jsonl")] {
            try data.write(to: url); try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
        for name in ["rollout-b.jsonl.gz", "rollout-c.jsonl.zst"] {
            let url = archived.appendingPathComponent(name)
            try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: url); try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
        let result = ActivityHistoryImporter.read(sources: [.init(directory: home.appendingPathComponent("sessions"), provider: .codex),
                                                            .init(directory: archived, provider: .codex)], before: now, now: now)
        XCTAssertEqual(result.intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 300)
        XCTAssertEqual(result.report.providers.first?.filesRead, 2)
        XCTAssertEqual(result.report.providers.first?.issues ?? [:], [:])
        XCTAssertFalse(result.limited)
    }
}

private final class LockedRows: @unchecked Sendable {
    private let lock = NSLock(); private var rows: [AgentSession]?
    var value: [AgentSession]? { get { lock.withLock { rows } } set { lock.withLock { rows = newValue } } }
}
