import XCTest
@testable import Weekleft
@testable import WeekleftCore

@MainActor final class SessionStoreLifecycleTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testPrecancelledRefreshDoesNotStartAnyDependency() async throws {
        var calls = 0
        let store = try fixture(.init(catalog: { _, _, _, _ in calls += 1; return ([], false) },
                                      events: { _, _, _ in calls += 1; return [] },
                                      titles: { _, _, _ in calls += 1; return [:] },
                                      hooksState: { calls += 1; return [:] }))
        let request = Task { await store.refresh() }
        request.cancel(); await request.value
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(store.refreshing)
        XCTAssertNil(store.updatedAt)
        XCTAssertTrue(store.diagnosticEntries.isEmpty)
    }

    func testStopRejectsNoncooperativeCatalogAndRestartCanPublish() async throws {
        let began = expectation(description: "Catalog pending")
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0, eventCalls = 0
        let row = session("fresh")
        let store = try fixture(.init(catalog: { _, _, _, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { resume = $0; began.fulfill() } }
            return ([row], false)
        }, events: { _, _, _ in eventCalls += 1; return [] }))
        store.useProviders([.codex])
        let request = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 2)
        store.stop(); resume?.resume(); await request.value
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.updatedAt)
        XCTAssertEqual(eventCalls, 0)
        XCTAssertFalse(store.refreshing)
        await store.refresh()
        XCTAssertEqual(calls, 1, "Stopped stores cannot implicitly restart a source")
        store.start(clientResolver: inertResolver)
        await store.refresh()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.sessions.map(\.sessionID), ["fresh"])
        XCTAssertEqual(store.updatedAt, instant)
        store.stop()
    }

    func testProviderChangeRejectsOldGenerationWithoutClearingNewWork() async throws {
        let began = expectation(description: "Old provider pending")
        var resume: CheckedContinuation<Void, Never>?
        var calls: [ProviderID] = []
        let stale = session("stale"), fresh = session("fresh", provider: .claude)
        let store = try fixture(.init(catalog: { provider, _, _, _ in
            calls.append(provider)
            if provider == .codex { await withCheckedContinuation { resume = $0; began.fulfill() }; return ([stale], false) }
            return ([fresh], false)
        }))
        store.useProviders([.codex])
        let old = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 2)
        store.useProviders([.claude]); await store.refresh()
        resume?.resume(); await old.value
        XCTAssertEqual(calls, [.codex, .claude])
        XCTAssertEqual(store.sessions.map(\.sessionID), ["fresh"])
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertFalse(store.refreshing)
        store.stop()
    }

    func testRefreshCancellationReachesCatalogAndCannotBecomeAnIssue() async throws {
        let began = expectation(description: "Catalog sleeping"), cancelled = expectation(description: "Catalog cancelled")
        var eventCalls = 0
        let store = try fixture(.init(catalog: { _, _, _, _ in
            began.fulfill()
            do { try await Task.sleep(for: .seconds(30)); return ([], false) }
            catch { cancelled.fulfill(); throw error }
        }, events: { _, _, _ in eventCalls += 1; return [] }))
        store.useProviders([.codex])
        let request = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 2)
        request.cancel(); await request.value
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(eventCalls, 0)
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertTrue(store.typedIssues.isEmpty)
        XCTAssertTrue(store.diagnosticEntries.isEmpty)
        XCTAssertNil(store.updatedAt)
        XCTAssertFalse(store.refreshing)
    }

    func testStopDuringEventsPreventsTitleReadAndObservation() async throws {
        let began = expectation(description: "Events pending")
        var resume: CheckedContinuation<Void, Never>?
        var titleCalls = 0, observations = 0
        let row = session("event")
        let store = try fixture(.init(catalog: { _, _, _, _ in ([row], false) }, events: { _, _, _ in
            await withCheckedContinuation { resume = $0; began.fulfill() }; return [row]
        }, titles: { _, _, _ in titleCalls += 1; return [:] }))
        store.useProviders([.codex]); store.onObservation = { _, _ in observations += 1 }
        let request = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 2)
        store.stop(); resume?.resume(); await request.value
        XCTAssertEqual(titleCalls, 0)
        XCTAssertEqual(observations, 0)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testStopDuringTitlesDoesNotRewriteHiddenMetadata() async throws {
        let began = expectation(description: "Titles pending")
        var resume: CheckedContinuation<Void, Never>?
        let row = session("hidden")
        let root = try directory()
        let store = try fixture(.init(catalog: { _, _, _, _ in ([row], false) }, titles: { _, _, _ in
            await withCheckedContinuation { resume = $0; began.fulfill() }; return [row.id: "Late rename"]
        }), directory: root)
        store.useProviders([.codex]); store.acceptSessions([row]); try store.hide(row)
        let file = root.appendingPathComponent("hidden-sessions.json"), original = try Data(contentsOf: file)
        let request = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 2)
        store.stop(); resume?.resume(); await request.value
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(store.hiddenSessions.first?.title, row.title)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testStartAndStopBeforeQueuedRefreshDoesNotStartBackend() async throws {
        var calls = 0
        let store = try fixture(.init(catalog: { _, _, _, _ in calls += 1; return ([], false) }))
        store.start(clientResolver: inertResolver)
        store.start(clientResolver: inertResolver)
        store.stop()
        await Task.yield(); await store.refresh()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(store.refreshing)
    }

    func testIsolatedDefaultsAndClockRemainWithinFixture() async throws {
        let store = try fixture()
        store.start(clientResolver: inertResolver); await store.refresh()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.hooksInstalled.isEmpty)
        XCTAssertFalse(store.disconnect(.codex))
        store.toggleHooks(.claude)
        XCTAssertTrue(store.hooksInstalled.isEmpty)
        let row = session("clock")
        store.acceptSessions([row]); XCTAssertEqual(store.activeCount, 1)
        try store.hide(row)
        XCTAssertEqual(store.hiddenSessions.first?.hiddenAt, instant)
        store.stop()
    }

    func testTypedDiagnosticsKeepOnlyBoundedAllowlistedFacts() async throws {
        let privateError = NSError(domain: "/private/path/token/transcript", code: 42,
                                   userInfo: [NSLocalizedDescriptionKey: "secret title and credential"])
        let store = try fixture(.init(catalog: { _, _, _, _ in throw privateError }))
        store.useProviders([.codex])
        for _ in 0..<40 { await store.refresh() }
        XCTAssertEqual(store.diagnosticEntries.count, 32)
        XCTAssertTrue(store.diagnosticEntries.allSatisfy { $0.date == instant && $0.issue.code == "codex.sessionCatalog.sourceUnavailable" })
        XCTAssertEqual(store.typedIssues[.codex]?.reason, .sourceUnavailable)
        XCTAssertFalse(store.issues.values.joined().contains("secret"))
        store.useProviders([.claude])
        XCTAssertNil(store.typedIssues[.codex])
        XCTAssertNil(store.issues[.codex])
    }

    func testHiddenTitleWriteFailurePublishesFreshStatusAndRecovers() async throws {
        try await verifyHiddenTitleWriteRecovery(replaceMessage: false)
    }

    func testHiddenTitleRecoveryKeepsNewerUnrelatedMessage() async throws {
        try await verifyHiddenTitleWriteRecovery(replaceMessage: true)
    }

    private func verifyHiddenTitleWriteRecovery(replaceMessage: Bool) async throws {
        let manager = FileManager.default, root = try directory()
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let file = root.appendingPathComponent("hidden-sessions.json")
        var clock = instant
        var hidden = session("hidden"); hidden.phase = .ready
        var visibleCodex = session("visible"), visibleClaude = session("visible", provider: .claude)
        var title = hidden.title, titleReads = 0, eventReads = 0
        var observations: [[AgentSession]] = []
        let store = try fixture(.init(catalog: { provider, _, _, _ in
            (provider == .codex ? [hidden, visibleCodex] : [visibleClaude], false)
        }, events: { _, _, _ in eventReads += 1; return [] }, titles: { _, _, _ in
            titleReads += 1; return [hidden.id: title]
        }), directory: root, now: { clock })
        defer { store.stop() }
        store.onObservation = { rows, _ in observations.append(rows) }
        await store.refresh(); try store.hide(hidden)
        XCTAssertEqual(store.activeCount, 2)
        let preserved = try Data(contentsOf: file)
        // Atomic replacement is controlled by the directory permissions, not
        // the destination file's write bit. Restore them before fixture teardown.
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        clock = clock.addingTimeInterval(20)
        title = "Renamed hidden fixture"
        visibleCodex.phase = .ready; visibleCodex.observedAt = clock
        visibleClaude.phase = .input; visibleClaude.observedAt = clock
        await store.refresh()
        await store.readEvents()
        XCTAssertEqual(eventReads, 3)
        XCTAssertEqual(titleReads, 2, "A failed metadata write must respect the normal title polling interval")
        XCTAssertEqual(store.updatedAt, clock)
        XCTAssertEqual(try Data(contentsOf: file), preserved)
        XCTAssertEqual(store.hiddenSessions.first?.title, hidden.title, "Unsaved titles must not be reported as persisted")
        let failure = try XCTUnwrap(store.connectionMessage, "The write failure remains visible")
        XCTAssertEqual(store.sessions.first { $0.id == visibleCodex.id }?.effectivePhase(now: clock), .ready)
        XCTAssertEqual(store.sessions.first { $0.id == visibleClaude.id }?.effectivePhase(now: clock), .input)
        XCTAssertEqual(observations.count, 3, "Activity and Keep Awake must still receive observations")
        XCTAssertEqual(observations.last?.first { $0.id == visibleCodex.id }?.phase, .ready)
        XCTAssertEqual(observations.last?.first { $0.id == visibleClaude.id }?.phase, .input)

        // Another operation may report the same generic text. Recovery must
        // clear only the title writer's own message, not that newer diagnostic.
        if replaceMessage { store.connectionMessage = failure }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        clock = clock.addingTimeInterval(20)
        await store.readEvents()
        XCTAssertEqual(titleReads, 3, "Saving is retried on the next title poll")
        XCTAssertEqual(eventReads, 4)
        XCTAssertEqual(observations.count, 4)
        XCTAssertEqual(try SessionVisibility(url: file).summaries.first?.title, title)
        XCTAssertEqual(store.hiddenSessions.first?.title, title)
        XCTAssertEqual(store.connectionMessage, replaceMessage ? failure : nil)
        await store.readEvents()
        XCTAssertEqual(titleReads, 3, "Successful recovery also retains the polling interval")
        XCTAssertTrue(store.typedIssues.isEmpty)
        XCTAssertTrue(store.diagnosticEntries.isEmpty)
        XCTAssertFalse(store.refreshing)
    }

    private func inertResolver() -> ClientExecutableResolver { .init(discoverCodex: { nil }, discoverClaude: { nil }) }
    private func session(_ id: String, provider: ProviderID = .codex) -> AgentSession {
        .init(provider: provider, sessionID: id, title: "Fixture " + id, cwd: "/fixture/project", phase: .running,
              updatedAt: instant, observedAt: instant, runtimeConfirmed: true)
    }
    private func fixture(_ dependencies: SessionStore.Dependencies = .init(), directory: URL? = nil, now: (() -> Date)? = nil) throws -> SessionStore {
        let suite = "SessionStoreLifecycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let instant = instant
        return SessionStore(directory: try directory ?? self.directory(), defaults: defaults, isolated: true, now: now ?? { instant }, dependencies: dependencies)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

extension SessionStoreLifecycleTests {
    func testDiscoveredNotLoadedPeersNeedIndependentActivityBeforeCountingAsWorking() async throws {
        let root = try directory().resolvingSymlinksInPath()
        let sessionsDirectory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let ids = (0..<5).map { _ in UUID().uuidString.lowercased() }
        var clock = instant
        let initialTime = instant.addingTimeInterval(-5)
        var rows: [[String: Any]] = []
        func event(_ kind: String, id: String, at date: Date) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date),
                "payload": ["type": kind, "thread_id": id, "turn_id": "fixture-turn"]]) + Data([10])
        }
        for (index, id) in ids.enumerated() {
            let path = sessionsDirectory.appendingPathComponent("rollout-" + id + ".jsonl")
            try event("item_completed", id: id, at: initialTime).write(to: path)
            rows.append(["id": id, "name": "Fixture peer \(index)", "preview": "", "cwd": "/fixture/worktree-\(index)",
                         "path": path.path, "status": ["type": "notLoaded"]])
        }
        let reader = CodexActivityReader(home: root, writerPaths: { _ in [] })
        let suite = "SessionDiscoveryIntegration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var sourceReads = Set<String>()
        let store = SessionStore(directory: root.appendingPathComponent("view-state"), defaults: defaults,
            isolated: true, now: { clock }, dependencies: .init(catalog: { _, _, _, _ in
                let response = try SessionProcess.readCodexCatalog(discovery: .init(ids: ids, isComplete: true), deadline: 12, uptime: { 0 }) { method, params, _ in
                    if method == "thread/list" { return ["data": [rows[0]], "nextCursor": NSNull()] }
                    let id = try XCTUnwrap(params["threadId"] as? String)
                    XCTAssertEqual(params["includeTurns"] as? Bool, false)
                    sourceReads.insert(id)
                    return ["thread": try XCTUnwrap(rows.first { $0["id"] as? String == id })]
                }
                XCTAssertTrue(response.sessions.allSatisfy { $0.phase == .unknown && $0.runtimeConfirmed == false })
                return (response.sessions, !response.isComplete)
            }, events: { catalog, _, time in await reader.events(catalog: catalog, now: time) }))
        store.useProviders([.codex])
        await store.refresh()
        XCTAssertEqual(sourceReads, Set(ids.dropFirst()))
        XCTAssertEqual(Set(store.sessions.map(\.sessionID)), Set(ids))
        XCTAssertEqual(store.activeCount, 5)
        XCTAssertEqual(SessionList.filter(store.sessions, query: "", provider: nil, activeOnly: false, now: clock).count, 5)
        XCTAssertTrue(store.sessions.allSatisfy { $0.evidence == .localEvent })

        let completedPath = sessionsDirectory.appendingPathComponent("rollout-" + ids[1] + ".jsonl")
        let writer = try FileHandle(forWritingTo: completedPath)
        try writer.seekToEnd(); try writer.write(contentsOf: event("task_complete", id: ids[1], at: clock)); try writer.close()
        await store.refresh()
        XCTAssertEqual(store.sessions.first { $0.sessionID == ids[1] }?.effectivePhase(now: clock), .ready)
        XCTAssertEqual(store.activeCount, 4)

        clock = clock.addingTimeInterval(180)
        await store.refresh()
        XCTAssertEqual(store.activeCount, 0, "Catalog rediscovery cannot refresh stale running events without a writable owner")
        XCTAssertEqual(store.sessions.count, 5)
        store.stop()
    }
}


