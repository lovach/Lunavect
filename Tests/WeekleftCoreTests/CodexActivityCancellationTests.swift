import XCTest
@testable import WeekleftCore

private final class CancellationWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelOnce: Bool
    private var count = 0
    init(cancelOnce: Bool = false) { self.cancelOnce = cancelOnce }
    var calls: Int { lock.withLock { count } }
    func read(_ paths: Set<String>) -> Set<String> {
        let cancel = lock.withLock {
            count += 1
            let value = cancelOnce; cancelOnce = false
            return value
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return paths
    }
}

final class CodexActivityCancellationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture() throws -> (URL, AgentSession) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let directory = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        let file = directory.appendingPathComponent("rollout-cancel-test.jsonl")
        let line = try JSONSerialization.data(withJSONObject: ["type": "event_msg",
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-180)),
            "payload": ["type": "task_started", "turn_id": "turn-1"]]) + Data([10])
        try line.write(to: file)
        var row = AgentSession(provider: .codex, sessionID: "cancel-test", title: "Fixture", cwd: "",
                               phase: .unknown, updatedAt: now, observedAt: now, runtimeConfirmed: false)
        row.activityPath = file.path
        return (home, row)
    }

    @MainActor func testCancelledReadDoesNotProbeAndNextRefreshCanRecover() async throws {
        let (home, row) = try fixture(), probe = CancellationWriterProbe()
        let reader = CodexActivityReader(home: home, writerPaths: { probe.read($0) })
        let request = Task { await reader.events(catalog: [row], now: now) }
        request.cancel()
        let cancelled = await request.value
        XCTAssertTrue(cancelled.isEmpty); XCTAssertEqual(probe.calls, 0)
        let recovered = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(recovered.first?.effectivePhase(now: now), .running)
        XCTAssertEqual(probe.calls, 1)
    }

    func testCancellationDuringWriterProbeDoesNotPublishFreshRunningState() async throws {
        let (home, row) = try fixture(), probe = CancellationWriterProbe(cancelOnce: true)
        let reader = CodexActivityReader(home: home, writerPaths: { probe.read($0) })
        let request = Task { await reader.events(catalog: [row], now: now) }
        let cancelled = await request.value
        XCTAssertTrue(cancelled.isEmpty)
        let recovered = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(recovered.first?.effectivePhase(now: now), .running)
        XCTAssertEqual(recovered.first?.runtimeObservedAt, now)
        XCTAssertEqual(probe.calls, 2)
    }

    /// History untouched for more than a day is not scanned at launch; appended
    /// work in such a file is still read.
    func testOldJournalIsSkippedButAppendedWorkIsRead() async throws {
        let (home, row) = try fixture()
        let file = URL(fileURLWithPath: try XCTUnwrap(row.activityPath))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: file.path)
        let reader = CodexActivityReader(home: home, writerPaths: { $0 })
        let skipped = await reader.events(catalog: [row], now: now)
        XCTAssertTrue(skipped.isEmpty, "an old journal yields no event and is not parsed")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: ["type": "event_msg",
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-30)),
            "payload": ["type": "task_started", "turn_id": "turn-2"]]) + Data([10]))
        try handle.close()
        let resumed = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(resumed.first?.effectivePhase(now: now), .running)
    }
}
