import XCTest
@testable import WeekleftCore

final class CodexSessionPaginationTests: XCTestCase {
    func testActiveSessionAfterFirstHundredIsIncludedAndOpaqueCursorIsForwarded() throws {
        let cursor = "opaque / cursor ? \" second page"
        var requests = 0
        let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { method, params, _ in
            XCTAssertEqual(method, "thread/list")
            XCTAssertEqual(params["limit"] as? Int, 100)
            XCTAssertEqual(params["sortKey"] as? String, "updated_at")
            XCTAssertEqual(params["useStateDbOnly"] as? Bool, true)
            requests += 1
            if requests == 1 {
                XCTAssertNil(params["cursor"])
                return self.page((0..<100).map { self.row("thread-\($0)") }, cursor: cursor)
            }
            XCTAssertEqual(params["cursor"] as? String, cursor)
            return self.page([self.row("active-101", status: "active")])
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(result.pagesRead, 2)
        XCTAssertEqual(result.sessions.count, 101)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.sessions.first { $0.sessionID == "active-101" }?.effectivePhase(), .running)
    }

    func testLargeCatalogStopsAtPageBudgetWithExplicitPartialResult() throws {
        var requests = 0
        let result = try SessionProcess.readCodexCatalog(maxPages: 3, deadline: 12, uptime: { 0 }) { _, _, _ in
            requests += 1
            return self.page([self.row("thread-\(requests)")], cursor: "page-\(requests)")
        }
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(result.pagesRead, 3)
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertEqual(result.incompleteReason, .pageLimit)
        XCTAssertFalse(result.isComplete)
    }

