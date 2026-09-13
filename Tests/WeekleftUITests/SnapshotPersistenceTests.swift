import XCTest
@testable import WeekleftCore
@testable import Weekleft

final class SnapshotPersistenceTests: XCTestCase {
    @MainActor func testFlushWaitsForQueuedWritesAndDoesNotWaitForMainCompletions() async throws {
        let first = state(1), second = state(2), final = state(3)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "queued main callbacks")
        completed.expectedFulfillmentCount = 2
        let writes = RecordedWrites(), callbackSequences = RecordedWrites()
        let url = try directory().appendingPathComponent("snapshot.json")
        let service = SnapshotPersistence(url: url, write: { value, destination in
            XCTAssertFalse(Thread.isMainThread)
            if value.snapshots == first.snapshots {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            }
            writes.record(value, url: destination)
        })
        service.submit(first) { result in
            XCTAssertTrue(Thread.isMainThread)
            callbackSequences.record(first, sequence: result.sequence)
            completed.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        service.submit(second) { result in
            callbackSequences.record(second, sequence: result.sequence)
            completed.fulfill()
        }
        // Metrics remain readable while the first disk operation is blocked.
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 2))
        DispatchQueue.global().async { release.signal() }
        let result = service.flush(final)
        XCTAssertEqual(result.disposition, .written)
        XCTAssertEqual(result.sequence, 3)
        XCTAssertEqual(writes.states.map(\.snapshots), [first.snapshots, second.snapshots, final.snapshots])
        XCTAssertEqual(writes.urls, [url, url, url])
        // Main callbacks can be older than this synchronous result. Their explicit
        // sequence lets AppStore reject a late failure after a successful flush.
        XCTAssertTrue(callbackSequences.states.isEmpty)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(callbackSequences.sequences, [1, 2])
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 3, written: 3))
        XCTAssertEqual(writes.states.last?.snapshots, final.snapshots)
    }

    func testDedupComparesBothQuotasAndPreferencesAndReloadsOnlyWrittenStates() throws {
        let original = state(1)
        var changedQuota = original
        changedQuota.snapshots[0].weekly = try QuotaWindow(usedPercent: 44, durationMinutes: 10080, resetsAt: nil)
        var changedPreferences = changedQuota
        changedPreferences.preferences.showFiveHour.toggle()
        let writes = RecordedWrites(), reloads = RecordedWrites()
        let service = SnapshotPersistence(url: try directory().appendingPathComponent("snapshot.json"),
            write: { writes.record($0, url: $1) }, reload: { reloads.record(original) })
        XCTAssertEqual(service.flush(original).disposition, .written)
        XCTAssertEqual(service.flush(original).disposition, .unchanged)
        XCTAssertEqual(service.flush(changedQuota).disposition, .written)
        XCTAssertEqual(service.flush(changedPreferences).disposition, .written)
        XCTAssertEqual(service.flush(changedPreferences).disposition, .unchanged)
        XCTAssertEqual(writes.states.map(\.snapshots), [original.snapshots, changedQuota.snapshots, changedPreferences.snapshots])
        XCTAssertEqual(writes.states.last?.preferences, changedPreferences.preferences)
        XCTAssertEqual(reloads.states.count, 3)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 5, written: 3, skipped: 2))
    }

    func testFailedWriteIsRetriedAndDoesNotBecomeDedupOrReloadSuccess() throws {
        let value = state(1), attempts = RecordedWrites(), reloads = RecordedWrites()
        let service = SnapshotPersistence(url: try directory().appendingPathComponent("snapshot.json"), write: { value, url in
            attempts.record(value, url: url)
            if attempts.states.count == 1 { throw CocoaError(.fileWriteOutOfSpace) }
        }, reload: { reloads.record(value) })
        let failed = service.flush(value)
        XCTAssertEqual(failed.disposition, .failed)
        XCTAssertEqual(failed.issue, "Не удалось сохранить данные виджета.")
        XCTAssertTrue(reloads.states.isEmpty)
        let retried = service.flush(value)
        XCTAssertEqual(retried.disposition, .written)
        XCTAssertNil(retried.issue)
        XCTAssertEqual(service.flush(value).disposition, .unchanged)
        XCTAssertEqual(attempts.states.count, 2)
        XCTAssertEqual(reloads.states.count, 1)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 3, written: 1, skipped: 1, failed: 1))
    }

    @MainActor func testValidLoadSeedsDedupButMissingOrRecoveredFileNeedsWrite() throws {
        let value = state(1)
        for (exists, recovered) in [(true, false), (false, false), (false, true)] {
            let url = try directory().appendingPathComponent("snapshot.json"), writes = RecordedWrites()
            let service = SnapshotPersistence(url: url, read: { _ in XCTFail("Writable load must recover"); return SharedState() },
                recover: { receivedURL in
                    XCTAssertFalse(Thread.isMainThread)
                    XCTAssertEqual(receivedURL, url)
                    return RecoveredLocalState(value: value, backupURL: recovered ? url.appendingPathExtension("backup") : nil)
                }, write: {
                    XCTAssertFalse(Thread.isMainThread)
                    writes.record($0, url: $1)
                }, exists: { _ in exists })
            let loaded = service.load()
            XCTAssertEqual(loaded.state.snapshots, value.snapshots)
            XCTAssertEqual(loaded.state.preferences, value.preferences)
            XCTAssertTrue(loaded.writable)
            XCTAssertEqual(loaded.issue != nil, recovered)
            let result = service.flush(value)
            XCTAssertEqual(result.disposition, exists && !recovered ? .unchanged : .written)
            XCTAssertEqual(result.issue, loaded.issue)
            XCTAssertEqual(writes.states.count, exists && !recovered ? 0 : 1)
        }
    }

    func testRecoveryReadFailureDisablesWritesAndPreservesOriginalBytes() throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        let original = Data("private unreadable fixture".utf8)
        try original.write(to: url)
        let attempts = RecordedWrites()
        let service = SnapshotPersistence(url: url, read: { _ in SharedState() }, recover: { _ in
            attempts.record(SharedState())
            throw CocoaError(.fileReadNoPermission)
        }, write: { _, _ in XCTFail("Read failure must disable writes") }, reload: { XCTFail("No write means no reload") })
        let loaded = service.load()
        XCTAssertFalse(loaded.writable)
        XCTAssertEqual(loaded.issue, "Не удалось прочитать настройки. Исходный файл сохранён; запись отключена до перезапуска.")
        let result = service.flush(state(2))
        XCTAssertEqual(result.disposition, .disabled)
        XCTAssertEqual(result.issue, loaded.issue)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 1, skipped: 1))
        XCTAssertFalse(service.load().writable)
        XCTAssertEqual(attempts.states.count, 1, "Later reads stay read-only until a new persistence instance is created")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testReadOnlyLoadNeverCallsRecoverWriteOrReload() throws {
        let value = state(2), url = try directory().appendingPathComponent("snapshot.json")
        let service = SnapshotPersistence(url: url, read: { receivedURL in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(receivedURL, url)
            return value
        }, recover: { _ in
            XCTFail("Read-only mode cannot move a file to backup")
            throw CocoaError(.fileReadUnknown)
        }, write: { _, _ in XCTFail("Read-only mode cannot write") }, reload: { XCTFail("Read-only mode cannot reload") })
        let result = service.load(readOnly: true)
        XCTAssertEqual(result.state.snapshots, value.snapshots)
        XCTAssertFalse(result.writable)
        XCTAssertNil(result.issue)
        XCTAssertEqual(service.flush(state(3)).disposition, .disabled)
        XCTAssertEqual(service.counters, PersistenceCounters(submitted: 1, skipped: 1))
    }

    func testDefaultIORepairsSyntheticSnapshotThenDeduplicatesSavedState() throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        let original = Data(
            #"{"snapshots":[{"provider":"codex","source":"fixture","weekly":{"usedPercent":150,"durationMinutes":10080}}],"preferences":{"showFiveHour":true,"enabledProviders":["codex"]}}"#
                .utf8)
        try original.write(to: url)
        let reloads = RecordedWrites()
        let service = SnapshotPersistence(url: url, reload: { reloads.record(SharedState()) })
        let loaded = service.load()
        XCTAssertTrue(loaded.writable)
        XCTAssertNotNil(loaded.issue)
        XCTAssertTrue(loaded.state.snapshots.isEmpty)
        XCTAssertTrue(loaded.state.preferences.showFiveHour)
        XCTAssertEqual(loaded.state.preferences.enabledProviders, [.codex])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let saved = service.flush(loaded.state)
        XCTAssertEqual(saved.disposition, .written)
        XCTAssertEqual(saved.issue, loaded.issue)
        let decoded = try JSONDecoder().decode(SharedState.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.preferences, loaded.state.preferences)
        XCTAssertEqual(decoded.snapshots, loaded.state.snapshots)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(service.flush(loaded.state).disposition, .unchanged)
        XCTAssertEqual(reloads.states.count, 1)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    private func state(_ value: Int) -> SharedState {
        SharedState(snapshots: [UsageSnapshot(provider: .codex, source: "fixture \(value)")])
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotPersistenceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class RecordedWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SharedState] = []
    private var destinations: [URL] = []
    private var revisions: [Int] = []
    var states: [SharedState] { lock.withLock { values } }
    var urls: [URL] { lock.withLock { destinations } }
    var sequences: [Int] { lock.withLock { revisions } }
    func record(_ state: SharedState, url: URL? = nil, sequence: Int? = nil) {
        lock.withLock {
            values.append(state)
            if let url { destinations.append(url) }
            if let sequence { revisions.append(sequence) }
        }
    }
}
