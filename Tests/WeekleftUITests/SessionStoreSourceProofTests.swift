import XCTest
import Combine
@testable import Weekleft
@testable import WeekleftCore

/// What the store accepts as proof about sessions: hook records spooled while the
/// app was closed (scenario L4) and the S-13 rule that ends a dead client's turn.
/// Temporary folders, injected liveness and clocks only.
@MainActor final class SessionStoreSourceProofTests: XCTestCase {
    private func capture(_ id: String, _ name: String, _ extra: [String: Any] = [:], at root: URL) throws {
        var payload: [String: Any] = ["session_id": id, "hook_event_name": name, "cwd": "/Users/fixture/Projects/" + id]
        payload.merge(extra) { $1 }
        try SessionHooks.capture(JSONSerialization.data(withJSONObject: payload), provider: .claude, at: root, client: .terminal,
                                 runtimePID: 4242, isInternal: { _ in false }, isAlive: { _ in true })
    }

    func testRecordsWrittenWhileTheAppWasClosedAreReadOnceWithoutHistoricalNotices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-S-" + UUID().uuidString, isDirectory: true)
        let suite = "Lunavect.HookSpool." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        // While the app is closed: one reply finished, another task still works.
        try capture("finished", "UserPromptSubmit", at: root)
        try capture("finished", "Stop", ["last_assistant_message": "Done."], at: root)
        try capture("working", "UserPromptSubmit", at: root)

        let store = SessionStore(directory: root, defaults: defaults, isolated: false,
                                 dependencies: .init(events: { _, _, _ in SessionHooks.load(at: root) },
                                                     initialEvents: { SessionHooks.load(at: $0) }))
        defer { store.stop() }
        store.useProviders([.claude])
        var tracker = SessionNoticeTracker(), notices: [String] = []
        let subscriber = store.observations.sink { observation in
            notices += tracker.update(observation.rows, now: observation.date).map { $0.session.sessionID + ":" + $0.kind.rawValue }
        }
        defer { subscriber.cancel() }

        await store.readEvents()
        XCTAssertEqual(Set(store.sessions.map(\.sessionID)), ["finished", "working"])
        XCTAssertEqual(store.sessions.first { $0.sessionID == "finished" }?.phase, .ready)
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertEqual(notices, [], "A reply that finished while Lunavect was closed is history, not a notice")
        await store.readEvents()
        XCTAssertEqual(store.sessions.count, 2, "Reading the spool again creates no second row")
        XCTAssertEqual(notices, [])

        try capture("working", "Stop", ["last_assistant_message": "Done."], at: root)
        await store.readEvents()
        await store.readEvents()
        XCTAssertEqual(notices, ["working:completed"], "The first live transition after launch is announced once")
        let records = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") && $0.hasPrefix("claude-") }
        XCTAssertEqual(Set(records), ["claude-finished.json", "claude-working.json"])
    }

    /// Docs: "a failed or partial list … keep[s] the ordinary freshness limits". After a
    /// failed read the last complete listing is older than a session started since, so
    /// its absence there proves nothing (mutation M10 of the r2 audit survived before).
    func testAFailedClaudeCatalogReadCannotEndAnUnlistedSessionAsStopped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-S-" + UUID().uuidString, isDirectory: true)
        let suite = "Lunavect.SourceProof." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000), fails = false, alive = true
        let other = AgentSession(provider: .claude, sessionID: "other", title: "Other", cwd: "/fixture/other", phase: .idle,
                                 updatedAt: clock, observedAt: clock, runtimeConfirmed: true)
        var hook = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "started-later", "hook_event_name": "UserPromptSubmit", "cwd": "/fixture/later"]),
            provider: .claude, previous: nil, now: clock.addingTimeInterval(5), client: .terminal).session
        hook.runtimePID = 4242
        let store = SessionStore(directory: root, defaults: defaults, isolated: true, now: { clock }, dependencies: .init(
            catalog: { _, _, _, _ in
                if fails { throw SessionError.timeout }
                return ([other].map { var row = $0; row.observedAt = clock; return row }, false)
            },
            events: { _, _, _ in [hook] }, isProcessAlive: { _ in alive }))
        defer { store.stop() }
        store.useProviders([.claude])
        await store.refresh()
        XCTAssertEqual(store.sessions.first { $0.sessionID == "started-later" }?.phase, .running)
        clock += 15; fails = true; alive = false
        await store.refresh()
        XCTAssertNotNil(store.typedIssues[.claude], "Precondition: the read failed")
        XCTAssertEqual(store.sessions.first { $0.sessionID == "started-later" }?.phase, .running,
                       "A failed read keeps the ordinary freshness rule")
        clock += 15; fails = false
        await store.refresh()
        XCTAssertEqual(store.sessions.first { $0.sessionID == "started-later" }?.phase, .interrupted,
                       "A complete listing without the session, plus a gone client, ends the turn")
    }
}
