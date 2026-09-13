import XCTest
import WeekleftCore
@testable import Weekleft

final class ActivityPersistenceTests: XCTestCase {
    @MainActor func testSlowSubmissionsFinishBeforeFinalFlushAndCallbacksCanInspectAndFlush() async throws {
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
        }, writeDetails: { value, url in
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
            XCTAssertEqual(result.sequence, 2)
            completed.fulfill()
        }
        DispatchQueue.global().async { release.signal() }
        let flushed = service.flush(final)
        XCTAssertEqual(flushed.sequence, 3)
        XCTAssertTrue(flushed.historySaved)
        XCTAssertEqual(writes.histories, [first.history, second.history, final.history])
        XCTAssertEqual(writes.detailValues, [first.details, second.details, final.details])
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 4, written: 3, skipped: 1))
        XCTAssertEqual(writes.histories.last, final.history)
        XCTAssertEqual(writes.detailValues.last, final.details)
    }

    func testHistoryAndDetailsDeduplicateIndependentlyAndOnlyHistoryReloadsWidgets() throws {
        let paths = try paths(), initial = state(1), changed = state(2), writes = ActivityWrites()
        let service = ActivityPersistence(historyURL: paths.history, detailsURL: paths.details,
            writeHistory: { value, _ in writes.history(value) }, writeDetails: { value, _ in writes.details(value) },
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
            }, writeDetails: { value, url in
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
            writeDetails: { _, _ in XCTFail("Unreadable details must stay protected") }, reload: { writes.reload() })
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
            writeDetails: { _, _ in XCTFail("Read-only details cannot write") }, reload: { XCTFail("Read-only mode cannot reload") })
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
