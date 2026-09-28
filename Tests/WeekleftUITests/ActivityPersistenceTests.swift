import XCTest
import WeekleftCore
@testable import Weekleft

final class ActivityPersistenceTests: XCTestCase {
    /// The final flush replaces a state still waiting behind a slow write: the
    /// waiting request receives the flush's result (R2-R-02).
    @MainActor func testFinalFlushReplacesAWaitingSubmissionAndCallbacksCanInspectAndFlush() async throws {
        let paths = try paths(), first = state(1), second = state(2), final = state(3)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "completion can use persistence without deadlock")
        completed.expectedFulfillmentCount = 2
        let writes = ActivityWrites()
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details, writeHistory: { value, url in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(url, paths.history)
            if value == first.history {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            }
            writes.history(value)
        }, writeDetails: { value, url, _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(url, paths.details)
            writes.details(value)
        })
        service.submit(first) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.sequence, 1)
            XCTAssertGreaterThanOrEqual(service.counters.submitted, 3)
            XCTAssertTrue(service.flush(final).historySaved)
            completed.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        service.submit(second) { result in
            // Replaced by the final state: the flush's result, not a write of its own.
            XCTAssertEqual(result.sequence, 3)
            XCTAssertTrue(result.historySaved)
            completed.fulfill()
        }
        XCTAssertEqual(service.waitingRequests, 1)
        DispatchQueue.global().async { release.signal() }
        let flushed = service.flush(final)
        XCTAssertEqual(flushed.sequence, 3)
        XCTAssertTrue(flushed.historySaved)
        XCTAssertEqual(service.waitingRequests, 0)
        XCTAssertEqual(writes.histories, [first.history, final.history])
        XCTAssertEqual(writes.detailValues, [first.details, final.details])
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 4, written: 2, skipped: 2))
        XCTAssertEqual(writes.histories.last, final.history)
        XCTAssertEqual(writes.detailValues.last, final.details)
    }

    /// R2-R-02: a disk that takes long for each write keeps at most one waiting
    /// state however many checkpoints arrive; every request gets a result, the
    /// waiting durability request is kept, and the final flush writes the last state
    /// after at most the write in progress. The slow writer is injected.
    func testSlowDiskKeepsOneWaitingStateAndFinalFlushWritesTheLastState() throws {
        let paths = try paths(), writes = ActivityWrites(), synchronized = SyncLog()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let states = (1...120).map(state)
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details, writeHistory: { value, url in
            if value == states[0].history {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            writes.history(value)
        }, writeDetails: { value, _, durable in writes.details(value); synchronized.append(durable) },
            completionQueue: DispatchQueue(label: "ActivityPersistenceTests.slow-disk"))
        let results = ResultLog(), delivered = DispatchGroup()
        delivered.enter()
        service.submit(states[0]) { results.append($0); delivered.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for (index, value) in states.dropFirst().enumerated() {
            delivered.enter()
            // One checkpoint on the way asks for a durable write (before sleep).
            service.submit(value, durable: index == 50) { results.append($0); delivered.leave() }
            XCTAssertEqual(service.waitingRequests, index + 1, "one waiting state holds every later request")
        }
        release.signal()
        _ = service.counters // the queue has drained
        XCTAssertEqual(delivered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(writes.histories, [states[0].history, states[119].history], "only the newest waiting state is written")
        XCTAssertEqual(synchronized.values, [false, true], "the replaced durable request makes the replacing write durable")
        XCTAssertEqual(results.values.count, 120)
        XCTAssertEqual(Set(results.values.dropFirst().map(\.sequence)), [120])
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 120, written: 2, skipped: 118))

        // Again with the final flush while the first write is still in progress.
        let paths2 = try self.paths(), writes2 = ActivityWrites(), entered2 = DispatchSemaphore(value: 0), release2 = DispatchSemaphore(value: 0)
        let final = state(500)
        let quitting = ActivityPersistence(historyURL: paths2.history, detailsURL: paths2.details, writeHistory: { value, _ in
            if value == states[0].history {
                entered2.signal()
                XCTAssertEqual(release2.wait(timeout: .now() + 5), .success)
            }
            writes2.history(value)
        }, writeDetails: { value, _, _ in writes2.details(value) },
            completionQueue: DispatchQueue(label: "ActivityPersistenceTests.quit"))
        let replaced = ResultLog(), replacedDelivered = DispatchGroup()
        quitting.submit(states[0]) { _ in }
        XCTAssertEqual(entered2.wait(timeout: .now() + 5), .success)
        for value in states.dropFirst() {
            replacedDelivered.enter()
            quitting.submit(value) { replaced.append($0); replacedDelivered.leave() }
        }
        DispatchQueue.global().async { release2.signal() }
        let flushed = quitting.flush(final)
        XCTAssertTrue(flushed.historySaved)
        XCTAssertEqual(writes2.histories, [states[0].history, final.history], "the waiting checkpoints are never written after the final state")
        XCTAssertEqual(replacedDelivered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(Set(replaced.values.map(\.sequence)), [flushed.sequence])
        XCTAssertEqual(quitting.counters, PersistenceCounters(submitted: 121, written: 2, skipped: 119))
    }

    /// A state submitted after the final flush took the waiting one is written
    /// after the flush, never before it (the replaced state's queued turn is void).
    func testSubmissionAfterAFlushTookTheWaitingStateIsWrittenAfterIt() throws {
        let paths = try paths(), writes = ActivityWrites(), first = state(1), waiting = state(2), final = state(3), later = state(4)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details, writeHistory: { value, _ in
            if value == first.history {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            writes.history(value)
        }, writeDetails: { _, _, _ in }, completionQueue: DispatchQueue(label: "ActivityPersistenceTests.after-flush"))
        service.submit(first) { _ in }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        service.submit(waiting) { _ in }
        let flushed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { XCTAssertTrue(service.flush(final).historySaved); flushed.signal() }
        let deadline = Date().addingTimeInterval(5)
        while service.waitingRequests != 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(service.waitingRequests, 0, "the flush took the waiting state")
        service.submit(later) { _ in }
        release.signal()
        XCTAssertEqual(flushed.wait(timeout: .now() + 5), .success)
        _ = service.counters
        XCTAssertEqual(writes.histories, [first.history, final.history, later.history])
    }

    func testHistoryAndDetailsDeduplicateIndependentlyAndOnlyHistoryReloadsWidgets() throws {
        let paths = try paths(), initial = state(1), changed = state(2), writes = ActivityWrites()
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details,
            writeHistory: { value, _ in writes.history(value) }, writeDetails: { value, _, _ in writes.details(value) },
            reload: { writes.reload() })
        XCTAssertTrue(service.flush(initial).historySaved)
        _ = service.flush(initial)
        _ = service.flush(.init(history: changed.history, details: initial.details))
        _ = service.flush(changed)
        _ = service.flush(changed)
        XCTAssertEqual(writes.histories, [initial.history, changed.history])
        XCTAssertEqual(writes.detailValues, [initial.details, changed.details])
        XCTAssertEqual(writes.reloadCount, 1)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 5, written: 3, skipped: 2))
    }

    func testPartialFailureCanRestorePreviouslySavedStateForEitherFile() throws {
        let initial = state(1), changed = state(2)
        for failHistory in [true, false] {
            let paths = try paths(), writes = ActivityWrites()
            let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details, writeHistory: { value, url in
                if failHistory, value == changed.history {
                    // A failing injected writer may have changed the bytes before
                    // throwing. Its previous success cannot seed deduplication.
                    try Data("partial history".utf8).write(to: url)
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try value.save(to: url)
            }, writeDetails: { value, url, _ in
                if !failHistory, value == changed.details {
                    try Data("partial details".utf8).write(to: url)
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try value.save(to: url)
            }, reload: { writes.reload() })
            XCTAssertTrue(service.flush(initial).historySaved)
            let failed = service.flush(changed)
            XCTAssertEqual(failed.historySaved, !failHistory)
            XCTAssertEqual(failed.historyIssue != nil, failHistory)
            XCTAssertEqual(failed.detailsIssue != nil, !failHistory)
            let restored = service.flush(initial)
            XCTAssertTrue(restored.historySaved)
            XCTAssertNil(restored.historyIssue)
            XCTAssertNil(restored.detailsIssue)
            XCTAssertEqual(try ActivityHistory.load(from: paths.history), initial.history)
            XCTAssertEqual(try ActivityDetails.load(from: paths.details), initial.details)
            _ = service.flush(initial)
            // A submission may write one file and fail the other, so written and
            // failed counters deliberately overlap for a partial success.
            XCTAssertEqual(service.counters, PersistenceCounters(submitted: 4, written: 3, skipped: 1, failed: 1))
            XCTAssertEqual(writes.reloadCount, 1)
        }
    }

    func testDetailsReadErrorDisablesOnlyDetailsAndPreservesTheirOriginalBytes() throws {
        let paths = try paths(), initial = state(1), changed = state(2)
        try initial.history.save(to: paths.history)
        let privateBytes = Data("unreadable details fixture".utf8)
        try privateBytes.write(to: paths.details)
        let writes = ActivityWrites()
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details,
            readDetails: { _ in throw CocoaError(.fileReadNoPermission) },
            writeDetails: { _, _, _ in XCTFail("Unreadable details must stay protected") }, reload: { writes.reload() })
        let loaded = service.load()
        XCTAssertTrue(loaded.historyLoaded)
        XCTAssertFalse(loaded.detailsLoaded)
        XCTAssertEqual(loaded.state.history, initial.history)
        XCTAssertNil(loaded.historyIssue)
        XCTAssertNotNil(loaded.detailsIssue)
        let result = service.flush(changed)
        XCTAssertTrue(result.historySaved)
        XCTAssertNil(result.historyIssue)
        XCTAssertEqual(result.detailsIssue, loaded.detailsIssue)
        XCTAssertEqual(try ActivityHistory.load(from: paths.history), changed.history)
        XCTAssertEqual(try Data(contentsOf: paths.details), privateBytes)
        XCTAssertEqual(writes.reloadCount, 1)
        XCTAssertFalse(service.load().detailsLoaded)
        XCTAssertEqual(try Data(contentsOf: paths.details), privateBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.history.deletingLastPathComponent().path).count, 2)
    }

    func testMalformedRecoveryWritesSameRecoveredStateAndRetainsEveryBackup() throws {
        let paths = try paths(), writes = ActivityWrites()
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details, reload: { writes.reload() })
        var originalBackups: [URL: Data] = [:]
        for generation in 1...2 {
            let historyBytes = Data("broken history \(generation)".utf8)
            let detailsBytes = Data("broken details \(generation)".utf8)
            try historyBytes.write(to: paths.history)
            try detailsBytes.write(to: paths.details)
            let loaded = service.load()
            XCTAssertTrue(loaded.historyLoaded)
            XCTAssertTrue(loaded.detailsLoaded)
            XCTAssertNotNil(loaded.historyIssue)
            XCTAssertNotNil(loaded.detailsIssue)
            XCTAssertEqual(loaded.state, .init(history: ActivityHistory(), details: ActivityDetails()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.history.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.details.path))
            let files = try FileManager.default.contentsOfDirectory(at: paths.history.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            for file in files where originalBackups[file] == nil {
                let bytes = try Data(contentsOf: file)
                XCTAssertEqual(bytes, file.lastPathComponent.hasPrefix("activity.json.") ? historyBytes : detailsBytes)
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
                originalBackups[file] = bytes
            }
            XCTAssertEqual(originalBackups.count, generation * 2)
            let result = service.flush(loaded.state)
            XCTAssertTrue(result.historySaved)
            XCTAssertEqual(result.historyIssue, loaded.historyIssue)
            XCTAssertEqual(result.detailsIssue, loaded.detailsIssue)
            XCTAssertEqual(try ActivityHistory.load(from: paths.history), loaded.state.history)
            XCTAssertEqual(try ActivityDetails.load(from: paths.details), loaded.state.details)
            for (file, bytes) in originalBackups { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        }
        _ = service.flush(.init(history: ActivityHistory(), details: ActivityDetails()))
        XCTAssertEqual(writes.reloadCount, 1)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 3, written: 2, skipped: 1))
    }

    @MainActor func testReadOnlyLoadAndLaterFlushNeverWriteOrReload() throws {
        let paths = try paths(), initial = state(1)
        try initial.history.save(to: paths.history)
        try initial.details.save(to: paths.details)
        let historyBytes = try Data(contentsOf: paths.history), detailsBytes = try Data(contentsOf: paths.details)
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details, readHistory: {
            XCTAssertFalse(Thread.isMainThread)
            return try ActivityHistory.load(from: $0)
        }, readDetails: {
            XCTAssertFalse(Thread.isMainThread)
            return try ActivityDetails.load(from: $0)
        }, writeHistory: { _, _ in XCTFail("Read-only history cannot write") },
            writeDetails: { _, _, _ in XCTFail("Read-only details cannot write") }, reload: { XCTFail("Read-only mode cannot reload") })
        let loaded = service.load(readOnly: true)
        XCTAssertTrue(loaded.historyLoaded)
        XCTAssertTrue(loaded.detailsLoaded)
        XCTAssertEqual(loaded.state, initial)
        XCTAssertFalse(service.flush(state(2)).historySaved)
        _ = service.load()
        XCTAssertFalse(service.flush(state(3)).historySaved)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 2, skipped: 2))
        XCTAssertEqual(try Data(contentsOf: paths.history), historyBytes)
        XCTAssertEqual(try Data(contentsOf: paths.details), detailsBytes)
    }

    private func state(_ marker: Int) -> ActivityPersistence.State {
        let end = Date(timeIntervalSince1970: 1_900_000_000 + Double(marker * 100)), start = end.addingTimeInterval(-60)
        var history = ActivityHistory()
        history.append(start: start, end: end, providers: 2)
        var details = ActivityDetails()
        details.merge([ActivityDetailRecord(provider: .codex, sessionID: "fixture-\(marker)", title: "Synthetic fixture",
            cwd: "/fixture", intervals: [ActivityInterval(start: start, end: end, providers: 2)])], now: end)
        return .init(history: history, details: details)
    }
    private func paths() throws -> (history: URL, details: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityPersistenceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root.appendingPathComponent("activity.json"), root.appendingPathComponent("activity-details.json"))
    }
}

private final class ActivityWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var historyValues: [ActivityHistory] = []
    private var recordedDetails: [ActivityDetails] = []
    private var reloads = 0
    var histories: [ActivityHistory] { lock.withLock { historyValues } }
    var detailValues: [ActivityDetails] { lock.withLock { recordedDetails } }
    var reloadCount: Int { lock.withLock { reloads } }
    func history(_ value: ActivityHistory) { lock.withLock { historyValues.append(value) } }
    func details(_ value: ActivityDetails) { lock.withLock { recordedDetails.append(value) } }
    func reload() { lock.withLock { reloads += 1 } }
}
private final class ResultLog: @unchecked Sendable {
    private let lock = NSLock(); private var log: [ActivityPersistence.WriteResult] = []
    var values: [ActivityPersistence.WriteResult] { lock.withLock { log } }
    func append(_ value: ActivityPersistence.WriteResult) { lock.withLock { log.append(value) } }
}
private final class SyncLog: @unchecked Sendable {
    private let lock = NSLock(); private var log: [Bool] = []
    var values: [Bool] { lock.withLock { log } }
    func append(_ value: Bool) { lock.withLock { log.append(value) } }
}