    func testRepeatedAndCyclicCursorsCannotLoopOrDuplicateSessions() throws {
        for cursors in [["a", "a"], ["a", "b", "a"]] {
            var requests = 0
            let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
                let cursor = cursors[requests]
                requests += 1
                return self.page([self.row("same-thread", title: "Page \(requests)")], cursor: cursor)
            }
            XCTAssertEqual(requests, cursors.count)
            XCTAssertEqual(result.pagesRead, cursors.count)
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.sessions.first?.title, "Page \(cursors.count)")
            XCTAssertEqual(result.incompleteReason, .repeatedCursor)
        }
    }

    func testOverallDeadlinePreventsAnotherPageWithoutDiscardingFirstPage() throws {
        var clock: TimeInterval = 0, requests = 0
        let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { clock }) { _, _, deadline in
            XCTAssertEqual(deadline, 12)
            requests += 1; clock = 13
            return self.page([self.row("retained")], cursor: "next")
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(result.sessions.map(\.sessionID), ["retained"])
        XCTAssertEqual(result.incompleteReason, .timeLimit)
    }

    func testLateTimeoutPreservesPagesWhileFirstRequestFailureThrows() throws {
        var requests = 0
        let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
            requests += 1
            if requests == 2 { throw SessionError.timeout }
            return self.page([self.row("retained")], cursor: "next")
        }
        XCTAssertEqual(result.sessions.map(\.sessionID), ["retained"])
        XCTAssertEqual(result.incompleteReason, .timeLimit)
        XCTAssertThrowsError(try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
            throw SessionError.timeout
        })
    }

    func testMalformedOrMissingNextCursorIsNotReportedAsComplete() throws {
        for cursor in [42, "", ["invalid"], String(repeating: "x", count: 65537)] as [Any] {
            let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
                ["data": [self.row("retained")], "nextCursor": cursor]
            }
            XCTAssertEqual(result.incompleteReason, .invalidResponse)
            XCTAssertEqual(result.sessions.map(\.sessionID), ["retained"])
        }
        let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
            ["data": [self.row("retained")]]
        }
        XCTAssertEqual(result.incompleteReason, .invalidResponse)
    }

    func testMalformedLaterPagePreservesAlreadyReadSessions() throws {
        var requests = 0
        let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
            requests += 1
            if requests == 2 { return ["data": "invalid", "nextCursor": NSNull()] }
            return self.page([self.row("retained")], cursor: "next")
        }
        XCTAssertEqual(result.sessions.map(\.sessionID), ["retained"])
        XCTAssertEqual(result.pagesRead, 1)
        XCTAssertEqual(result.incompleteReason, .invalidResponse)
    }

    func testPriorityReadIncludesKnownActiveSessionBeforeLargeCatalogReachesBudget() throws {
        var methods: [String] = []
        let result = try SessionProcess.readCodexCatalog(prioritySessionIDs: ["active-900", "active-900", "../invalid"], maxPages: 1,
                                                        deadline: 12, uptime: { 0 }) { method, params, _ in
            methods.append(method)
            if method == "thread/read" {
                XCTAssertEqual(params["threadId"] as? String, "active-900")
                XCTAssertEqual(params["includeTurns"] as? Bool, false)
                return ["thread": self.row("active-900", status: "active")]
            }
            return self.page((0..<100).map { self.row("thread-\($0)") }, cursor: "more")
        }
        XCTAssertEqual(methods, ["thread/read", "thread/list"])
        XCTAssertEqual(result.sessions.count, 101)
        XCTAssertEqual(result.sessions.first?.sessionID, "active-900")
        XCTAssertEqual(result.sessions.first?.effectivePhase(), .running)
        XCTAssertEqual(result.incompleteReason, .pageLimit)
        XCTAssertTrue(result.unresolvedPrioritySessionIDs.isEmpty)
    }

    func testPriorityReadOfNotLoadedThreadDoesNotInventLiveActivity() throws {
        let result = try SessionProcess.readCodexCatalog(prioritySessionIDs: ["previously-running"], deadline: 12, uptime: { 0 }) { method, _, _ in
            if method == "thread/read" { return ["thread": self.row("previously-running")] }
            return self.page([])
        }
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(session.phase, .unknown)
        XCTAssertEqual(session.effectivePhase(), .unknown)
        XCTAssertEqual(session.runtimeConfirmed, false)
        XCTAssertTrue(result.isComplete)
    }

    func testPriorityReadCountAndTimeAreBoundedAndUnresolvedIDsAreExplicit() throws {
        let ids = (0..<20).map { "priority-\($0)" }
        var reads = 0
        let capped = try SessionProcess.readCodexCatalog(prioritySessionIDs: ids, deadline: 12, uptime: { 0 }) { method, params, _ in
            if method == "thread/read" {
                reads += 1
                return ["thread": self.row(try XCTUnwrap(params["threadId"] as? String))]
            }
            return self.page([])
        }
        XCTAssertEqual(reads, 16)
        XCTAssertEqual(capped.unresolvedPrioritySessionIDs, Array(ids.suffix(4)))
        XCTAssertEqual(capped.incompleteReason, .priorityReadIncomplete)

        var clock: TimeInterval = 0
        reads = 0
        let timed = try SessionProcess.readCodexCatalog(prioritySessionIDs: ids, deadline: 12, uptime: { clock }) { method, _, deadline in
            if method == "thread/read" {
                reads += 1
                XCTAssertLessThanOrEqual(deadline, 3)
                XCTAssertLessThanOrEqual(deadline - clock, 1)
                clock = deadline
                throw SessionError.timeout
            }
            XCTAssertEqual(clock, 3)
            XCTAssertEqual(deadline, 12)
            return self.page([])
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(timed.unresolvedPrioritySessionIDs, ids)
        XCTAssertEqual(timed.incompleteReason, .priorityReadIncomplete)
    }

    func testListCanResolveFailedPriorityReadWithoutFalsePartialState() throws {
        let result = try SessionProcess.readCodexCatalog(prioritySessionIDs: ["known"], deadline: 12, uptime: { 0 }) { method, _, _ in
            if method == "thread/read" { throw SessionError.invalidResponse }
            return self.page([self.row("known", status: "active")])
        }
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.unresolvedPrioritySessionIDs.isEmpty)
        XCTAssertEqual(result.sessions.first?.phase, .running)
    }

    func testPriorityResponseCannotSubstituteAnotherThread() throws {
        let result = try SessionProcess.readCodexCatalog(prioritySessionIDs: ["requested"], deadline: 12, uptime: { 0 }) { method, _, _ in
            if method == "thread/read" { return ["thread": self.row("unrelated", status: "active")] }
            return self.page([])
        }
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.unresolvedPrioritySessionIDs, ["requested"])
        XCTAssertFalse(result.isComplete)
    }

    func testPartialCatalogRetainsMissingActiveRowsAsUnknownWithJournalPath() throws {
        let now = Date()
        var active = AgentSession(provider: .codex, sessionID: "beyond-budget", title: "Known task", cwd: "/project",
                                  phase: .running, updatedAt: now.addingTimeInterval(-60), observedAt: now,
                                  evidence: .localEvent, runtimeConfirmed: true)
        active.activityPath = "/fixture/rollout.jsonl"
        active.runtimeObservedAt = now
        let waiting = AgentSession(provider: .codex, sessionID: "waiting", title: "Wait", cwd: "", phase: .input,
                                   updatedAt: now, observedAt: .distantPast)
        let idle = AgentSession(provider: .codex, sessionID: "idle", title: "Idle", cwd: "", phase: .idle,
                                updatedAt: now, observedAt: now)
        let catalog = CodexSessionCatalog(sessions: [], incompleteReason: .pageLimit, pagesRead: 8)
        let retained = catalog.retainingKnownSessions([active, active, waiting, idle])
        XCTAssertEqual(retained.map(\.sessionID), ["beyond-budget", "waiting"])
        XCTAssertTrue(retained.allSatisfy { $0.effectivePhase(now: now) == .unknown })
        XCTAssertTrue(retained.allSatisfy { $0.observedAt == .distantPast && $0.runtimeConfirmed == false && $0.evidence == .catalog })
        XCTAssertEqual(retained.first?.phase, .running)
        XCTAssertEqual(retained.first?.activityPath, active.activityPath)
        XCTAssertEqual(retained.first?.updatedAt, active.updatedAt)
    }

    func testCompleteCatalogDropsAbsentRowsAndPartialDoesNotOverwriteFreshRows() throws {
        let old = AgentSession(provider: .codex, sessionID: "known", title: "Old", cwd: "", phase: .running,
                               updatedAt: .distantPast, observedAt: .distantPast)
        XCTAssertTrue(CodexSessionCatalog(sessions: []).retainingKnownSessions([old]).isEmpty)
        var fresh = old; fresh.title = "Fresh"; fresh.observedAt = Date(); fresh.runtimeConfirmed = true
        let partial = CodexSessionCatalog(sessions: [fresh], incompleteReason: .timeLimit)
        XCTAssertEqual(partial.retainingKnownSessions([old]), [fresh])
        var unknown = old; unknown.phase = .unknown
        let unresolved = CodexSessionCatalog(sessions: [], unresolvedPrioritySessionIDs: [old.sessionID])
        XCTAssertFalse(unresolved.isComplete)
        XCTAssertEqual(unresolved.retainingKnownSessions([unknown]).first?.sessionID, unknown.sessionID)
    }

    func testNotLoadedKeepsKnownActiveIDEligibleAcrossTwoPartialRefreshesWithoutLiveStatus() throws {
        var previous = AgentSession(provider: .codex, sessionID: "beyond-budget", title: "Known", cwd: "/project", phase: .running,
                                    updatedAt: .distantPast, observedAt: Date(), runtimeConfirmed: true)
        previous.activityPath = "/fixture/rollout.jsonl"
        let notLoaded = try XCTUnwrap(SessionParser.codex(JSONSerialization.data(withJSONObject: page([row(previous.sessionID)]))).first)
        for reason: CodexSessionCatalog.IncompleteReason? in [nil, .pageLimit] {
            let first = CodexSessionCatalog(sessions: [notLoaded], incompleteReason: reason).retainingKnownSessions([previous])
            let remembered = try XCTUnwrap(first.first)
            XCTAssertEqual(remembered.phase, .running)
            XCTAssertEqual(remembered.effectivePhase(), .unknown)
            XCTAssertEqual(remembered.observedAt, .distantPast)
            XCTAssertEqual(remembered.runtimeConfirmed, false)
            XCTAssertEqual(remembered.evidence, .catalog)
            XCTAssertEqual(remembered.activityPath, previous.activityPath)

            let priorityIDs = first.filter { $0.phase.isActive }.map(\.sessionID)
            var reads = 0
            let next = try SessionProcess.readCodexCatalog(prioritySessionIDs: priorityIDs, maxPages: 1, deadline: 12, uptime: { 0 }) { method, params, _ in
                if method == "thread/read" {
                    reads += 1
                    XCTAssertEqual(params["threadId"] as? String, previous.sessionID)
                    throw SessionError.timeout
                }
                return self.page([self.row("recent")], cursor: "older")
            }
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(next.unresolvedPrioritySessionIDs, [previous.sessionID])
            let second = next.retainingKnownSessions(first)
            let retained = try XCTUnwrap(second.first { $0.sessionID == previous.sessionID })
            XCTAssertEqual(retained.effectivePhase(), .unknown)
            XCTAssertEqual(retained.activityPath, previous.activityPath)
            XCTAssertTrue(CodexSessionCatalog(sessions: []).retainingKnownSessions(second).isEmpty)
        }
    }

    func testCodexInputWriteTimesOutWhenReaderKeepsFullPipeOpen() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SessionProcess.writeCodexInput(Data(repeating: 120, count: 1_000_000),
                                                              to: pipe.fileHandleForWriting, until: started + 0.05)) {
            guard case SessionError.timeout = $0 else { return XCTFail("Expected bounded write timeout, got \($0)") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8)
    }

    func testCodexInputWriteReportsClosedPipeWithoutChangingProcessSignals() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        defer { try? pipe.fileHandleForWriting.close() }
        XCTAssertThrowsError(try SessionProcess.writeCodexInput(Data("request\n".utf8), to: pipe.fileHandleForWriting,
                                                              until: ProcessInfo.processInfo.systemUptime + 1)) {
            guard case SessionError.invalidResponse = $0 else { return XCTFail("Expected EPIPE response error, got \($0)") }
        }
    }

    func testSubprocessReadsMultiplePagesAndIgnoresUnrelatedReplies() throws {
        let first = try json(["id": 2, "result": page((0..<100).map { row("thread-\($0)") }, cursor: "next-page")])
        let second = try json(["id": 3, "result": page([row("active-101", status: "active")])])
        let script = try fixture("""
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '\(first)'
        IFS= read -r request
        case "$request" in
          *next-page*) ;;
          *) exit 3 ;;
        esac
        printf '%s\\n' '{"method":"thread/status/changed","params":{}}' '{"id":2,"error":{"message":"old reply"}}' '\(second)'
        """)
        let result = try SessionProcess.codexCatalog(path: script.path, proxy: false, timeout: 2)
        XCTAssertEqual(result.pagesRead, 2)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.sessions.count, 101)
        XCTAssertEqual(result.sessions.last?.phase, .running)
    }

    private func row(_ id: String, status: String = "notLoaded", title: String? = nil) -> [String: Any] {
        ["id": id, "name": title ?? id, "status": ["type": status], "updatedAt": 1_789_200_000]
    }
    private func page(_ rows: [[String: Any]], cursor: String? = nil) -> [String: Any] {
        ["data": rows, "nextCursor": cursor as Any? ?? NSNull()]
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func fixture(_ content: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-pagination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cli")
        try Data(content.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
