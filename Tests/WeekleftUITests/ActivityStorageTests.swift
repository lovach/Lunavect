import AppKit
import Darwin
import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// Storage lifetime of live activity: write cadence, sleep, recovery from an
/// unreadable history, abandoned temporaries, bounded termination and retries.
/// Synthetic rows, temporary directories and injected clocks only.
final class ActivityStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityStorageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func row(_ id: String, provider: ProviderID = .claude, _ phase: SessionPhase, at date: Date) -> AgentSession {
        AgentSession(provider: provider, sessionID: id, title: "Synthetic " + id, cwd: "/tmp/fixture-" + id, phase: phase,
                     updatedAt: date, observedAt: date, evidence: .localEvent, runtimeConfirmed: true)
    }

    // MARK: B-02 write frequency (audit 04 §0 methodology, in process)

    /// One synthetic working hour, observed every 2 s like the active poll:
    /// two Claude sessions run throughout (as in the measured 240 s window), a
    /// finished Codex row and a ready/idle Claude row change phase every 30 s,
    /// and every ten minutes a third session flips running/input every 3 s for
    /// a minute (20 transitions). A write is a new inode of the file (temporary
    /// plus rename), sampled after each observation once the queue drained.
    @MainActor func testSyntheticWorkingHourWriteFrequency() throws {
        let directory = try root(), clock = StorageClock(now)
        let historyURL = directory.appendingPathComponent("activity.json"), detailsURL = directory.appendingPathComponent("activity-details.json")
        let storage = ActivityPersistence(historyURL: historyURL, detailsURL: detailsURL, clock: { clock.now })
        let service = ActivityService(history: .init(), details: .init(), storage: storage, powerNotifications: nil, clock: { clock.now })
        service.setProviders([.claude, .codex])
        var inodes: [URL: ino_t] = [:], writes: [URL: Int] = [:], bytes: [URL: Int] = [:], burstWrites = 0
        var windows: [Int: Int] = [:]
        func sample(second: Int, inBurst: Bool) {
            _ = storage.counters // waits for queued writes
            for url in [historyURL, detailsURL] {
                var info = stat()
                guard lstat(url.path, &info) == 0, inodes[url] != info.st_ino else { continue }
                inodes[url] = info.st_ino; writes[url, default: 0] += 1; bytes[url, default: 0] += Int(info.st_size)
                if url == historyURL { windows[second / 240, default: 0] += 1; if inBurst { burstWrites += 1 } }
            }
        }
        for second in stride(from: 0, to: 3600, by: 2) {
            clock.now = now.addingTimeInterval(Double(second))
            let minute = second / 60, inBurst = minute % 10 == 5
            var rows = [row("a", .running, at: clock.now), row("b", .running, at: clock.now),
                        row("done", provider: .codex, .finished, at: clock.now),
                        row("parked", (second / 30).isMultiple(of: 2) ? .ready : .idle, at: clock.now)]
            if inBurst { rows.append(row("burst", (second / 3).isMultiple(of: 2) ? .running : .input, at: clock.now)) }
            service.observe(rows)
            sample(second: second, inBurst: inBurst)
        }
        service.stop()
        sample(second: 3599, inBurst: false)
        let history = writes[historyURL, default: 0], details = writes[detailsURL, default: 0]
        let perWindow = windows.values.sorted()
        print("WRITE-FREQUENCY history=\(history) details=\(details) historyBytes=\(bytes[historyURL, default: 0]) detailsBytes=\(bytes[detailsURL, default: 0]) historyPer240s=\(perWindow.first ?? 0)...\(perWindow.last ?? 0) burstMinuteHistory=\(burstWrites / 6)")
        XCTAssertLessThanOrEqual(history, 100, "Minute checkpoints plus debounced transitions")
        XCTAssertLessThanOrEqual(details, 14, "Private details every five minutes plus the final flush")
        XCTAssertLessThanOrEqual(burstWrites, 6 * 6, "Twenty transitions in a minute cause at most a few writes")
        XCTAssertEqual(try ActivityHistory.load(from: historyURL), service.history)
        XCTAssertEqual(try ActivityDetails.load(from: detailsURL), service.details, "Quit flushes the private details")
        XCTAssertEqual(service.history.summary(now: clock.now).totals.claude, 3598)
    }

    @MainActor func testPhaseChangesOutsideActivityDoNotWriteAndTransitionsAreDebounced() throws {
        let clock = StorageClock(now), writes = StorageCount()
        let storage = ActivityPersistence(historyURL: try root().appendingPathComponent("a.json"), detailsURL: try root().appendingPathComponent("d.json"),
            writeHistory: { _, _ in writes.increment() }, writeDetails: { _, _, _ in }, clock: { clock.now })
        let service = ActivityService(history: .init(), details: .init(), storage: storage, powerNotifications: nil, clock: { clock.now })
        service.setProviders([.claude])
        clock.now = now; service.observe([row("a", .idle, at: now)]); _ = storage.counters
        let baseline = writes.value
        // Ready/idle/finished changes do not change what is measured.
        for (index, phase) in [SessionPhase.ready, .idle, .finished, .ready].enumerated() {
            clock.now = now.addingTimeInterval(Double(index + 20)); service.observe([row("a", phase, at: clock.now)]); _ = storage.counters
        }
        XCTAssertEqual(writes.value, baseline)
        // A transition into running is saved once, after the debounce window.
        clock.now = now.addingTimeInterval(30); service.observe([row("a", .running, at: clock.now)]); _ = storage.counters
        XCTAssertEqual(writes.value, baseline)
        clock.now = now.addingTimeInterval(46); service.observe([row("a", .running, at: clock.now)]); _ = storage.counters
        XCTAssertEqual(writes.value, baseline + 1)
        service.stop()
    }

    // MARK: A-04 sleep and wake

    @MainActor func testSleepAndWakeNotificationsBreakLiveContinuity() {
        let center = NotificationCenter(), clock = StorageClock(now)
        let service = ActivityService(powerNotifications: center, clock: { clock.now }, importer: { _, _, _ in ActivityImportResult() })
        service.setProviders([.claude])
        for offset in [0.0, 5] { clock.now = now.addingTimeInterval(offset); service.observe([row("a", .running, at: clock.now)]) }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        for offset in [15.0, 20] { clock.now = now.addingTimeInterval(offset); service.observe([row("a", .running, at: clock.now)]) }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for offset in [30.0, 35] { clock.now = now.addingTimeInterval(offset); service.observe([row("a", .running, at: clock.now)]) }
        service.flush()
        XCTAssertEqual(service.history.summary(now: clock.now).totals.claude, 15)
        service.stop()
    }

    // MARK: R3-03 durable details at quit and before sleep

    /// Details are written without fsync on the five-minute cadence (decision 23),
    /// but a kernel panic or power loss after an unsynchronized rename can leave an
    /// empty file and lose the whole 35-day breakdown. Quit and sleep write them durably.
    @MainActor func testDetailsAreSynchronizedAtQuitAndBeforeSleepOnly() throws {
        let directory = try root(), clock = StorageClock(now), center = NotificationCenter(), log = StorageSyncLog()
        let storage = ActivityPersistence(historyURL: directory.appendingPathComponent("activity.json"),
                                          detailsURL: directory.appendingPathComponent("activity-details.json"),
                                          writeHistory: { _, _ in }, writeDetails: { _, _, synchronize in log.append(synchronize) },
                                          clock: { clock.now })
        let service = ActivityService(history: .init(), details: .init(), storage: storage, powerNotifications: center, clock: { clock.now })
        service.setProviders([.claude])
        for second in stride(from: 0.0, through: 900, by: 5) {
            clock.now = now.addingTimeInterval(second)
            service.observe([row("a", .running, at: clock.now)])
        }
        _ = storage.counters
        XCTAssertFalse(log.values.isEmpty)
        XCTAssertFalse(log.values.contains(true), "The periodic details writes stay without fsync")
        let periodic = log.values.count
        clock.now = now.addingTimeInterval(905)
        service.observe([row("a", .running, at: clock.now)])
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        _ = storage.counters
        XCTAssertEqual(log.values.dropFirst(periodic), [true], "Before sleep the latest details are written with fsync")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        _ = storage.counters
        XCTAssertEqual(log.values.count, periodic + 1, "Unchanged details already on disk are not written again")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        clock.now = now.addingTimeInterval(960)
        service.observe([row("a", .running, at: clock.now)])
        service.stop()
        XCTAssertEqual(log.values.last, true, "The final flush at quit writes details with fsync")
    }

    func testAnUnsynchronizedDetailsWriteIsRepeatedWhenDurabilityIsRequested() {
        let log = StorageSyncLog(), directory = FileManager.default.temporaryDirectory
        let storage = ActivityPersistence(historyURL: directory.appendingPathComponent("unused-\(UUID().uuidString).json"),
                                          detailsURL: directory.appendingPathComponent("unused-\(UUID().uuidString).json"),
                                          writeHistory: { _, _ in }, writeDetails: { _, _, synchronize in log.append(synchronize) },
                                          completionQueue: DispatchQueue(label: "ActivityStorageTests.completion"))
        _ = storage.load(history: ActivityHistory(), details: ActivityDetails())
        var state = ActivityPersistence.State(history: ActivityHistory(), details: ActivityDetails())
        state.details.append(row("a", .running, at: now), start: now, end: now.addingTimeInterval(60))
        let done = DispatchSemaphore(value: 0)
        for durable in [false, true, true] {
            storage.submit(state, durable: durable) { _ in done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(log.values, [false, true], "Same details: rewritten once with fsync, then left alone")
    }

    // MARK: B-01 unreadable history

    @MainActor func testOversizedHistoryCanBeKeptAsACopyAndCollectionStartsOver() async throws {
        let directory = try root(), historyURL = directory.appendingPathComponent("activity.json")
        let original = Data(repeating: 0x20, count: 32_000_001)
        try original.write(to: historyURL)
        let imports = StorageCount()
        let storage = ActivityPersistence(historyURL: historyURL, detailsURL: directory.appendingPathComponent("activity-details.json"))
        let service = ActivityService(storage: storage, powerNotifications: nil, clock: { self.now }, importer: { _, _, _ in
            imports.increment(); return ActivityImportResult()
        })
        XCTAssertTrue(service.unavailable)
        service.start(providers: [.claude])
        XCTAssertTrue(service.unavailable, "Launch never replaces an unreadable file on its own")
        XCTAssertEqual(try Data(contentsOf: historyURL).count, original.count)
        service.requestImport()
        _ = storage.counters
        XCTAssertTrue(service.unavailable, "An ordinary import request never starts over")
        service.startOverPreservingHistory() // "Keep a copy and start over"
        let done = expectation(description: "Start over and import")
        let token = service.$importing.dropFirst().filter { !$0 }.first().sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5); token.cancel()
        XCTAssertFalse(service.unavailable)
        XCTAssertEqual(imports.value, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let copy = try XCTUnwrap(files.first { $0.hasPrefix("activity.json.unreadable-") })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(copy)), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(copy).path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNoThrow(try ActivityHistory.load(from: historyURL))
        XCTAssertNotNil(service.issue)
        service.stop()
    }

    /// R3-02: the connection wizard imports history after connecting a provider
    /// (`AppStore.importActivityHistory`). With an unreadable history that import
    /// must not keep a copy and start over silently: only the explicit button may.
    @MainActor func testWizardImportNeverMovesAnUnreadableHistoryAside() async throws {
        let directory = try root(), historyURL = directory.appendingPathComponent("activity.json")
        let original = Data(repeating: 0x20, count: 32_000_001)
        try original.write(to: historyURL)
        let imports = StorageCount()
        let storage = ActivityPersistence(historyURL: historyURL, detailsURL: directory.appendingPathComponent("activity-details.json"))
        let service = ActivityService(storage: storage, powerNotifications: nil, clock: { self.now }, importer: { _, _, _ in
            imports.increment(); return ActivityImportResult()
        })
        service.start(providers: [.claude])
        service.requestImport() // what the connection wizard calls
        _ = storage.counters // drains the storage queue, where a start-over would move the file
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(service.unavailable, "The history stays unavailable until the user chooses to start over")
        XCTAssertEqual(try Data(contentsOf: historyURL).count, original.count)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("activity.json.unreadable-") })
        XCTAssertEqual(imports.value, 0)
        service.stop()
    }

    func testDetailsStayBelowTheReadLimitAtTheirWorstCaseSize() throws {
        let start = now.addingTimeInterval(-86400)
        var details = ActivityDetails()
        // Every character of cwd needs JSON escaping and appears twice (key and value).
        let cwd = String(repeating: "/", count: 4096), title = String(repeating: "\u{1}", count: 1000)
        let records = (0..<2000).map { index in
            ActivityDetailRecord(provider: .codex, sessionID: String(format: "%0128d", index), title: title, cwd: cwd,
                intervals: (0..<50).map { step in
                    let begin = start.addingTimeInterval(Double(index * 100 + step) + 0.123456)
                    return ActivityInterval(start: begin, end: begin.addingTimeInterval(0.5), providers: 2, recovered: true, observedProviders: 2,
                                            recoveredProviders: 2, liveObservedProviders: 0)
                })
        }
        details.merge(records, now: now)
        let url = try root().appendingPathComponent("activity-details.json")
        try details.save(to: url)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        print("DETAILS-WORST-CASE records=\(details.records.count) bytes=\(size)")
        XCTAssertLessThanOrEqual(size, ActivityDetails.maximumBytes)
        XCTAssertLessThan(size, 32_000_000)
        XCTAssertNoThrow(try ActivityDetails.load(from: url))
        // The newest records are the ones kept.
        XCTAssertNotNil(details.records.values.first { $0.sessionID == String(format: "%0128d", 1999) })
    }

    func testAggregateHistoryAtItsIntervalCapStaysBelowTheReadLimit() throws {
        // 50,000 alternating 5 s states with every optional provenance field and fractional times.
        let reference = now.timeIntervalSinceReferenceDate + 0.123456789
        let intervals: [[String: Any]] = (0..<50_000).map { step in
            let begin = reference + Double(step) * 5, mask = step % 3 + 1
            return ["start": begin, "end": begin + 5, "providers": mask, "recovered": true, "observedProviders": 3,
                    "recoveredProviders": mask, "liveObservedProviders": 3]
        }
        let url = try root().appendingPathComponent("activity.json")
        try JSONSerialization.data(withJSONObject: ["intervals": intervals]).write(to: url)
        var history = try ActivityHistory.load(from: url)
        history.recordObservationGap(seconds: 30, at: now)
        try history.save(to: url)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        print("HISTORY-WORST-CASE intervals=\(history.intervals.count) bytes=\(size)")
        XCTAssertEqual(history.intervals.count, 50_000)
        XCTAssertLessThan(size, 32_000_000)
    }

    // MARK: B-03 abandoned temporaries

    func testActivityAndSnapshotLoadsRemoveOnlyOldOwnTemporaries() throws {
        let directory = try root(), clock = StorageClock(now)
        let old = directory.appendingPathComponent(".\(UUID().uuidString).tmp"), fresh = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let foreign = directory.appendingPathComponent(".notes.tmp")
        for file in [old, fresh, foreign] { try Data("partial".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: foreign.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: fresh.path)
        _ = ActivityPersistence(historyURL: directory.appendingPathComponent("activity.json"),
                                detailsURL: directory.appendingPathComponent("activity-details.json"), clock: { clock.now }).load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        let snapshotOld = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data("partial".utf8).write(to: snapshotOld)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: snapshotOld.path)
        _ = SnapshotPersistence(url: directory.appendingPathComponent("snapshot.json"), clock: { clock.now }).load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotOld.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        // A read-only instance never repairs shared files.
        try Data("partial".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: old.path)
        _ = SnapshotPersistence(url: directory.appendingPathComponent("snapshot.json"), clock: { clock.now }).load(readOnly: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    // MARK: B-04 bounded termination flush

    func testTerminationFlushOnAStuckVolumeReturnsAfterItsDeadline() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let directory = try root()
        // The stuck volume holds each write for 30 s (released at the end of the
        // test); the flush must return at its 0.2 s timeout, well under 5 s.
        let activity = ActivityPersistence(historyURL: directory.appendingPathComponent("a.json"), detailsURL: directory.appendingPathComponent("d.json"),
            writeHistory: { _, _ in _ = release.wait(timeout: .now() + 30) }, writeDetails: { _, _, _ in }, flushTimeout: 0.2)
        var history = ActivityHistory(); history.append(start: now, end: now.addingTimeInterval(5), providers: 1)
        var started = ProcessInfo.processInfo.systemUptime
        let result = activity.flush(.init(history: history, details: .init()))
        TimingBound.assertPrompt(since: started, strict: 2)
        XCTAssertFalse(result.historySaved)
        XCTAssertNotNil(result.historyIssue)
        let snapshots = SnapshotPersistence(url: directory.appendingPathComponent("snapshot.json"),
            write: { _, _ in _ = release.wait(timeout: .now() + 30) }, flushTimeout: 0.2)
        started = ProcessInfo.processInfo.systemUptime
        let snapshot = snapshots.flush(SharedState())
        TimingBound.assertPrompt(since: started, strict: 2)
        XCTAssertEqual(snapshot.disposition, .failed)
    }

    // MARK: Audit 04 §4 item 11: a full disk

    @MainActor func testFullDiskKeepsTheSavedFileReportsAndRetries() throws {
        let directory = try root(), historyURL = directory.appendingPathComponent("activity.json"), clock = StorageClock(now)
        let failing = StorageFlag(true)
        let storage = ActivityPersistence(historyURL: historyURL, detailsURL: directory.appendingPathComponent("activity-details.json"),
            writeHistory: { value, url in
                if failing.value { throw POSIXError(.ENOSPC) }
                try value.save(to: url)
            }, clock: { clock.now })
        var saved = ActivityHistory(); saved.append(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(-50), providers: 1)
        try saved.save(to: historyURL)
        let service = ActivityService(storage: storage, powerNotifications: nil, clock: { clock.now }, importer: { _, _, _ in ActivityImportResult() })
        service.setProviders([.claude])
        for offset in [0.0, 5] { clock.now = now.addingTimeInterval(offset); service.observe([row("a", .running, at: clock.now)]) }
        service.flush()
        XCTAssertNotNil(service.issue)
        XCTAssertEqual(try ActivityHistory.load(from: historyURL), saved, "The last good file is kept")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
        failing.value = false
        service.flush()
        XCTAssertNil(service.issue)
        XCTAssertEqual(try ActivityHistory.load(from: historyURL), service.history)
        service.stop()
    }

    // MARK: Matrix A3 and audit 04 §4 item 8: repeated import

    @MainActor func testImportingTheSameArchiveTwiceNeitherDoublesTotalsNorMovesTheBoundary() async throws {
        let archive = try root(), end = now.timeIntervalSince1970
        let rows: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "one", "started_at": end - 7200, "completed_at": end - 6600, "duration_ms": 600_000]],
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "two", "started_at": end - 3600, "completed_at": end - 3300, "duration_ms": 300_000]],
        ]
        let file = archive.appendingPathComponent("rollout.jsonl")
        try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let service = ActivityService(powerNotifications: nil, clock: { self.now }, importer: { _, boundary, now in
            ActivityHistoryImporter.read(sources: [.init(directory: archive, provider: .codex)], before: boundary, now: now)
        })
        func importOnce() async {
            let done = expectation(description: "import")
            let token = service.$importing.dropFirst().filter { !$0 }.first().sink { _ in done.fulfill() }
            service.requestImport()
            await fulfillment(of: [done], timeout: 5); token.cancel()
        }
        service.setProviders([.codex])
        await importOnce()
        let first = service.history
        await importOnce()
        XCTAssertEqual(service.history.intervals, first.intervals)
        XCTAssertEqual(service.history.summary(now: now).totals.codex, 900)
        XCTAssertEqual(service.history.providerImportCutoffs, first.providerImportCutoffs)
        XCTAssertEqual(service.history.importReport?.providers.first?.recoveredSeconds, 900)
        service.stop()
    }

    func testReimportAfterALivePeriodKeepsLiveIntervalsBoundaryAndObservedTitles() throws {
        var tracker = ActivityTracker()
        let boundary = now.addingTimeInterval(-600)
        _ = tracker.prepareImport(providers: [.codex], now: boundary)
        let live = AgentSession(provider: .codex, sessionID: "fixture", title: "Observed title", cwd: "/tmp/fixture", phase: .running,
                                updatedAt: boundary, observedAt: boundary, evidence: .localEvent, runtimeConfirmed: true)
        for offset in stride(from: 0.0, through: 60, by: 5) {
            var row = live; row.observedAt = boundary.addingTimeInterval(offset); row.updatedAt = row.observedAt
            tracker.observe([row], now: row.observedAt)
        }
        let liveIntervals = tracker.history.intervals.filter { $0.start >= boundary }
        var result = ActivityImportResult()
        let recovered = ActivityInterval(start: boundary.addingTimeInterval(-300), end: boundary.addingTimeInterval(300), providers: 2)
        result.intervals = [recovered]
        result.details = [ActivityDetailRecord(provider: .codex, sessionID: "fixture", title: "Imported title", cwd: "/tmp/fixture", intervals: [recovered])]
        result.report.providers = [.init(id: .codex)]
        tracker.mergeImport(result, now: now, providers: [.codex])
        tracker.mergeImport(result, now: now, providers: [.codex])
        XCTAssertEqual(tracker.history.providerImportCutoffs?["codex"], boundary)
        XCTAssertEqual(tracker.history.intervals.filter { $0.start >= boundary }.map(\.recoveredProviderMask), liveIntervals.map { _ in 0 })
        XCTAssertEqual(tracker.history.summary(now: now).totals.codex, 360)
        XCTAssertEqual(tracker.history.summary(now: now).totals.recovered, 300)
        let record = try XCTUnwrap(tracker.details.records.values.first)
        XCTAssertEqual(record.title, "Observed title", "A live title is not replaced by an import")
        XCTAssertEqual(record.totals(in: DateInterval(start: boundary.addingTimeInterval(-600), end: now)).active, 360)
    }
}

private final class StorageClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { get { lock.withLock { date } } set { lock.withLock { date = newValue } } }
}
private final class StorageSyncLog: @unchecked Sendable {
    private let lock = NSLock(); private var log: [Bool] = []
    var values: [Bool] { lock.withLock { log } }
    func append(_ value: Bool) { lock.withLock { log.append(value) } }
}
private final class StorageCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class StorageFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag: Bool
    init(_ flag: Bool) { self.flag = flag }
    var value: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
}
