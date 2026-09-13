import XCTest
import Darwin
@testable import WeekleftCore

@MainActor final class LocalProcessCancellationTests: XCTestCase {
    func testCancelledWrappersNeverLaunchOrPrepareProbeDirectory() async throws {
        let root = try directory(), marker = root.appendingPathComponent("started")
        let script = try fixture(in: root, body: "printf started > \(SessionHooks.quote(marker.path))\nexit 0")
        let probe = root.appendingPathComponent("probe")
        let operations: [@Sendable () async throws -> Void] = [
            { _ = try await SessionSources.claude(path: script.path) },
            { _ = try await SessionSources.codexCatalog(path: script.path, home: root) },
            { _ = try await CodexProvider.fetch(cliPath: script.path) },
            { _ = try await ClaudeUsageProbe.fetch(cliPath: script.path, directory: probe) }
        ]
        for operation in operations {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await operation()
            }
            await assertCancelled(task)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.path))
    }

    func testCancelledQuotaReadKillsOwnTermIgnoringChildPromptly() async throws {
        let root = try directory(), marker = root.appendingPathComponent("pid")
        let script = try sleepingFixture(in: root, marker: marker)
        let task = Task { try await CodexProvider.fetch(cliPath: script.path) }
        defer { task.cancel() }
        let pid = try await waitForPID(marker)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await assertCancelled(task)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        XCTAssertEqual(kill(pid, 0), -1, "The owned child must be gone before cancellation completes")
    }

    func testCancelledSessionWaitAfterStdoutClosesStopsOwnedChild() async throws {
        let root = try directory(), marker = root.appendingPathComponent("pid")
        let script = try sleepingFixture(in: root, marker: marker, beforeSleep: "exec 1>&-")
        let task = Task { try await SessionSources.claude(path: script.path) }
        defer { task.cancel() }
        let pid = try await waitForPID(marker)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await assertCancelled(task)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testCancelledUsagePTYStopsOwnedChildWithoutTimeoutSubstitution() async throws {
        let root = try directory(), marker = root.appendingPathComponent("pid")
        let script = try sleepingFixture(in: root, marker: marker)
        let task = Task { try await ClaudeUsageProbe.fetch(cliPath: script.path, timeout: 30, directory: root.appendingPathComponent("probe")) }
        defer { task.cancel() }
        let pid = try await waitForPID(marker)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await assertCancelled(task)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testCancelledProxyDoesNotStartFallbackServer() async throws {
        let root = try directory(), marker = root.appendingPathComponent("pid"), calls = root.appendingPathComponent("calls")
        let socket = root.appendingPathComponent("app-server-control/app-server-control.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: socket)
        let script = try sleepingFixture(in: root, marker: marker, beforeSleep: "printf '%s\\n' \"$*\" >> \(SessionHooks.quote(calls.path))")
        let task = Task { try await SessionSources.codexCatalog(path: script.path, home: root) }
        defer { task.cancel() }
        let pid = try await waitForPID(marker)
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(try String(contentsOf: calls).split(separator: "\n").map(String.init), ["app-server proxy"])
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testCancellationFromPriorityOrLaterPageIsNeverConvertedToPartialCatalog() throws {
        var methods: [String] = []
        XCTAssertThrowsError(try SessionProcess.readCodexCatalog(prioritySessionIDs: ["known"], deadline: 12, uptime: { 0 }) { method, _, _ in
            methods.append(method)
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(methods, ["thread/read"])

        var requests = 0
        XCTAssertThrowsError(try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
            requests += 1
            if requests == 2 { throw CancellationError() }
            return ["data": [["id": "known", "status": ["type": "active"]]], "nextCursor": "more"]
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(requests, 2)
    }

    func testCancelledPipeWriteStopsBeforeItsLongDeadline() async throws {
        let root = try directory(), marker = root.appendingPathComponent("writing"), pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let task = Task {
            try await SessionProcess.detached {
                try Data().write(to: marker)
                try SessionProcess.writeCodexInput(Data(repeating: 120, count: 1_000_000), to: pipe.fileHandleForWriting,
                                                  until: ProcessInfo.processInfo.systemUptime + 30)
            }
        }
        defer { task.cancel() }
        try await waitForFile(marker)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await assertCancelled(task)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8)
    }

    func testCancellationAfterUsageProbeDoesNotWriteCacheOrReturnCachedFallback() async {
        var cacheReads = 0, cacheWrites = 0
        let snapshot = UsageSnapshot(provider: .claude, fetchedAt: Date(), source: ClaudeUsageProbe.source)
        let task = Task {
            try await ClaudeProvider.refresh(force: true, cached: { cacheReads += 1; return snapshot }, probe: {
                withUnsafeCurrentTask { $0?.cancel() }
                return snapshot
            }, save: { _ in cacheWrites += 1 })
        }
        await assertCancelled(task)
        XCTAssertEqual(cacheReads, 0)
        XCTAssertEqual(cacheWrites, 0)
    }

    private func assertCancelled<T>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "Cancellation became \(error)", file: file, line: line) }
    }
    private func waitForFile(_ url: URL) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ProcessInfo.processInfo.systemUptime < end else { throw SessionError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func waitForPID(_ url: URL) async throws -> Int32 {
        try await waitForFile(url)
        let end = ProcessInfo.processInfo.systemUptime + 1
        while true {
            if let value = try? String(contentsOf: url), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            guard ProcessInfo.processInfo.systemUptime < end else { throw SessionError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func sleepingFixture(in root: URL, marker: URL, beforeSleep: String = "") throws -> URL {
        try fixture(in: root, body: "trap '' TERM\n\(beforeSleep)\nprintf '%s\\n' \"$$\" > \(SessionHooks.quote(marker.path))\nexec /bin/sleep 30")
    }
    private func fixture(in root: URL, body: String) throws -> URL {
        let script = root.appendingPathComponent("cli-" + UUID().uuidString)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
