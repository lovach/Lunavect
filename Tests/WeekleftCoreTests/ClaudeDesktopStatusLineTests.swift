import XCTest
@testable import WeekleftCore

/// Q-07: in Claude Desktop the status line never runs, so its quota file ages
/// while hooks keep working. That is explained, not reported as a fault.
final class ClaudeDesktopStatusLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(_ client: SessionClient, _ provider: ProviderID = .claude, updatedAgo: TimeInterval) -> AgentSession {
        AgentSession(provider: provider, sessionID: UUID().uuidString, title: "Fixture", cwd: "/fixture", client: client,
                     phase: .ready, updatedAt: now.addingTimeInterval(-updatedAgo), observedAt: now, evidence: .hook)
    }

    func testOnlyDesktopSessionsNewerThanTheStatusLineAreRecognized() {
        let desktop = [row(.desktop, updatedAgo: 3600), row(.desktop, updatedAgo: 600), row(.terminal, .codex, updatedAgo: 60)]
        let fourDaysAgo = now.addingTimeInterval(-4 * 86400)
        XCTAssertTrue(ClaudeStatusLineReach.onlyDesktopSessions(desktop, statusLineObservedAt: fourDaysAgo, now: now))
        XCTAssertTrue(ClaudeStatusLineReach.onlyDesktopSessions(desktop, statusLineObservedAt: nil, now: now), "Never received")
        XCTAssertFalse(ClaudeStatusLineReach.onlyDesktopSessions(desktop, statusLineObservedAt: now.addingTimeInterval(-60), now: now),
                       "The status line reported after the newest session")
        XCTAssertFalse(ClaudeStatusLineReach.onlyDesktopSessions(desktop + [row(.terminal, updatedAgo: 1800)], statusLineObservedAt: fourDaysAgo, now: now),
                       "A terminal session should have run the status line")
        XCTAssertFalse(ClaudeStatusLineReach.onlyDesktopSessions([row(.desktop, updatedAgo: 7 * 3600)], statusLineObservedAt: fourDaysAgo, now: now),
                       "Nothing recent to explain")
        XCTAssertFalse(ClaudeStatusLineReach.onlyDesktopSessions([], statusLineObservedAt: fourDaysAgo, now: now))
    }

    func testDesktopOnlyIsANoteNotAnEventsFault() throws {
        let probe = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now.addingTimeInterval(-60), source: ClaudeUsageProbe.source)
        let diagnostic = ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                                              snapshot: probe, sessionIssue: nil, now: now, statusLineDesktopOnly: true)
        XCTAssertEqual(diagnostic.state, .ready)
        XCTAssertNil(diagnostic.repair)
        XCTAssertEqual(diagnostic.note, "Статусная строка не работает в Claude Desktop; лимиты обновляются через /usage")
        XCTAssertTrue(try ConnectionDiagnosticReport(appVersion: "0.2.5", build: "192", macOS: "26.0", connections: [diagnostic]).text()
            .contains("\"statusLineDesktopOnly\" : true"))
        let codex = ConnectionDiagnostic(provider: .codex, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                                         snapshot: nil, sessionIssue: nil, now: now, statusLineDesktopOnly: true)
        XCTAssertNil(codex.note, "Only Claude has a status line")
    }
}
