import XCTest
import WeekleftCore
@testable import Weekleft

/// The service keeps the daily archive: live waiting, the one-time log back-fill and its file.
@MainActor final class ActivityArchiveServiceTests: XCTestCase {
    func testWaitingIsCountedPerSessionAndArchiveIsWrittenAndBackfilledOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ActivityPersistence(historyURL: root.appendingPathComponent("history.json"), detailsURL: root.appendingPathComponent("details.json"),
                                          writeHistory: { _, _ in }, writeDetails: { _, _, _ in })
        var date = Date()
        // 10:00 sixty days ago: an hour that does not cross midnight whenever the test runs.
        let old = Calendar.current.date(byAdding: .hour, value: 10, to: Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -60, to: date)!))!
        let backfills = BackfillCounter()
        let service = ActivityService(history: .init(), details: .init(), storage: storage, powerNotifications: nil, clock: { date },
                                      importer: { _, _, _ in .init() }, archive: .init(), archiveURL: root.appendingPathComponent("archive.json"),
                                      backfill: { _, _ in
                                          backfills.add()
                                          var result = ActivityImportResult()
                                          result.intervals = [ActivityInterval(start: old, end: old.addingTimeInterval(3600), providers: 1)]
                                          return result
                                      })
        service.start(providers: [.claude])
        for _ in 0..<200 where service.archive.backfillVersion == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.archive.backfillVersion, ActivityArchive.currentBackfillVersion)
        XCTAssertEqual(service.archive.days[ActivityArchive.key(old, calendar: .current)]?.parts["all"]?.recovered, 3600)
        let waiting = AgentSession(provider: .claude, sessionID: "question", title: "Ask", cwd: "/fixture", phase: .input,
                                   updatedAt: date, observedAt: date, runtimeConfirmed: true)
        for step in 0..<3 {
            var row = waiting; row.observedAt = date; row.updatedAt = date
            service.observe([row], now: date)
            if step < 2 { date = date.addingTimeInterval(5) }
        }
        date = date.addingTimeInterval(5)
        service.observe([], now: date)
        service.flush(now: date)
        let today = try XCTUnwrap(service.archive.days[ActivityArchive.key(date, calendar: .current)])
        XCTAssertEqual(today.parts["claude"]?.waitingInput, 10)
        XCTAssertEqual(today.parts["all"]?.waits, [10])
        let saved = try ActivityArchive.load(from: root.appendingPathComponent("archive.json"))
        XCTAssertEqual(saved.days.count, service.archive.days.count)
        service.stop()
        XCTAssertEqual(backfills.value, 1)
    }
}

private final class BackfillCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
