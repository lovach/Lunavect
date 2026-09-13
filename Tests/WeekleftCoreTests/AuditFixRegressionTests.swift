import XCTest
import Darwin
@testable import WeekleftCore

/// Regression checks for the 2026-09-13 independent audit. Each case failed before its fix.
final class AuditFixRegressionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func running(_ date: Date, id: String = "clock-fixture") -> AgentSession {
        AgentSession(provider: .codex, sessionID: id, title: "Fixture", cwd: "/fixture", phase: .running,
                     updatedAt: date, observedAt: date, runtimeConfirmed: true)
    }

    // A-02: history written while the clock was ahead must not block a new tracker.
    func testNewTrackerRecordsWorkAfterClockMovedBackBetweenLaunches() throws {
        var first = ActivityTracker()
        let ahead = base.addingTimeInterval(3600)
        first.observe([running(ahead)], now: ahead)
        first.observe([running(ahead.addingTimeInterval(5))], now: ahead.addingTimeInterval(5))
        let saved = try JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(first.history))
        var restarted = ActivityTracker(history: saved)
        restarted.observe([running(base)], now: base)
        restarted.observe([running(base.addingTimeInterval(5))], now: base.addingTimeInterval(5))
        XCTAssertEqual(restarted.history.summary(now: base.addingTimeInterval(5)).totals.active, 5)
    }

    // A-05: a Desktop route does not depend on the generated title.
    func testDesktopRouteSurvivesMissingTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditMetadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("account/workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("local_audit-route.json")
        for title in ["Named", "", "   "] {
            try JSONSerialization.data(withJSONObject: ["cliSessionId": "audit-id", "isArchived": false, "title": title]).write(to: file)
            XCTAssertEqual(ClaudeSessionMetadata.records(for: ["audit-id"], at: root)["audit-id"]?.desktopID, "local_audit-route")
            XCTAssertEqual(ClaudeSessionMetadata.titles(for: ["audit-id"], at: root)["audit-id"], title == "Named" ? "Named" : nil)
        }
        try JSONSerialization.data(withJSONObject: ["cliSessionId": "audit-id", "isArchived": true, "title": "Named"]).write(to: file)
        XCTAssertNil(ClaudeSessionMetadata.records(for: ["audit-id"], at: root)["audit-id"], "Archived sessions stay excluded")
    }

    // F-11: a live row without a title keeps the name recorded earlier.
    func testUntitledObservationKeepsKnownActivityTitle() {
        var details = ActivityDetails()
        let titled = AgentSession(provider: .claude, sessionID: "abc", title: "Known title", cwd: "/p", phase: .running,
                                  updatedAt: base, observedAt: base, evidence: .localEvent, runtimeConfirmed: true)
        var untitled = titled; untitled.title = ""
        details.append(titled, start: base, end: base.addingTimeInterval(2))
        details.append(untitled, start: base.addingTimeInterval(2), end: base.addingTimeInterval(4))
        XCTAssertEqual(details.records.values.first?.title, "Known title")
        var renamed = titled; renamed.title = "New title"
        details.append(renamed, start: base.addingTimeInterval(4), end: base.addingTimeInterval(6))
        XCTAssertEqual(details.records.values.first?.title, "New title")
    }

    // F-12: a day whose midnight is skipped by DST has 23 hour points.
    func testDayWithoutMidnightHasTwentyThreeHourPoints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let work = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T15:00:00Z"))
        var history = ActivityHistory()
        history.append(start: work, end: work.addingTimeInterval(3600), providers: 1, observedProviders: 1)
        let day = history.summary(now: work.addingTimeInterval(7200), calendar: calendar, period: .day)
        XCTAssertEqual(day.points.count, 23)
        XCTAssertEqual(day.totals.active, 3600)
    }

    // F-05: Claude installed through a Node version manager is discovered and can find its Node.
    func testClaudeDiscoveryFindsNodeManagerInstallAndPassesItsDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AuditClaude-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var expected = ""
        for version in ["v9.11.0", "v24.1.0", "v22.3.0"] {
            let bin = home.appendingPathComponent(".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let claude = bin.appendingPathComponent("claude")
            try Data("#!/bin/sh\n".utf8).write(to: claude)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
            if version == "v24.1.0" { expected = claude.path }
        }
        XCTAssertEqual(SessionSources.discoverClaude(home: home.path, systemDirectories: []), expected)
        let environment = SessionSources.environment(forExecutable: expected, base: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(environment["PATH"], URL(fileURLWithPath: expected).deletingLastPathComponent().path + ":/usr/bin:/bin")
    }

    // A-04: a manually selected Codex executable can confirm a silent turn's writer.
    func testSelectedExecutableConfirmsLiveWriter() async throws {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        XCTAssertGreaterThan(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)), 0)
        let selfExecutable = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        let now = Date()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AuditRuntime-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions/2026/09/13")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "11111111-2222-3333-4444-555555555555"
        let file = directory.appendingPathComponent("rollout-2026-09-13T10-00-00-\(id).jsonl")
        let record: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-180)),
                                     "payload": ["type": "task_started", "turn_id": "fixture-turn", "thread_id": id]]
        try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: file)
        // This test process plays the selected client: it holds the log open for writing.
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        XCTAssertFalse(CodexRuntimeReader.writablePaths([file.path]).contains(file.path), "Not an automatically discovered client")
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: selfExecutable), [file.path])
        var row = AgentSession(provider: .codex, sessionID: id, title: "Fixture", cwd: "/fixture", phase: .unknown,
                               updatedAt: now, observedAt: now, runtimeConfirmed: false)
        row.activityPath = file.path
        let reader = CodexActivityReader(home: home)
        await reader.useExecutable(selfExecutable)
        let observed = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(observed.first?.effectivePhase(now: now), .running)
    }
}
