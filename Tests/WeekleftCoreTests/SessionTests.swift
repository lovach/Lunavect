import XCTest
@testable import WeekleftCore

final class SessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testDesktopTitleUsesExactSessionIDAndPreservesCyrillic() throws {
        let data = Data(#"{"cliSessionId":"abc","title":"Мои проекты","isArchived":false,"messages":["PRIVATE"]}"#.utf8)
        XCTAssertEqual(ClaudeSessionMetadata.title(from: data, sessionID: "abc"), "Мои проекты")
        XCTAssertNil(ClaudeSessionMetadata.title(from: data, sessionID: "other"))
        XCTAssertNil(ClaudeSessionMetadata.title(from: Data(#"{"cliSessionId":"abc","title":"old","isArchived":true}"#.utf8), sessionID: "abc"))
        XCTAssertNil(ClaudeSessionMetadata.title(from: Data(#"{"cliSessionId":"abc","title":"  "}"#.utf8), sessionID: "abc"))
    }
    func testDesktopMetadataDoesNotTraverseTranscriptsOrSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("account/workspace")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        let valid = Data(#"{"cliSessionId":"abc","title":"Мои проекты"}"#.utf8)
        try valid.write(to: workspace.appendingPathComponent("local_valid.json"))
        let hidden = Data(#"{"cliSessionId":"private","title":"Transcript"}"#.utf8)
        try hidden.write(to: workspace.appendingPathComponent("transcripts/local_hidden.json"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("local_link.json"), withDestinationURL: workspace.appendingPathComponent("transcripts/local_hidden.json"))
        XCTAssertEqual(ClaudeSessionMetadata.titles(for: ["abc", "private"], at: root), ["abc": "Мои проекты"])
    }
    func testTurnTimerSurvivesToolsAndCatalogMerge() throws {
        let submit = Data(#"{"session_id":"abc","hook_event_name":"UserPromptSubmit"}"#.utf8)
        let pre = Data(#"{"session_id":"abc","hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)
        let post = Data(#"{"session_id":"abc","hook_event_name":"PostToolUse","tool_name":"Bash"}"#.utf8)
        let started = try SessionRecord.event(submit, provider: .codex, previous: nil, now: now)
        let working = try SessionRecord.event(pre, provider: .codex, previous: started, now: now.addingTimeInterval(5))
        XCTAssertEqual(working.session.activityTitle, L("Выполняет команду"))
        let thinking = try SessionRecord.event(post, provider: .codex, previous: working, now: now.addingTimeInterval(10))
        XCTAssertEqual(thinking.session.activityTitle, L("Думает"))
        XCTAssertEqual(thinking.session.turnStartedAt, now)
        let catalog = try SessionParser.codex(Data(#"{"data":[{"id":"abc","name":"Actual title","status":{"type":"notLoaded"}}]}"#.utf8), now: now.addingTimeInterval(11))
        let merged = SessionList.merge(catalog: catalog, events: [thinking.session], now: now.addingTimeInterval(11))
        XCTAssertEqual(merged.first?.turnStartedAt, now)
        XCTAssertEqual(merged.first?.title, "Actual title")
        let next = try SessionRecord.event(submit, provider: .codex, previous: thinking, now: now.addingTimeInterval(20))
        XCTAssertEqual(next.session.turnStartedAt, now.addingTimeInterval(20))
    }
    func testLateSessionStartCannotOverwriteRunningTurn() throws {
        let submit = Data(#"{"session_id":"live","hook_event_name":"UserPromptSubmit"}"#.utf8)
        let start = Data(#"{"session_id":"live","hook_event_name":"SessionStart"}"#.utf8)
        let running = try SessionRecord.event(submit, provider: .claude, previous: nil, now: now)
        let lateStart = try SessionRecord.event(start, provider: .claude, previous: running, now: now.addingTimeInterval(1))
        XCTAssertEqual(lateStart.session.phase, .running)
    }
    func testBackgroundBlockedCatalogRetainsTaskStateWithoutInventingActivityTimestamp() throws {
        let data = Data(#"[{"id":"old","sessionId":"old-session","kind":"background","state":"blocked","startedAt":1783332137673}]"#.utf8)
        let first = try SessionParser.claude(data, now: now).first!
        let again = try SessionParser.claude(data, now: now.addingTimeInterval(15)).first!
        XCTAssertEqual(first.updatedAt, Date(timeIntervalSince1970: 1783332137.673))
        XCTAssertEqual(again.updatedAt, first.updatedAt)
        XCTAssertEqual(again.effectivePhase(now: now.addingTimeInterval(15)), .input)
        XCTAssertTrue(SessionList.filter([again], query: "", provider: nil, activeOnly: false, now: now.addingTimeInterval(15)).isEmpty)
        XCTAssertEqual(SessionList.filter([again], query: "", provider: nil, activeOnly: false, now: now.addingTimeInterval(15), includeHistory: true).count, 1)
    }
    func testCurrentListKeepsOpenIdleSessionButExcludesHistoryAndEndedSessions() throws {
        let data = Data(#"{"data":[{"id":"open","updatedAt":100,"status":{"type":"idle"}},{"id":"history","updatedAt":1800000000,"status":{"type":"notLoaded"}}]}"#.utf8)
        var rows = try SessionParser.codex(data, now: now)
        rows.append(AgentSession(provider: .claude, sessionID: "ended", title: "Ended", cwd: "/app", phase: .finished, updatedAt: now, observedAt: now, evidence: .hook))
        XCTAssertEqual(SessionList.filter(rows, query: "", provider: nil, activeOnly: false, now: now).map(\.sessionID), ["open"])
        XCTAssertTrue(SessionList.filter(rows, query: "", provider: nil, activeOnly: false, now: now.addingTimeInterval(61)).isEmpty)
    }
    func testFreshLiveBackgroundCatalogSupersedesEarlierHookAndThenExpires() throws {
        let catalog = try SessionParser.claude(Data(#"[{"id":"old","sessionId":"old-session","kind":"background","state":"blocked","startedAt":1783332137673,"pid":123,"status":"waiting"}]"#.utf8), now: now)
        let event = try SessionRecord.event(Data(#"{"session_id":"old-session","hook_event_name":"Stop"}"#.utf8), provider: .claude, previous: nil, now: now.addingTimeInterval(-2)).session
        let rows = SessionList.merge(catalog: catalog, events: [event], now: now)
        XCTAssertEqual(rows.first?.effectivePhase(now: now), .input)
        XCTAssertEqual(SessionList.filter(rows, query: "", provider: nil, activeOnly: false, now: now).count, 1)
        XCTAssertTrue(SessionList.filter(rows, query: "", provider: nil, activeOnly: false, now: now.addingTimeInterval(61)).isEmpty)
    }
    func testOpeningOrIdleSessionDoesNotClaimCompletedAnswer() throws {
        let start = try SessionRecord.event(Data(#"{"session_id":"abc","hook_event_name":"SessionStart"}"#.utf8), provider: .codex, previous: nil, now: now)
        let catalog = try SessionParser.codex(Data(#"{"data":[{"id":"abc","status":{"type":"idle"}}]}"#.utf8), now: now)
        XCTAssertEqual(start.session.phase.title, L("Готова к работе"))
        XCTAssertEqual(catalog.first?.phase.title, L("Готова к работе"))
        let stop = try SessionRecord.event(Data(#"{"session_id":"abc","hook_event_name":"Stop"}"#.utf8), provider: .codex, previous: start, now: now)
        XCTAssertEqual(stop.session.phase.title, L("Ответ готов"))
    }
    func testNotLoadedIsUnknownAndNameDoesNotUsePrivatePrompt() throws {
        let data = Data(#"{"data":[{"id":"abc","name":"Fix layout","cwd":"/work/app","updatedAt":1800000000,"source":"vscode","status":{"type":"notLoaded"},"preview":"PRIVATE PROMPT"}]}"#.utf8)
        let session = try SessionParser.codex(data, now: now).first!
        XCTAssertEqual(session.title, "Fix layout")
        XCTAssertEqual(session.phase, .unknown)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(session), as: UTF8.self).contains("PRIVATE"))
    }
    func testCodexApprovalAndMissingStatus() throws {
        let data = Data(#"{"data":[{"id":"one","cwd":"/a","status":{"type":"active","activeFlags":["waitingOnApproval"]}},{"id":"two","cwd":"/b"}]}"#.utf8)
        let list = try SessionParser.codex(data, now: now)
        XCTAssertEqual(list.map(\.phase), [.permission, .unknown])
        XCTAssertThrowsError(try SessionParser.codex(Data("{}".utf8), now: now))
    }
    func testClaudeCLIBlockedIsAttentionNotInventedPermission() throws {
        let data = Data(#"[{"id":"abcd","sessionId":"abcd-1234","name":"Fix menu","cwd":"/app","kind":"background","state":"blocked","startedAt":1800000000000}]"#.utf8)
        let session = try SessionParser.claude(data, now: now).first!
        XCTAssertEqual(session.phase, .input)
        XCTAssertEqual(session.client, .background)
        XCTAssertEqual(session.updatedAt, now)
        XCTAssertEqual(try SessionParser.claude(Data("[]".utf8), now: now), [])
    }
    func testHooksDoNotPersistPayloadAndDoNotClearOtherPendingApproval() throws {
        var record: SessionRecord?
        func event(_ name: String, _ tool: String) throws {
            let payload: [String: Any] = [
                "session_id": "session-1", "cwd": "/work/project", "hook_event_name": name, "tool_name": tool,
                "tool_use_id": tool + "-id", "prompt": "SECRET", "tool_input": ["command": "SECRET"],
                "transcript_path": "PRIVATE",
            ]
            record = try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .codex, previous: record, now: now)
        }
        try event("PermissionRequest", "Bash")
        try event("PostToolUse", "Read")
        XCTAssertEqual(record?.session.phase, .permission)
        try event("PostToolUse", "Bash")
        XCTAssertEqual(record?.session.phase, .running)
        try event("Stop", "")
        XCTAssertEqual(record?.session.phase, .ready)
        let encoded = String(decoding: try JSONEncoder().encode(record!), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET"))
        XCTAssertFalse(encoded.contains("PRIVATE"))
    }
    func testMergeKeepsTitleAndSeparatesProvidersWithSameID() {
        let catalog = AgentSession(provider: .codex, sessionID: "same", title: "Named task", cwd: "/work", phase: .unknown, updatedAt: now, observedAt: now)
        let hook = AgentSession(provider: .codex, sessionID: "same", title: "work", cwd: "/work", client: .desktop, phase: .running, updatedAt: now, observedAt: now, evidence: .hook)
        let claude = AgentSession(provider: .claude, sessionID: "same", title: "Other", cwd: "/other", phase: .input, updatedAt: now, observedAt: now)
        let sessions = SessionList.merge(catalog: [catalog, claude], events: [hook], now: now)
        XCTAssertEqual(sessions.count, 2)
        let codex = sessions.first { $0.provider == .codex }!
        XCTAssertEqual(codex.title, "Named task")
        XCTAssertEqual(codex.phase, .running)
        XCTAssertEqual(codex.client, .desktop)
        XCTAssertEqual(codex.effectivePhase(now: now.addingTimeInterval(601)), .unknown)
    }
    func testSearchAndActiveFilterUseEffectiveState() {
        let fresh = AgentSession(provider: .claude, sessionID: "a", title: "Меню", cwd: "/work/Lunavect", phase: .input, updatedAt: now, observedAt: now)
        let old = AgentSession(
            provider: .codex, sessionID: "b", title: "Old", cwd: "/work/Lunavect", phase: .running,
            updatedAt: now.addingTimeInterval(-3600), observedAt: now.addingTimeInterval(-3600), evidence: .hook)
        XCTAssertEqual(SessionList.filter([fresh, old], query: "lunavect", provider: nil, activeOnly: true, now: now).map(\.sessionID), ["a"])
        XCTAssertEqual(SessionList.filter([fresh, old], query: "", provider: .codex, activeOnly: false, now: now, includeHistory: true).count, 1)
    }
    func testInvalidIDsAndUnknownEventsAreRejected() throws {
        for id in ["../escape", "", "a/b"] {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": id, "cwd": "/tmp", "hook_event_name": "Stop"])
            XCTAssertThrowsError(try SessionRecord.event(data, provider: .claude, previous: nil, now: now))
        }
        XCTAssertThrowsError(try SessionRecord.event(Data(#"{"session_id":"abc","hook_event_name":"SomethingNew"}"#.utf8), provider: .claude, previous: nil, now: now))
    }
    func testFreshCatalogStatusWinsOverOlderRunningEvent() {
        let catalog = AgentSession(provider: .claude, sessionID: "same", title: "Task", cwd: "/app", phase: .input, updatedAt: now, observedAt: now)
        let event = AgentSession(
            provider: .claude, sessionID: "same", title: "app", cwd: "/app", phase: .running,
            updatedAt: now.addingTimeInterval(-30), observedAt: now.addingTimeInterval(-30), evidence: .hook)
        XCTAssertEqual(SessionList.merge(catalog: [catalog], events: [event], now: now).first?.phase, .input)
    }
    func testPermissionNotificationDoesNotCreateUnresolvableDuplicate() throws {
        let approval = Data(#"{"session_id":"abc","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#.utf8)
        let notification = Data(#"{"session_id":"abc","hook_event_name":"Notification","notification_type":"permission_prompt"}"#.utf8)
        let post = Data(#"{"session_id":"abc","hook_event_name":"PostToolUse","tool_name":"Bash"}"#.utf8)
        let first = try SessionRecord.event(approval, provider: .claude, previous: nil, now: now)
        let second = try SessionRecord.event(notification, provider: .claude, previous: first, now: now)
        let third = try SessionRecord.event(post, provider: .claude, previous: second, now: now)
        XCTAssertEqual(third.session.phase, .running)
    }
    func testCapturedRecordsHavePrivatePermissionsAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionHooks.capture(Data(#"{"session_id":"abc","cwd":"/project","hook_event_name":"UserPromptSubmit","prompt":"PRIVATE"}"#.utf8), provider: .codex, at: dir)
        let rows = SessionHooks.load(at: dir)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.phase, .running)
        let file = dir.appendingPathComponent("codex-abc.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(try String(contentsOf: file).contains("PRIVATE"))
    }
    func testResumeCommandQuotesProjectAndLinkCannotCreateNewThread() {
        let row = AgentSession(provider: .codex, sessionID: "new", title: "Ignored", cwd: "/work/a'$(touch bad)", phase: .unknown, updatedAt: now, observedAt: now)
        XCTAssertNil(row.codexURL)
        XCTAssertEqual(row.resumeCommand,  #"cd -- /work/a\'\$\(touch\ bad\) && codex resume new"#)
    }
    func testHookInstallIsIdempotentAndRemovalPreservesExistingSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let original = Data(#"{"statusLine":{"command":"old-hud"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-hook"}]}]},"custom":42}"#.utf8)
        try original.write(to: settings)
        try SessionHooks.install(provider: .claude, executable: "/Applications/Test App's.app/main", configURL: settings, backupDirectory: dir.appendingPathComponent("backups"))
        let once = try Data(contentsOf: settings)
        try SessionHooks.install(provider: .claude, executable: "/Applications/Test App's.app/main", configURL: settings, backupDirectory: dir.appendingPathComponent("backups"))
        XCTAssertEqual(try Data(contentsOf: settings), once)
        try SessionHooks.remove(provider: .claude, configURL: settings, backupDirectory: dir.appendingPathComponent("backups"))
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! NSDictionary
        XCTAssertEqual(result, try JSONSerialization.jsonObject(with: original) as! NSDictionary)
    }
    func testDisabledOrMalformedHooksCannotBeOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("settings.json")
        for text in [#"{"disableAllHooks":true}"#, #"{"hooks":{"Stop":"invalid"}}"#] {
            try Data(text.utf8).write(to: config)
            XCTAssertThrowsError(try SessionHooks.install(provider: .claude, executable: "/app", configURL: config, backupDirectory: dir.appendingPathComponent("backup")))
            XCTAssertEqual(try String(contentsOf: config), text)
        }
    }
}
