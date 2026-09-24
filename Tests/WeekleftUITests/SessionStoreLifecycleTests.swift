import XCTest
import Combine
@testable import Weekleft
@testable import WeekleftCore

@MainActor final class SessionStoreLifecycleTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testNestedClaudeWaitStaysExcludedAcrossCatalogGapsAndAllowsIndependentResume() async throws {
        var clock = instant
        var child = session("child"); child.phase = .input; child.provider = .claude; child.isNestedClaudeSession = true
        var parent = session("parent"), peer = session("peer"); parent.provider = .claude; peer.provider = .claude
        var catalog = [parent, peer, child]
        var hook = child; hook.isNestedClaudeSession = nil; hook.evidence = .hook
        let root = try directory()
        var visibility = try SessionVisibility(url: root.appendingPathComponent("hidden-sessions.json"), now: clock)
        try visibility.hide(child, now: clock.addingTimeInterval(-1))
        try visibility.hide(peer, now: clock)
        var observed: [[String]] = [], published: [[String]] = []
        let store = try fixture(.init(catalog: { _, _, _, _ in (catalog, false) }, events: { _, _, _ in [hook] }), directory: root, now: { clock })
        defer { store.stop() }
        store.useProviders([.claude])
        store.autoHideMinutes = 5
        store.onObservation = { rows, _ in observed.append(rows.map(\.sessionID)) }
        let subscriber = store.observations.sink { published.append($0.rows.map(\.sessionID)) }
        defer { subscriber.cancel() }
        await store.refresh()
        XCTAssertEqual(store.currentSessions.map(\.sessionID), ["parent"])
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertEqual(store.hiddenIDs, [peer.id], "Repair only internal-agent history, preserving a deliberately hidden peer")
        clock += 1
        catalog = [parent, peer]
        hook.observedAt = clock; hook.updatedAt = clock
        await store.refresh()
        XCTAssertEqual(store.currentSessions.map(\.sessionID), ["parent"], "A temporarily absent catalog cannot reintroduce a known child's hook")
        XCTAssertTrue(observed.allSatisfy { !$0.contains("child") }, "Internal waits cannot reach activity tracking or Keep Awake")
        XCTAssertTrue(published.allSatisfy { !$0.contains("child") }, "Internal waits cannot trigger user notifications")
        XCTAssertEqual(store.hiddenIDs, [peer.id])
        child.isNestedClaudeSession = false; child.phase = .running
        clock += 1; child.observedAt = clock; child.updatedAt = clock
        child.evidence = .hook; child.turnStartedAt = clock; child.hasTaskActivity = true
        store.acceptSessions([parent, child], now: clock)
        XCTAssertTrue(store.currentSessions.contains { $0.sessionID == "child" }, "An explicitly independent resume becomes visible")
    }

    func testSubagentWaitDoesNotReachPanelCountsObservationsOrHiddenHistory() async throws {
        var clock = instant
        var child = session("child"); child.phase = .input; child.isCodexSubagent = true
        let parent = session("parent"), peer = session("peer")
        var catalog = [parent, peer, child]
        var hook = child; hook.isCodexSubagent = nil; hook.evidence = .hook
        let root = try directory()
        var visibility = try SessionVisibility(url: root.appendingPathComponent("hidden-sessions.json"), now: clock)
        try visibility.hide(child, now: clock.addingTimeInterval(-1))
        try visibility.hide(peer, now: clock)
        var observed: [[String]] = [], published: [[String]] = []
        let store = try fixture(.init(catalog: { _, _, _, _ in (catalog, false) }, events: { _, _, _ in [hook] }), directory: root, now: { clock })
        defer { store.stop() }
        store.useProviders([.codex])
        store.autoHideMinutes = 5
        store.onObservation = { rows, _ in observed.append(rows.map(\.sessionID)) }
        let subscriber = store.observations.sink { published.append($0.rows.map(\.sessionID)) }
        defer { subscriber.cancel() }
        await store.refresh()
        XCTAssertEqual(store.currentSessions.map(\.sessionID), ["parent"])
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertEqual(store.hiddenIDs, [peer.id], "Repair only internal-agent history, preserving a deliberately hidden peer")
        clock += 1
        catalog = [parent, peer]
        hook.observedAt = clock; hook.updatedAt = clock
        await store.refresh()
        XCTAssertEqual(store.currentSessions.map(\.sessionID), ["parent"], "A temporarily absent catalog cannot reintroduce a known child's hook")
        XCTAssertTrue(observed.allSatisfy { !$0.contains("child") }, "Internal waits cannot reach activity tracking or Keep Awake")
        XCTAssertTrue(published.allSatisfy { !$0.contains("child") }, "Internal waits cannot trigger user notifications")
        XCTAssertEqual(store.hiddenIDs, [peer.id])
    }

    func testInternalCodexAgentIsNeverReadBackAsAKnownActiveSession() async throws {
        var clock = instant
        var memory = session("memory"), task = session("task")
        memory.evidence = .hook; memory.isCodexSubagent = true; task.evidence = .hook
        var requested: [[String]] = []
        let store = try fixture(.init(catalog: { provider, _, _, priority in
            if provider == .codex { requested.append(priority) }
            return ([], false)
        }, events: { _, _, _ in [memory, task] }), now: { clock })
        defer { store.stop() }
        store.useProviders([.codex])
        await store.refresh()
        clock += 1
        memory.observedAt = clock; memory.updatedAt = clock; task.observedAt = clock; task.updatedAt = clock
        await store.refresh()
        XCTAssertEqual(requested.last, ["task"], "An internal agent is never read back, so it cannot make the catalog incomplete")
        XCTAssertEqual(store.currentSessions.map(\.sessionID), ["task"])
    }

    func testWaitingPublicationExpiresDespiteFailedEventReadsAndRecovers() async throws {
        var clock = instant
        var fails = true
        var row = session("waiting")
        row.phase = .permission
        let store = try fixture(.init(events: { _, _, _ in
            if fails { throw SessionError.timeout }
            return [row]
        }), now: { clock })
        defer { store.stop() }
        var waiting = 0
        let observer = store.$sessions.sink { rows in
            waiting = rows.filter { $0.isCurrent(now: clock) && [.permission, .input].contains($0.effectivePhase(now: clock)) }.count
        }
        defer { observer.cancel() }
        store.acceptSessions([row])
        XCTAssertEqual(waiting, 1)
        clock += 30
        await store.readEvents()
        XCTAssertEqual(waiting, 1, "One read failure cannot discard still-current evidence")
        clock += 31
        await store.readEvents()
        XCTAssertEqual(waiting, 0, "The menu-bar subscriber must expire without opening the panel or a successful read")
        XCTAssertTrue(store.currentSessions.isEmpty)
        XCTAssertEqual(store.sessions.map(\.id), [row.id], "Expiring status does not delete the task")
        fails = false; row.observedAt = clock; row.updatedAt = clock
        await store.readEvents()
        XCTAssertEqual(waiting, 1, "Fresh evidence can confirm a real wait again")
    }

    func testPendingEventReadDoesNotBlockWaitingExpiryOrDuplicateWork() async throws {
        var clock = instant
        var row = session("pending-wait")
        row.phase = .input; row.evidence = .hook
        let began = expectation(description: "Event read pending")
        let polled = expectation(description: "Second background poll")
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0, waiting = 0
        let store = try fixture(.init(events: { _, _, _ in
            calls += 1
            await withCheckedContinuation { resume = $0; began.fulfill() }
            return [row]
        }), now: { clock })
        defer { store.stop() }
        let observer = store.$sessions.sink { rows in
            waiting = rows.filter { $0.isCurrent(now: clock) && $0.effectivePhase(now: clock) == .input }.count
        }
        defer { observer.cancel() }
        store.acceptSessions([row])
        let first = Task { await store.readEvents() }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(waiting, 1)
        clock += 601
        let second = Task { polled.fulfill(); await store.readEvents() }
        await fulfillment(of: [polled], timeout: 2)
        XCTAssertEqual(waiting, 0, "Expiry must not wait for the outstanding source operation")
        XCTAssertEqual(calls, 1, "Background ticks still coalesce the pending source operation")
        resume?.resume()
        await first.value; await second.value
        XCTAssertEqual(waiting, 0, "A late result cannot renew its own observation timestamp")
    }

    func testResumedClaudeWorkCannotResurrectEarlierClosingQuestion() async throws {
        var clock = instant
        let payload: [String: Any] = ["session_id": "claude-resumed", "hook_event_name": "Stop",
                                      "last_assistant_message": "Делаем все пять?"]
        var question = try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude,
            previous: nil, now: instant).session
        var phase = SessionPhase.idle
        var present = true
        let store = try fixture(.init(catalog: { _, _, _, _ in
            let row = AgentSession(provider: .claude, sessionID: "claude-resumed", title: "Fixture", cwd: "/fixture",
                phase: phase, updatedAt: clock, observedAt: clock, runtimeConfirmed: true)
            return (present ? [row] : [], false)
        }, events: { _, _, _ in [question] }), now: { clock })
        store.useProviders([.claude])
        await store.refresh()
        XCTAssertEqual(store.currentSessions.first?.phase, .input)
        clock += 15; phase = .running
        await store.refresh()
        XCTAssertEqual(store.currentSessions.first?.phase, .running)
        clock += 15; phase = .idle
        await store.refresh()
        XCTAssertFalse(store.currentSessions.contains { $0.phase == .input }, "An old Stop must not revive after confirmed new work")
        clock += 15; present = false
        await store.refresh()
        XCTAssertFalse(store.currentSessions.contains { $0.phase == .input }, "A missing catalog row cannot revive the answered question either")
        clock += 15; present = true
        question = try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude,
            previous: nil, now: clock).session
        await store.refresh()
        XCTAssertEqual(store.currentSessions.first?.phase, .input, "A genuinely new closing question still needs attention")
        store.stop()
    }

    func testDailyCheckExpiresOnlyHiddenSessionsAbsentFromACompleteCatalog() async throws {
        let root = try directory(), longAgo = instant.addingTimeInterval(-40 * 86400)
        var listed = session("listed", provider: .claude), gone = listed
        gone.sessionID = "gone"; gone.observedAt = longAgo; gone.updatedAt = longAgo
        var visibility = try SessionVisibility(url: root.appendingPathComponent("hidden-sessions.json"), now: longAgo)
        try visibility.hide(listed, now: longAgo)
        try visibility.hide(gone, now: longAgo)
        listed.phase = .idle
        var clock = instant, catalogFails = true
        let store = try fixture(.init(catalog: { _, _, _, _ in
            if catalogFails { throw SessionError.timeout }
            return ([listed], false)
        }), directory: root, now: { clock })
        defer { store.stop() }
        store.useProviders([.claude])
        await store.refresh()
        XCTAssertEqual(store.hiddenIDs, [gone.id, listed.id].sorted(), "A failed catalog cannot prove that a session is gone")
        clock += 86400; catalogFails = false
        await store.refresh()
        XCTAssertEqual(store.hiddenIDs, [listed.id], "A session the catalog still lists stays hidden")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(try SessionVisibility(url: root.appendingPathComponent("hidden-sessions.json"), now: clock).hidden, [listed.id])
    }

    func testPrecancelledRefreshDoesNotStartAnyDependency() async throws {
        var calls = 0
        let store = try fixture(.init(catalog: { _, _, _, _ in calls += 1; return ([], false) },
                                      events: { _, _, _ in calls += 1; return [] },
                                      titles: { _, _, _ in calls += 1; return [:] },
                                      hooksState: { XCTFail("No dependency may start"); return [:] }))
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

    func testCancellingOneOfTwoWaitersKeepsTheSharedRefresh() async throws {
        for cancelFirst in [false, true] {
            let began = expectation(description: "Catalog pending")
            var resume: CheckedContinuation<Void, Never>?
            var catalogCancelled = false
            let row = session("shared")
            let store = try fixture(.init(catalog: { _, _, _, _ in
                await withCheckedContinuation { resume = $0; began.fulfill() }
                catalogCancelled = Task.isCancelled
                return ([row], false)
            }))
            store.useProviders([.codex])
            let first = Task { await store.refresh() }
            await fulfillment(of: [began], timeout: 2)
            let joined = Task { await store.refresh() }
            for _ in 0..<10 { await Task.yield() }
            (cancelFirst ? first : joined).cancel()
            for _ in 0..<10 { await Task.yield() }
            resume?.resume()
            await first.value; await joined.value
            XCTAssertFalse(catalogCancelled, "Another caller still waits for this refresh")
            XCTAssertEqual(store.sessions.map(\.sessionID), ["shared"])
            XCTAssertEqual(store.updatedAt, instant)
            XCTAssertFalse(store.refreshing)
            store.stop()
        }
    }

    func testSourceChangeDuringAReadSchedulesExactlyOneMoreRead() async throws {
        let began = expectation(description: "First read pending"), followUp = expectation(description: "Follow-up read")
        var resume: CheckedContinuation<Void, Never>?
        var reads = 0
        let store = try fixture(.init(events: { _, _, _ in
            reads += 1
            if reads == 1 { await withCheckedContinuation { resume = $0; began.fulfill() } }
            if reads == 2 { followUp.fulfill() }
            return []
        }))
        defer { store.stop() }
        store.useProviders([.codex])
        let request = Task { await store.readEvents() }
        await fulfillment(of: [began], timeout: 2)
        store.sourceChanged(); store.sourceChanged()
        resume?.resume(); await request.value
        await fulfillment(of: [followUp], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 2, "Changes during one read coalesce into a single follow-up")
        store.sourceChanged()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 3, "A change with no read in progress starts one directly")
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
