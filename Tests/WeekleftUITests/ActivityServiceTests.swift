import XCTest
import Combine
@testable import Weekleft
import WeekleftCore

final class ActivityServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private actor Imports {
        struct Call { let providers: Set<ProviderID>; let boundary: Date }
        private(set) var calls: [Call] = []
        private var pending: [Int: CheckedContinuation<ActivityImportResult, Never>] = [:]
        let called: @Sendable () -> Void
        init(called: @escaping @Sendable () -> Void) { self.called = called }
        func read(_ providers: Set<ProviderID>, boundary: Date) async -> ActivityImportResult {
            let index = calls.count
            calls.append(Call(providers: providers, boundary: boundary))
            return await withCheckedContinuation { pending[index] = $0; called() }
        }
        func finish(_ index: Int, result: ActivityImportResult) { pending.removeValue(forKey: index)?.resume(returning: result) }
    }
    private func imported(_ provider: ProviderID) -> ActivityImportResult {
        var result = ActivityImportResult()
        result.intervals = [.init(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(-10), providers: provider == .claude ? 1 : 2)]
        return result
    }
    @MainActor private func waitUntilIdle(_ service: ActivityService) async {
        guard service.importing else { return }
        let done = expectation(description: "Import ends")
        let token = service.$importing.dropFirst().filter { !$0 }.first().sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 3)
        token.cancel()
    }
    @MainActor func testImmediateStopBeforeTaskRunsNeverInvokesImportBackend() async {
        let invoked = expectation(description: "Cancelled backend must not start"); invoked.isInverted = true
        let service = ActivityService(clock: { self.now }, importer: { _, _, _ in
            invoked.fulfill(); return ActivityImportResult()
        })
        service.setProviders([.codex]); service.requestImport(); service.stop()
        await fulfillment(of: [invoked], timeout: 0.04)
        XCTAssertFalse(service.importing)
        XCTAssertNil(service.history.importedAt)
    }
    @MainActor func testStopRejectsLateImportAndRepeatedStartOwnsOneWorker() async {
        let called = expectation(description: "Initial import")
        let restarted = expectation(description: "Restarted import")
        let counter = CallCounter()
        let gate = Imports { if counter.next() == 1 { called.fulfill() } else { restarted.fulfill() } }
        let service = ActivityService(clock: { self.now }, importer: { providers, boundary, _ in
            await gate.read(providers, boundary: boundary)
        })
        service.start(providers: [.codex]); service.start(providers: [.codex])
        await fulfillment(of: [called], timeout: 3)
        service.stop(); service.stop()
        XCTAssertFalse(service.importing)
        service.start(providers: [.codex]); service.start(providers: [.codex])
        await fulfillment(of: [restarted], timeout: 3)
        await gate.finish(1, result: imported(.codex))
        await waitUntilIdle(service)
        let expected = service.history
        let changed = expectation(description: "Stopped worker must not publish"); changed.isInverted = true
        let token = service.$history.dropFirst().sink { _ in changed.fulfill() }
        await gate.finish(0, result: imported(.claude))
        await fulfillment(of: [changed], timeout: 0.04)
        token.cancel()
        XCTAssertEqual(service.history, expected)
        XCTAssertEqual(counter.value, 2)
        service.stop()
    }
    @MainActor func testProviderChangeCancelsOldImportAndKeepsNewSelection() async {
        let called = expectation(description: "Both provider selections run"); called.expectedFulfillmentCount = 2
        let gate = Imports { called.fulfill() }
        let first = expectation(description: "First import started")
        let counter = CallCounter()
        let service = ActivityService(clock: { self.now }, importer: { providers, boundary, _ in
            if counter.next() == 1 { first.fulfill() }
            return await gate.read(providers, boundary: boundary)
        })
        service.start(providers: [.claude, .codex])
        await fulfillment(of: [first], timeout: 3)
        service.setProviders([.claude])
        await fulfillment(of: [called], timeout: 3)
        await gate.finish(1, result: imported(.claude))
        await waitUntilIdle(service)
        let changed = expectation(description: "Disabled source must not publish"); changed.isInverted = true
        let token = service.$history.dropFirst().sink { _ in changed.fulfill() }
        await gate.finish(0, result: imported(.codex))
        await fulfillment(of: [changed], timeout: 0.04)
        token.cancel()
        XCTAssertEqual(service.history.summary(now: now).totals.claude, 50)
        XCTAssertEqual(service.history.summary(now: now).totals.codex, 0)
        let calls = await gate.calls
        XCTAssertEqual(calls.map(\.providers), [Set([.claude, .codex]), Set([.claude])])
        XCTAssertEqual(calls.map(\.boundary), [now, now])
        service.stop()
    }
    @MainActor func testCancelledResultEndsImportAndCoalescedRetryKeepsBoundary() async {
        let called = expectation(description: "First call")
        let retried = expectation(description: "Coalesced retry")
        let counter = CallCounter()
        let gate = Imports { if counter.next() == 1 { called.fulfill() } else { retried.fulfill() } }
        let service = ActivityService(clock: { self.now }, importer: { providers, boundary, _ in
            await gate.read(providers, boundary: boundary)
        })
        service.setProviders([.codex]); service.requestImport()
        await fulfillment(of: [called], timeout: 3)
        for _ in 0..<20 { service.requestImport() }
        var cancelled = imported(.claude); cancelled.cancelled = true
        await gate.finish(0, result: cancelled)
        await fulfillment(of: [retried], timeout: 3)
        await gate.finish(1, result: imported(.codex))
        await waitUntilIdle(service)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(service.history.summary(now: now).totals.claude, 0)
        XCTAssertEqual(service.history.summary(now: now).totals.codex, 50)
        XCTAssertEqual(service.history.importCutoff, now)
        service.stop()
    }
    @MainActor func testFailedBoundaryWriteDoesNotStartImportAndRetryPersistsItFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = CallCounter(), imports = CallCounter()
        let storage = ActivityPersistence(historyURL: root.appendingPathComponent("history.json"), detailsURL: root.appendingPathComponent("details.json"),
            writeHistory: { history, url in
                XCTAssertFalse(Thread.isMainThread)
                if writes.next() == 1 { throw CocoaError(.fileWriteNoPermission) }
                try history.save(to: url)
            })
        let service = ActivityService(history: .init(), details: .init(), storage: storage, clock: { self.now }, importer: { _, boundary, _ in
            imports.next()
            XCTAssertEqual(try ActivityHistory.load(from: root.appendingPathComponent("history.json")).importCutoff, boundary)
            return ActivityImportResult()
        })
        service.setProviders([.codex]); service.requestImport()
        await waitUntilIdle(service)
        XCTAssertEqual(imports.value, 0)
        XCTAssertNotNil(service.issue)
        service.requestImport()
        await waitUntilIdle(service)
        service.stop()
        XCTAssertEqual(imports.value, 1)
        XCTAssertEqual(service.history.importCutoff, now)
        XCTAssertNotNil(service.history.importedAt)
        XCTAssertNil(service.issue)
        XCTAssertEqual(try ActivityHistory.load(from: root.appendingPathComponent("history.json")), service.history)
    }
    @MainActor func testStopAndProviderChangeBreakLiveObservationContinuity() {
        var date = now
        let service = ActivityService(clock: { date }, importer: { _, _, _ in ActivityImportResult() })
        service.setProviders([.codex])
        let row = AgentSession(provider: .codex, sessionID: "fixture", title: "Fixture", cwd: "/fixture", phase: .running,
                               updatedAt: now, observedAt: now, runtimeConfirmed: true)
        service.observe([row]); date = now.addingTimeInterval(5); service.observe([row]); service.flush()
        XCTAssertEqual(service.history.summary(now: date).totals.active, 5)
        service.stop(); date = now.addingTimeInterval(7); service.observe([row])
        XCTAssertEqual(service.history.summary(now: date).totals.active, 5)
        service.start(providers: [.codex]); date = now.addingTimeInterval(8); service.observe([row])
        service.setProviders([]); service.setProviders([.codex]); date = now.addingTimeInterval(9); service.observe([row]); service.flush()
        XCTAssertEqual(service.history.summary(now: date).totals.active, 5)
        service.stop()
    }
    @MainActor func testIsolatedServiceNeverLoadsWritesOrImportsInjectedStorage() {
        let work = CallCounter()
        let storage = ActivityPersistence(historyURL: URL(fileURLWithPath: "/unused/history"), detailsURL: URL(fileURLWithPath: "/unused/details"),
            readHistory: { _ in work.next(); return .init() }, readDetails: { _ in work.next(); return .init() },
            writeHistory: { _, _ in work.next() }, writeDetails: { _, _ in work.next() }, reload: { work.next() })
        let service = ActivityService(storage: storage, isolated: true, clock: { self.now }, importer: { _, _, _ in
            work.next(); return ActivityImportResult()
        })
        service.setProviders([.codex]); service.start(providers: [.codex]); service.requestImport(); service.flush(); service.stop()
        XCTAssertEqual(work.value, 0)
        XCTAssertFalse(service.importing)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func next() -> Int { lock.withLock { count += 1; return count } }
}