extension SessionStoreLifecycleTests {
    func testNewCatalogStartsFreshEventsBeforeAnOldPollCanFinish() async throws {
        let oldStarted = expectation(description: "Old catalog events held")
        let freshStarted = expectation(description: "New catalog events start without waiting for old poll")
        var releaseOld: CheckedContinuation<Void, Never>?
        var catalogCalls = 0, eventCalls = 0, freshDidStart = false
        let rows = (0..<5).map { session("peer-\($0)") }
        var observations: [[String]] = []
        let store = try fixture(.init(catalog: { _, _, _, _ in
            catalogCalls += 1
            return (catalogCalls == 1 ? [rows[0]] : rows, false)
        }, events: { catalog, _, _ in
            eventCalls += 1
            if eventCalls == 2 {
                XCTAssertEqual(catalog.map(\.sessionID), [rows[0].sessionID])
                await withCheckedContinuation { releaseOld = $0; oldStarted.fulfill() }
            } else if eventCalls == 3 {
                XCTAssertEqual(Set(catalog.map(\.sessionID)), Set(rows.map(\.sessionID)))
                freshDidStart = true; freshStarted.fulfill()
            }
            return []
        }))
        store.useProviders([.codex])
        store.onObservation = { observed, _ in observations.append(observed.map(\.sessionID)) }
        await store.refresh()
        let oldPoll = Task { await store.readEvents() }
        await fulfillment(of: [oldStarted], timeout: 2)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [freshStarted], timeout: 2)
        // Always release the fixture on failure as well, so a broken implementation
        // reports assertions instead of hanging the test process.
        if freshDidStart {
            await refresh.value
            XCTAssertEqual(store.activeCount, 5)
        }
        releaseOld?.resume(); await oldPoll.value; await refresh.value
        XCTAssertTrue(freshDidStart)
        XCTAssertEqual(eventCalls, 3)
        XCTAssertEqual(Set(store.sessions.map(\.sessionID)), Set(rows.map(\.sessionID)))
        XCTAssertEqual(observations.map(\.count), [1, 5], "The superseded one-row poll must never publish after replacement")
        XCTAssertFalse(store.refreshing)
        store.stop()
    }

    func testNewCatalogRejectsLateTitlesWithoutRewritingHiddenMetadata() async throws {
        let oldStarted = expectation(description: "Old title lookup held")
        let freshStarted = expectation(description: "New title lookup starts independently")
        var releaseOld: CheckedContinuation<Void, Never>?
        var catalogCalls = 0, titleCalls = 0, freshDidStart = false, clock = instant
        let rows = (0..<5).map { session("peer-\($0)") }
        let directory = try directory()
        let store = try fixture(.init(catalog: { _, _, _, _ in
            catalogCalls += 1
            return (catalogCalls == 1 ? [rows[0]] : rows, false)
        }, titles: { _, _, _ in
            titleCalls += 1
            if titleCalls == 2 {
                await withCheckedContinuation { releaseOld = $0; oldStarted.fulfill() }
                return [rows[0].id: "Stale title"]
            }
            if titleCalls == 3 { freshDidStart = true; freshStarted.fulfill(); return [rows[0].id: "Current title"] }
            return [:]
        }), directory: directory, now: { clock })
        store.useProviders([.codex]); await store.refresh(); try store.hide(rows[0])
        clock = clock.addingTimeInterval(20)
        let oldPoll = Task { await store.readEvents() }
        await fulfillment(of: [oldStarted], timeout: 2)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [freshStarted], timeout: 2)
        var acceptedFile: Data?
        if freshDidStart {
            await refresh.value
            XCTAssertEqual(store.hiddenSessions.first?.title, "Current title")
            acceptedFile = try Data(contentsOf: directory.appendingPathComponent("hidden-sessions.json"))
        }
        releaseOld?.resume(); await oldPoll.value; await refresh.value
        XCTAssertTrue(freshDidStart)
        XCTAssertEqual(titleCalls, 3)
        XCTAssertEqual(store.hiddenSessions.first?.title, "Current title")
        if let acceptedFile { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("hidden-sessions.json")), acceptedFile) }
        XCTAssertEqual(store.sessions.count, 4, "Only the explicitly hidden peer is excluded")
        XCTAssertTrue(store.diagnosticEntries.isEmpty)
        store.stop()
    }
}
