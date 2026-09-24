import XCTest
import os
@testable import Weekleft
@testable import WeekleftCore

/// Store-level regression checks for the 2026-09-13 independent audit.
@MainActor final class AuditFixStoreRegressionTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    // F-09: one failed catalog poll keeps confirmed rows until their own lifetime ends.
    func testSingleCatalogFailureDoesNotBlankSessionList() async throws {
        var clock = instant, calls = 0
        func row(_ id: String, _ phase: SessionPhase) -> AgentSession {
            AgentSession(provider: .codex, sessionID: id, title: "Fixture " + id, cwd: "/fixture/" + id, client: .terminal,
                         phase: phase, updatedAt: clock.addingTimeInterval(-30), observedAt: clock, evidence: .catalog, runtimeConfirmed: true)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AuditStore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, isolated: true, now: { clock }, dependencies: .init(catalog: { _, _, _, _ in
            calls += 1
            if calls == 1 { return ([row("a", .idle), row("b", .running)], false) }
            throw SessionError.timeout
        }))
        defer { store.stop() }
        store.useProviders([.codex])
        await store.refresh()
        XCTAssertEqual(store.currentSessions.count, 2)
        clock += 15
        await store.refresh()
        XCTAssertEqual(store.currentSessions.count, 2, "A timeout is not evidence that sessions ended")
        XCTAssertNotNil(store.issues[.codex], "The failure remains visible as a provider issue")
        clock += 50
        await store.refresh()
        XCTAssertEqual(store.currentSessions.count, 0, "Unconfirmed observations still expire")
    }

    // A-01: a delayed refresh result cannot replace a newer local Claude observation.
    func testDelayedRefreshDoesNotRollBackNewerClaudeObservation() async throws {
        let now = instant
        let initial = try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600)),
                                        fetchedAt: now.addingTimeInterval(-60), source: "Claude Code statusLine")
        let newer = try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 20, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600)),
                                      fetchedAt: now, source: "Claude Code statusLine")
        let suite = "AuditFix." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var localTick: (@MainActor @Sendable () -> Void)?
        var gate: CheckedContinuation<Void, Never>?
        let codexStarted = expectation(description: "Codex pending"), claudeReturned = expectation(description: "Claude fallback returned")
        let localRead = expectation(description: "Newer local observation")
        let persistence = SnapshotPersistence(url: URL(fileURLWithPath: "/unused/audit.json"), write: { _, _ in XCTFail("No writes") }, reload: {})
        let scheduling = AppRefreshScheduling(repeating: { interval, action in
            if interval == 5 { localTick = action }
            return {}
        }, wake: { _ in {} })
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex, .claude]
        let services = AppDataServices(snapshots: persistence, activity: ActivityService(isolated: true), clock: { now }, localQuota: { _ in
            localRead.fulfill(); return newer
        }, refreshQuota: { id, _, _ in
            if id == .claude {
                let fallback = try await ClaudeProvider.refresh(force: false, now: now, cached: { initial },
                    probe: { throw UsageError.claudeUsageUnavailable }, save: { _ in XCTFail("A failed probe must not save") })
                claudeReturned.fulfill(); return fallback
            }
            await withCheckedContinuation { gate = $0; codexStarted.fulfill() }
            return UsageSnapshot(provider: .codex, fetchedAt: now, source: "Codex CLI")
        }, scheduling: scheduling, discoverCodex: { nil })
        let store = AppStore(state: .init(snapshots: [initial], preferences: preferences), savesChanges: false,
                             network: NetworkConnection(makeMonitor: { nil }), defaults: defaults, dataServices: services)
        store.start()
        await fulfillment(of: [codexStarted, claudeReturned], timeout: 3)
        localTick?()
        await fulfillment(of: [localRead], timeout: 3)
        for _ in 0..<100 where store.snapshots.first(where: { $0.provider == .claude })?.weekly?.usedPercent != 20 { await Task.yield() }
        gate?.resume()
        for _ in 0..<1000 where store.refreshing { await Task.yield() }
        XCTAssertFalse(store.refreshing)
        let final = try XCTUnwrap(store.snapshots.first(where: { $0.provider == .claude }))
        XCTAssertEqual(final.weekly?.usedPercent, 20)
        XCTAssertEqual(final.fetchedAt, now)
        store.stop()
    }

    // 2026-09-24 A-08: building resolvers for rows does not probe the environment.
    func testResolverDiscoversCodexOnlyWhenResolvedAndKeepsTheChosenPath() throws {
        let discoveries = OSAllocatedUnfairLock(initialState: 0)
        let suite = "AuditFix." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = AppDataServices(snapshots: SnapshotPersistence(url: URL(fileURLWithPath: "/unused/audit.json"), write: { _, _ in }, reload: {}),
                                       activity: ActivityService(isolated: true), scheduling: AppRefreshScheduling(repeating: { _, _ in {} }, wake: { _ in {} }),
                                       discoverCodex: { discoveries.withLock { $0 += 1 }; return "/bin/echo" })
        // Explicit preferences: no connection migration reads client configuration.
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let store = AppStore(state: .init(snapshots: [], preferences: preferences), savesChanges: false,
                             network: NetworkConnection(makeMonitor: { nil }), defaults: defaults, dataServices: services)
        for _ in 0..<50 { _ = store.clientResolver }
        XCTAssertEqual(discoveries.withLock { $0 }, 0, "Rendering rows must not run discovery")
        XCTAssertEqual(try store.clientResolver.resolve(.codex), "/bin/echo")
        XCTAssertEqual(discoveries.withLock { $0 }, 1)
        store.codexPath = "/bin/cat"
        XCTAssertEqual(try store.clientResolver.resolve(.codex), "/bin/cat", "A selected client still wins")
        XCTAssertEqual(discoveries.withLock { $0 }, 1)
    }

    // 2026-09-24 A-08: an unchanged hook state does not invalidate views on every poll.
    func testUnchangedHookStateIsNotRepublishedOnEachPoll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AuditStore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = OSAllocatedUnfairLock(initialState: true)
        let store = SessionStore(directory: directory, isolated: true, now: { self.instant },
                                 dependencies: .init(hooksState: { [.claude: installed.withLock { $0 }] }))
        defer { store.stop() }
        store.useProviders([.claude])
        var published: [[ProviderID: Bool]] = []
        let observer = store.$hooksInstalled.dropFirst().sink { published.append($0) }
        defer { observer.cancel() }
        for _ in 0..<3 { await store.refresh() }
        XCTAssertEqual(published, [[.claude: true]])
        installed.withLock { $0 = false }
        await store.refresh()
        XCTAssertEqual(published, [[.claude: true], [.claude: false]], "A real change is still published")
    }
}
