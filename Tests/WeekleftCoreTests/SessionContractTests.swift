import XCTest
@testable import WeekleftCore

final class SessionContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ name: String, previous: SessionRecord? = nil, at: Date? = nil, extra: [String: Any] = [:]) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "fixture", "hook_event_name": name]
        payload.merge(extra) { _, new in new }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: previous, now: at ?? now)
    }
    private func catalog(_ extra: [String: Any], at: Date? = nil) throws -> AgentSession {
        var row: [String: Any] = ["sessionId": "fixture", "kind": "interactive", "startedAt": 1_700_000_000_000]
        row.merge(extra) { _, new in new }
        return try XCTUnwrap(SessionParser.claude(JSONSerialization.data(withJSONObject: [row]), now: at ?? now).first)
    }
    func testDocumentedClaudeStatesAndLiveStatus() throws {
        for (state, phase) in [("working", SessionPhase.running), ("blocked", .input), ("done", .ready), ("failed", .failed), ("stopped", .interrupted)] {
            let row = try catalog(["kind": "background", "id": "short-id", "state": state])
            XCTAssertEqual(row.effectivePhase(now: now), phase, state)
        }
        for (status, phase) in [("busy", SessionPhase.running), ("waiting", .input), ("idle", .idle)] {
            XCTAssertEqual(try catalog(["status": status, "pid": 123]).effectivePhase(now: now), phase)
        }
        for reason in ["permission prompt", "sandbox request"] {
            XCTAssertEqual(try catalog(["status": "waiting", "waitingFor": reason]).phase, .permission)
        }
        XCTAssertEqual(try catalog(["kind": "background", "state": "working", "status": "idle"]).phase, .running)
        XCTAssertEqual(try catalog(["kind": "background", "state": "done", "status": "idle"]).phase, .ready)
    }
    func testFreshIdleCatalogInterruptsHookTurnWithoutInventingCompletionOrRevivingStaleWork() throws {
        let running = try event("UserPromptSubmit").session
        let row = try catalog(["status": "idle"], at: now.addingTimeInterval(15))
        let merged = SessionList.merge(catalog: [row], events: [running], now: now.addingTimeInterval(15))
        XCTAssertEqual(merged.first?.phase, .interrupted)
        XCTAssertFalse(try XCTUnwrap(merged.first).effectivePhase(now: now.addingTimeInterval(15)).isActive)
        XCTAssertEqual(SessionList.merge(catalog: [row], events: [running], now: now.addingTimeInterval(90)).first?.effectivePhase(now: now.addingTimeInterval(90)), .unknown)
        XCTAssertEqual(SessionList.merge(catalog: [], events: [running], now: now.addingTimeInterval(15)).first?.phase, .running, "An absent catalog row proves no completion")
        let newer = try event("UserPromptSubmit", at: now.addingTimeInterval(16)).session
        XCTAssertEqual(SessionList.merge(catalog: [row], events: [newer], now: now.addingTimeInterval(16)).first?.phase, .running)
    }

    func testCompactionLifecycleCountsWorkWithoutPersistingSummaryOrInventingAReply() throws {
        for trigger in ["manual", "auto"] {
            let prior = try event("UserPromptSubmit", at: now.addingTimeInterval(-120))
            let compact = try event("PreCompact", previous: prior, extra: ["trigger": trigger, "custom_instructions": "PRIVATE"])
            XCTAssertEqual(compact.session.phase, .running)
            XCTAssertEqual(compact.session.compactionTrigger, trigger)
            XCTAssertEqual(compact.session.turnStartedAt, trigger == "manual" ? now : prior.session.turnStartedAt)
            for status in ["idle", "busy"] {
                let later = now.addingTimeInterval(200)
                let row = try catalog(["status": status], at: later)
                let merged = try XCTUnwrap(SessionList.merge(catalog: [row], events: [compact.session], now: later).first)
                XCTAssertEqual(merged.effectivePhase(now: later), .running)
                XCTAssertEqual(merged.compactionTrigger, trigger)
            }
            let ended = try event("PostCompact", previous: compact, at: now.addingTimeInterval(240),
                                  extra: ["trigger": trigger, "compact_summary": "PRIVATE"])
            XCTAssertNil(ended.session.compactionTrigger)
            XCTAssertEqual(ended.session.phase, trigger == "manual" ? .idle : .running)
            let start = try event("SessionStart", previous: compact, at: now.addingTimeInterval(240), extra: ["source": "compact"])
            XCTAssertEqual(start.session.phase, ended.session.phase)
            XCTAssertNil(start.session.compactionTrigger)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(ended), as: UTF8.self).contains("PRIVATE"))
            let idle = try catalog(["status": "idle"], at: now.addingTimeInterval(601))
            XCTAssertNotEqual(SessionList.merge(catalog: [idle], events: [compact.session], now: now.addingTimeInterval(601)).first?.phase, .running)
            let resumed = try event("UserPromptSubmit", previous: compact, at: now.addingTimeInterval(250))
            XCTAssertNil(resumed.session.compactionTrigger)
        }
    }
    func testFailedCatalogCannotClaimInterruptionAndNewHookSupersedesLastSuccessfulPoll() throws {
        let running = try event("UserPromptSubmit").session
        var row = try catalog(["status": "idle"], at: now.addingTimeInterval(15))
        row.runtimeConfirmed = false
        let unknown = SessionList.merge(catalog: [row], events: [running], now: now.addingTimeInterval(20)).first!
        XCTAssertEqual(unknown.effectivePhase(now: now.addingTimeInterval(20)), .unknown)
        XCTAssertNotEqual(unknown.phase, .interrupted)
        let fresh = try event("UserPromptSubmit", at: now.addingTimeInterval(21)).session
        XCTAssertEqual(SessionList.merge(catalog: [row], events: [fresh], now: now.addingTimeInterval(21)).first?.effectivePhase(now: now.addingTimeInterval(21)), .running)
    }
    func testHistoricalBackgroundCompletionIsSeparateFromStateAndUnfinishedTasks() throws {
        for state in ["done", "failed", "stopped"] {
            let historical = try catalog(["kind": "background", "state": state])
            XCTAssertFalse(historical.isCurrent(now: now), state)
            XCTAssertNotEqual(historical.effectivePhase(now: now), .unknown)
            let live = try catalog(["kind": "background", "state": state, "pid": 123, "status": "idle"])
            XCTAssertTrue(live.isCurrent(now: now), state)
        }
        XCTAssertTrue(try catalog(["kind": "background", "state": "working"]).isCurrent(now: now), "Autonomous work can continue without a process")
        let dormant = try catalog(["kind": "background", "state": "blocked"])
        XCTAssertEqual(dormant.phase, .input, "Retained waiting state is not idle or completed")
        XCTAssertFalse(dormant.isCurrent(now: now), "A retained wait alone does not establish current presence")
        XCTAssertEqual(try catalog(["kind": "background", "state": "new-future-value"]).effectivePhase(now: now), .unknown)
    }
    func testCatalogPreservesTimerAndConfirmedCompletion() throws {
        let running = try event("UserPromptSubmit")
        let busy = try catalog(["status": "busy"], at: now.addingTimeInterval(15))
        XCTAssertEqual(SessionList.merge(catalog: [busy], events: [running.session], now: now.addingTimeInterval(15)).first?.turnStartedAt, now)
        let ready = try event("Stop", previous: running, at: now.addingTimeInterval(10)).session
        let idle = try catalog(["status": "idle"], at: now.addingTimeInterval(15))
        XCTAssertEqual(SessionList.merge(catalog: [idle], events: [ready], now: now.addingTimeInterval(15)).first?.phase, .ready)
    }
    func testRetainedWaitStaysHistoryAcrossPollsWhileOldLiveWaitRemainsCurrent() throws {
        for seconds in [0.0, 30, 3600] {
            let date = now.addingTimeInterval(seconds)
            let row = try catalog(["kind": "background", "state": "blocked"], at: date)
            XCTAssertEqual(row.effectivePhase(now: date), .input)
            XCTAssertFalse(row.isCurrent(now: date))
            XCTAssertTrue(SessionList.filter([row], query: "", provider: nil, activeOnly: false, now: date).isEmpty)
            XCTAssertEqual(SessionList.filter([row], query: "", provider: nil, activeOnly: false, now: date, includeHistory: true).count, 1)
        }
        // startedAt predates now by years in this fixture. Presence, not session
        // age, distinguishes a real wait from a retained background record.
        let liveRows: [[String: Any]] = [["pid": 123], ["status": "waiting", "waitingFor": "permission prompt"], ["status": "idle", "pid": 123]]
        for live in liveRows {
            var payload: [String: Any] = ["kind": "background", "state": "blocked"]
            payload.merge(live) { _, new in new }
            XCTAssertTrue(try catalog(payload).isCurrent(now: now))
        }
        for pid in [0, -1] {
            XCTAssertFalse(try catalog(["kind": "background", "state": "blocked", "pid": pid]).isCurrent(now: now))
        }
    }
    func testRetainedCatalogCannotOverrideFreshHookOrExtendItsLifetime() throws {
        let wait = try event("PermissionRequest", extra: ["tool_name": "Bash"]).session
        for seconds in [1.0, 30, 599] {
            let date = now.addingTimeInterval(seconds)
            let dormant = try catalog(["kind": "background", "state": "blocked"], at: date)
            let merged = try XCTUnwrap(SessionList.merge(catalog: [dormant], events: [wait], now: date).first)
            XCTAssertEqual(merged.phase, .permission)
            XCTAssertEqual(merged.observedAt, now, "A catalog reread must not become a hook heartbeat")
            XCTAssertTrue(merged.isCurrent(now: date))
        }
        let expired = now.addingTimeInterval(600)
        let dormant = try catalog(["kind": "background", "state": "blocked"], at: expired)
        let merged = try XCTUnwrap(SessionList.merge(catalog: [dormant], events: [wait], now: expired).first)
        XCTAssertEqual(merged.phase, .input)
        XCTAssertFalse(merged.isCurrent(now: expired))
        let done = try catalog(["kind": "background", "state": "done"], at: now.addingTimeInterval(1))
        XCTAssertEqual(SessionList.merge(catalog: [done], events: [wait], now: now.addingTimeInterval(1)).first?.phase, .ready,
                       "Confirmed completion still supersedes an older hook")
    }
    func testRetainedWaitDoesNotNotifyOrSeedHistoricalCompletion() throws {
        var tracker = SessionNoticeTracker()
        let working = try catalog(["kind": "background", "state": "working"])
        XCTAssertTrue(tracker.update([working], now: now).isEmpty)
        let dormant = try catalog(["kind": "background", "state": "blocked"], at: now.addingTimeInterval(1))
        XCTAssertTrue(tracker.update([dormant], now: now.addingTimeInterval(1)).isEmpty)
        let reopened = try catalog(["kind": "background", "state": "done", "pid": 123, "status": "idle"], at: now.addingTimeInterval(2))
        XCTAssertTrue(tracker.update([reopened], now: now.addingTimeInterval(2)).isEmpty, "Dormant waiting must not imply a newly completed response")
        let liveWait = try catalog(["kind": "background", "state": "blocked", "pid": 123, "status": "waiting", "waitingFor": "permission prompt"], at: now.addingTimeInterval(3))
        XCTAssertEqual(tracker.update([liveWait], now: now.addingTimeInterval(3)).map(\.kind), [.permission])
        let done = try catalog(["kind": "background", "state": "done"], at: now.addingTimeInterval(4))
        XCTAssertEqual(tracker.update([done], now: now.addingTimeInterval(4)).map(\.kind), [.completed],
                       "An observed live task still reports actual completion when its process exits")
    }
    func testUnidentifiedPermissionClearsOnProgressWhileIdentifiedParallelRequestsStayPending() throws {
        let approval = try event("PermissionRequest", extra: ["tool_name": "Bash"])
        let progress = try event("PostToolUse", previous: approval, extra: ["tool_name": "Read", "tool_use_id": "read-1"])
        XCTAssertEqual(progress.session.phase, .running)
        let notification = try event("Notification", extra: ["notification_type": "permission_prompt"])
        XCTAssertEqual(try event("PostToolUseFailure", previous: notification, extra: ["tool_use_id": "network-1"]).session.phase, .running)
        let first = try event("PermissionRequest", extra: ["tool_use_id": "first"])
        let second = try event("PermissionRequest", previous: first, extra: ["tool_use_id": "second"])
        let completed = try event("PostToolUse", previous: second, extra: ["tool_use_id": "first"])
        XCTAssertEqual(completed.pendingApprovals, ["second"])
        XCTAssertEqual(completed.session.phase, .permission)
    }
    func testLegacyApprovalToolNamesMigrateWithoutStickingAfterAnotherToolRuns() throws {
        var old = try event("PermissionRequest", extra: ["tool_name": "Bash"])
        old.approvalVersion = nil; old.unidentifiedApproval = nil; old.pendingApprovals = ["Bash"]
        let saved = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(old))
        let progress = try event("PostToolUse", previous: saved, extra: ["tool_name": "Read", "tool_use_id": "read-id"])
        XCTAssertEqual(progress.session.phase, .running)
        XCTAssertTrue(progress.pendingApprovals.isEmpty)
    }
    func testIdleReminderDoesNotCreateSecondAttentionNotice() throws {
        let running = try event("UserPromptSubmit")
        let ready = try event("Stop", previous: running, at: now.addingTimeInterval(10))
        let reminder = try event("Notification", previous: ready, at: now.addingTimeInterval(70), extra: ["notification_type": "idle_prompt"])
        XCTAssertEqual(reminder.session, ready.session)
        XCTAssertEqual(try event("Notification", previous: ready, at: now.addingTimeInterval(71), extra: ["notification_type": "elicitation_dialog"]).session.phase, .input)
    }
    func testClosingDecisionQuestionsNeedInputInsteadOfClaimingCompletion() throws {
        let running = try event("UserPromptSubmit")
        for text in [
            "Предлагаю пять правок.\n\n1. Делаем все пять? Если выбирать, то 1 и 2.\n2. Подписи на английском? Предлагаю да.",
            "Подробный разбор допишу позже.\n\n1. Делаю все шесть? Предлагаю да.",
            "**Продолжаем?**", "Жду вашего подтверждения перед публикацией.",
            "Выберите один из двух вариантов.", "Shall I apply these changes?",
            "Please confirm the target directory.", "Which option do you prefer?",
            "Soll ich die Änderungen anwenden?",
            "Хук принимаем? Рекомендую да.", "Правки 1–6 оставляем? Рекомендую да.",
            "Можно скачать `example.dmg` во временную папку? Тогда проверю установщик.",
            "Готов предварительный вариант.\n\nВопросы:\n1. Хук принимаем? Рекомендую да.\n2. Правки оставляем?\n3. Можно скачать `example.dmg`?",

        ] {
            let stopped = try event("Stop", previous: running, extra: ["last_assistant_message": text])
            XCTAssertEqual(stopped.session.phase, .input, text)
            XCTAssertEqual(stopped.session.responseRequestsInput, true)
            XCTAssertTrue(stopped.session.isCurrent(now: now))
            XCTAssertTrue(stopped.pendingApprovals.isEmpty, "A prose question is not a tool permission request")
            let encoded = try JSONEncoder().encode(stopped)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(text), "Do not persist conversation text")
            XCTAssertEqual(try JSONDecoder().decode(SessionRecord.self, from: encoded).session.phase, .input)
        }
    }
    func testReadyResponsesExamplesAndOptionalOffersDoNotInventInputRequests() throws {
        for text in [
            "Готово. Все проверки прошли.", "Почему так? Причина — старый кэш.",
            "Если хотите, могу добавить ещё один вариант.", "Хочешь, покажу другой вариант?",
            "You can choose a different theme in Settings.", "Что дальше? Работа завершена.",
            "Пример сообщения:\n> Делаем все пять?",
            "Пример:\n```text\nShall I proceed?\n```",
            "Пример:\n~~~\nВыберите вариант.\n~~~", "Кнопка называется «Продолжаем?».",
            "| Подтвердите выбор | Пример текста |", "`Please confirm the path.`",
            "Пример: `Хук принимаем?`", "> Можно скачать файл?", "Правки оставляем как есть.",
            "В документации есть фраза «Хук принимаем?». Это пример.",
            "`Можно скачать файл?`", "Можно скачать файл на сайте. Работа завершена.",
        ] {
            XCTAssertEqual(try event("Stop", extra: ["last_assistant_message": text]).session.phase, .ready, text)
        }
        XCTAssertEqual(try event("Stop").session.phase, .ready, "Older clients may omit the response")
        XCTAssertEqual(try event("Stop", extra: ["last_assistant_message": ["bad": "shape"]]).session.phase, .ready)
    }
    func testResponseQuestionSurvivesIdleCatalogButNewWorkAndTerminalStatesWin() throws {
        let question = try event("Stop", extra: ["last_assistant_message": "Делаем все пять?"])
        let later = now.addingTimeInterval(15)
        for values: [String: Any] in [["status": "idle"], ["pid": 123]] {
            let row = try catalog(values, at: later)
            let merged = try XCTUnwrap(SessionList.merge(catalog: [row], events: [question.session], now: later).first)
            XCTAssertEqual(merged.phase, .input)
            XCTAssertEqual(merged.observedAt, now, "Polling must not renew inferred evidence")
            XCTAssertEqual(SessionList.filter([merged], query: "", provider: nil, activeOnly: true, now: later).count, 1)
        }
        for (values, phase): ([String: Any], SessionPhase) in [
            (["status": "busy"], .running), (["status": "waiting", "waitingFor": "permission prompt"], .permission),
            (["kind": "background", "state": "done"], .ready), (["kind": "background", "state": "failed"], .failed),
        ] {
            let row = try catalog(values, at: later)
            XCTAssertEqual(SessionList.merge(catalog: [row], events: [question.session], now: later).first?.phase, phase)
        }
        let expired = now.addingTimeInterval(601)
        let idle = try catalog(["status": "idle"], at: expired)
        XCTAssertNotEqual(SessionList.merge(catalog: [idle], events: [question.session], now: expired).first?.phase, .input)
        let reminder = try event("Notification", previous: question, at: later, extra: ["notification_type": "idle_prompt"])
        XCTAssertEqual(reminder.session, question.session)
        let resumed = try event("UserPromptSubmit", previous: question, at: later)
        XCTAssertEqual(resumed.session.phase, .running)
        XCTAssertNil(resumed.session.responseRequestsInput)
        let finished = try event("Stop", previous: resumed, at: later.addingTimeInterval(10), extra: ["last_assistant_message": "Готово."])
        XCTAssertEqual(finished.session.phase, .ready)
        XCTAssertNil(finished.session.responseRequestsInput)
    }
    func testClockCorrectionAcceptsStopAndSmallReorderingIsIgnored() throws {
        let running = try event("UserPromptSubmit")
        XCTAssertEqual(try event("Stop", previous: running, at: now.addingTimeInterval(-3600)).session.phase, .ready)
        XCTAssertEqual(try event("Stop", previous: running, at: now.addingTimeInterval(-2)).session.phase, .running)
    }
    func testDiacriticInsensitiveSearch() {
        for (title, query) in [("Ёлка", "елка"), ("Café", "cafe")] {
            let row = AgentSession(provider: .claude, sessionID: "fixture", title: title, cwd: "", phase: .idle, updatedAt: now, observedAt: now)
            XCTAssertEqual(SessionList.filter([row], query: query, provider: nil, activeOnly: false, now: now).count, 1)
        }
    }
    func testChangingPollPolicyCannotMoveCatalogDeadlineLater() {
        var lastPoll = now, deadline: Date? = now.addingTimeInterval(45)
        var polls = 0
        for second in 1...135 {
            let date = now.addingTimeInterval(Double(second))
            let interval = SessionPolling(panelVisible: false, hasActiveSessions: second % 4 < 2).catalog
            deadline = SessionPolling.nextCatalogDeadline(now: date, lastPoll: lastPoll, scheduled: deadline, interval: interval)
            if deadline! <= date {
                polls += 1; lastPoll = date; deadline = date.addingTimeInterval(interval)
            }
        }
        XCTAssertGreaterThanOrEqual(polls, 8)
    }
    func testLiveAndUncertainTerminalSessionsNeverProduceResumeLauncher() throws {
        for provider in ProviderID.allCases {
            var row = AgentSession(
                provider: provider, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture", cwd: "/tmp",
                client: .terminal, phase: .running, updatedAt: now, observedAt: now, evidence: .hook)
            for phase in SessionPhase.allCases where phase != .finished {
                row.phase = phase
                XCTAssertNil(row.terminalScript(executable: "/bin/echo"), phase.rawValue)
            }
            row.phase = .finished
            XCTAssertNotNil(row.terminalScript(executable: "/bin/echo"))
            row.evidence = .catalog
            XCTAssertNil(row.terminalScript(executable: "/bin/echo"))
        }
    }
    func testBackgroundAttachAcceptsDocumentedShortIDWithoutSessionUUID() throws {
        var row = AgentSession(provider: .claude, sessionID: "7c5dcf5d", title: "Fixture", cwd: "/tmp", client: .background, phase: .running, updatedAt: now, observedAt: now, resumeID: "7c5dcf5d")
        XCTAssertTrue(try XCTUnwrap(row.terminalScript(executable: "/bin/echo")).contains("attach '7c5dcf5d'"))
        row.resumeID = nil
        XCTAssertNil(row.terminalScript(executable: "/bin/echo"), "A missing attach ID must not fall through to resume")
    }
    private func checkQuoting(shells: [String]) throws {
        let values = [#"/tmp/x\'$(printf SUBSTITUTED)' #"#, #"/tmp/`printf SUBSTITUTED`"#, #"/tmp/a (b); $HOME & [x]"#, "/tmp/Ёлка Café"]
        for shell in shells {
            for value in values {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = (shell.hasSuffix("fish") ? ["--no-config"] : shell.hasSuffix("zsh") ? ["-f"] : []) + ["-c", "/usr/bin/printf %s " + SessionHooks.portableQuote(value)]
                process.environment = ["PATH": "/usr/bin:/bin"]
                process.standardOutput = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertEqual(String(decoding: data, as: UTF8.self), value, shell)
            }
        }
    }
    func testPortableQuotingRoundTripsThroughShAndZsh() throws {
        try checkQuoting(shells: ["/bin/sh", "/bin/zsh"])
    }
    func testPortableQuotingRoundTripsThroughFish() throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("fish is not installed; real sh and zsh round trips are covered separately")
        }
        try checkQuoting(shells: [fish])
    }
}
