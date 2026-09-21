import XCTest
@testable import WeekleftCore

final class CodexActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ type: String, at time: Date, turn: String = "turn-1", extra: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = ["type": type, "turn_id": turn]
        extra.forEach { payload[$0] = $1 }
        return try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: time), "payload": payload])
    }
    var catalog: AgentSession {
        AgentSession(provider: .codex, sessionID: "test-id", title: "Настрой проект", cwd: "/work", phase: .unknown, updatedAt: now, observedAt: now, runtimeConfirmed: false)
    }
    func testRealTurnEventsReviveNotLoadedCatalogAndCompletionStopsSpinner() throws {
        var state = CodexActivityState()
        try state.consume(event("task_started", at: now), sessionID: catalog.sessionID)
        let running = try XCTUnwrap(state.session(from: catalog))
        XCTAssertEqual(running.effectivePhase(now: now), .running)
        XCTAssertEqual(running.turnStartedAt, now)
        XCTAssertEqual(SessionList.merge(catalog: [catalog], events: [running], now: now).first?.title, "Настрой проект")
        try state.consume(event("task_complete", at: now.addingTimeInterval(10), extra: ["last_agent_message": "PRIVATE"]), sessionID: catalog.sessionID)
        let ready = try XCTUnwrap(state.session(from: catalog))
        XCTAssertEqual(ready.effectivePhase(now: now.addingTimeInterval(10)), .ready)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(ready), as: UTF8.self).contains("PRIVATE"))
        try state.consume(event("item_completed", at: now.addingTimeInterval(11)), sessionID: catalog.sessionID)
        XCTAssertEqual(state.phase, .ready)
    }
    func testStaleActivityDoesNotBecomeFreshOnRepeatedPollsAndOtherThreadIsIgnored() throws {
        var state = CodexActivityState()
        try state.consume(event("task_started", at: now), sessionID: catalog.sessionID)
        try state.consume(event("item_completed", at: now.addingTimeInterval(10), extra: ["thread_id": "different"]), sessionID: catalog.sessionID)
        XCTAssertEqual(state.observedAt, now)
        XCTAssertFalse(try XCTUnwrap(state.session(from: catalog)).isCurrent(now: now.addingTimeInterval(121)))
    }
    func testReaderHandlesPartialAppendAndRejectsSymlinks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-test-id.jsonl")
        var start = Data(#"{"type":"session_meta","payload":{"id":"test-id","originator":"Codex Desktop","instructions":"PRIVATE"}}"#.utf8)
        start.append(10); start.append(try event("task_started", at: now)); start.append(10)
        try start.write(to: file)
        var row = catalog; row.activityPath = file.path
        let reader = CodexActivityReader(home: home)
        let first = await reader.events(catalog: [row])
        XCTAssertEqual(first.first?.phase, .running)
        XCTAssertEqual(first.first?.client, .desktop)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let finish = try event("task_complete", at: now.addingTimeInterval(5))
        try handle.write(contentsOf: finish.prefix(finish.count / 2))
        let partial = await reader.events(catalog: [row])
        XCTAssertEqual(partial.first?.phase, .running)
        try handle.write(contentsOf: finish.suffix(from: finish.count / 2) + Data([10]))
        let completed = await reader.events(catalog: [row])
        XCTAssertEqual(completed.first?.phase, .ready)
        let repeated = await reader.events(catalog: [row])
        XCTAssertEqual(repeated.first?.observedAt, now.addingTimeInterval(5))
        let link = dir.appendingPathComponent("link-test-id.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        row.activityPath = link.path
        let rejected = await reader.events(catalog: [row])
        XCTAssertTrue(rejected.isEmpty)
    }

    private func fixture() throws -> (home: URL, file: URL, row: AgentSession) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let directory = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-test-id.jsonl")
        var row = catalog; row.activityPath = file.path
        return (home, file, row)
    }

    func testSegmentedRolloutUsesThreadIdentityAndPreservesLifecycle() async throws {
        let (home, original, catalogRow) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = original.deletingLastPathComponent().appendingPathComponent("rollout-test-id_\(UUID().uuidString).jsonl")
        var row = catalogRow; row.activityPath = file.path
        let header = Data(#"{"type":"session_meta","payload":{"id":"test-id","originator":"Codex Desktop"}}"#.utf8) + Data([10])
        try (header + event("task_started", at: now) + Data([10])).write(to: file)
        let reader = CodexActivityReader(home: home, writerPaths: { $0 })
        let active = await reader.events(catalog: [row], now: now.addingTimeInterval(180))
        XCTAssertEqual(active.first?.effectivePhase(now: now.addingTimeInterval(180)), .running)
        XCTAssertEqual(active.first?.sessionID, "test-id")
        XCTAssertEqual(active.first?.client, .desktop)
        XCTAssertEqual(active.first?.turnStartedAt, now)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd(); try writer.write(contentsOf: event("task_complete", at: now.addingTimeInterval(181)) + Data([10])); try writer.close()
        let completed = await reader.events(catalog: [row], now: now.addingTimeInterval(181))
        XCTAssertEqual(completed.first?.phase, .ready)
        XCTAssertNil(completed.first?.runtimeObservedAt)
    }

    func testSegmentedRolloutRejectsMissingOrDifferentThreadHeader() async throws {
        let (home, original, catalogRow) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        for id in ["", "other-thread"] {
            let file = original.deletingLastPathComponent().appendingPathComponent("rollout-test-id_\(UUID().uuidString).jsonl")
            var row = catalogRow; row.activityPath = file.path
            let header = id.isEmpty ? Data() : Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n".utf8)
            try (header + event("task_started", at: now) + Data([10])).write(to: file)
            let events = await CodexActivityReader(home: home).events(catalog: [row], now: now)
            XCTAssertTrue(events.isEmpty)
        }
    }

    private func paddedEvent(_ type: String, at time: Date, turn: String = "turn-1", size: Int) throws -> Data {
        let line = try event(type, at: time, turn: turn)
        return line + Data(repeating: 32, count: max(0, size - line.count - 1)) + Data([10])
    }

    func testAtomicReplacementResetsTurnPendingAndOriginForEqualAndLargerFiles() async throws {
        for replacementSize in [1_024, 2_048] {
            let (home, file, row) = try fixture()
            defer { try? FileManager.default.removeItem(at: home) }
            var old = Data(#"{"type":"session_meta","payload":{"id":"test-id","originator":"Codex Desktop"}}"#.utf8) + Data([10])
            old.append(try event("task_started", at: now)); old.append(10)
            // A partial line is deliberately left pending in the old generation.
            old.append(Data(#"{"type":"event_msg","payload":"#.utf8))
            old.append(Data(repeating: 32, count: 1_024 - old.count))
            try old.write(to: file)
            let reader = CodexActivityReader(home: home, writerPaths: { $0 })
            let first = await reader.events(catalog: [row], now: now.addingTimeInterval(180))
            XCTAssertEqual(first.first?.phase, .running)
            XCTAssertEqual(first.first?.client, .desktop)
            XCTAssertEqual(first.first?.turnStartedAt, now)
            XCTAssertNotNil(first.first?.runtimeObservedAt)

            let completedAt = now.addingTimeInterval(-20)
            try paddedEvent("task_complete", at: completedAt, turn: "replacement-turn", size: replacementSize)
                .write(to: file, options: .atomic)
            let replaced = await reader.events(catalog: [row], now: now)
            XCTAssertEqual(replaced.first?.phase, .ready)
            XCTAssertEqual(replaced.first?.observedAt, completedAt, "Replacement may contain an older event or a different turn")
            XCTAssertEqual(replaced.first?.client, row.client)
            XCTAssertNil(replaced.first?.turnStartedAt)
            XCTAssertNil(replaced.first?.runtimeObservedAt)
            let fresh = await CodexActivityReader(home: home, writerPaths: { $0 }).events(catalog: [row], now: now)
            XCTAssertEqual(replaced.first?.phase, fresh.first?.phase)
            XCTAssertEqual(replaced.first?.observedAt, fresh.first?.observedAt)
        }
    }

    func testInPlaceTruncateAndRegrowResetsEqualSmallerAndLargerJournals() async throws {
        for size in [512, 1_024, 2_048] {
            let (home, file, row) = try fixture()
            defer { try? FileManager.default.removeItem(at: home) }
            try paddedEvent("task_started", at: now, size: 1_024).write(to: file)
            let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
            let initial = await reader.events(catalog: [row], now: now)
            XCTAssertEqual(initial.first?.phase, .running)
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            // No poll observes the temporary zero length; the inode stays the same.
            try writer.truncate(atOffset: 0)
            try writer.write(contentsOf: paddedEvent("turn_aborted", at: now.addingTimeInterval(-10), turn: "new-turn", size: size))
            let replaced = await reader.events(catalog: [row], now: now)
            XCTAssertEqual(replaced.first?.phase, .interrupted)
            XCTAssertEqual(replaced.first?.observedAt, now.addingTimeInterval(-10))
            XCTAssertNil(replaced.first?.turnStartedAt)
        }
    }

    func testEmptyTruncateDisappearanceAndPathChangeRecoverWithoutOldTurn() async throws {
        let (home, file, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try paddedEvent("task_started", at: now, size: 1_024).write(to: file)
        let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
        let first = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(first.first?.phase, .running)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 0)
        let empty = await reader.events(catalog: [row], now: now)
        XCTAssertTrue(empty.isEmpty)
        try writer.write(contentsOf: event("task_complete", at: now.addingTimeInterval(-10), turn: "new-turn") + Data([10]))
        let refilled = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(refilled.first?.phase, .ready)
        XCTAssertNil(refilled.first?.turnStartedAt)

        let other = file.deletingLastPathComponent().appendingPathComponent("replacement-test-id.jsonl")
        try FileManager.default.moveItem(at: file, to: other)
        let missing = await reader.events(catalog: [row], now: now)
        XCTAssertTrue(missing.isEmpty)
        var moved = row; moved.activityPath = other.path
        let relocated = await reader.events(catalog: [moved], now: now)
        XCTAssertEqual(relocated.first?.phase, .ready)
        var absent = moved; absent.activityPath = nil
        let noPath = await reader.events(catalog: [absent], now: now)
        XCTAssertTrue(noPath.isEmpty)
        let restored = await reader.events(catalog: [moved], now: now)
        XCTAssertEqual(restored.first?.observedAt, now.addingTimeInterval(-10))
    }

    func testReplacementDuringWriterProbeCannotRefreshPreviousGeneration() async throws {
        for atomic in [true, false] {
            for size in [1_024, 2_048] {
                let (home, file, row) = try fixture()
                defer { try? FileManager.default.removeItem(at: home) }
                try paddedEvent("task_started", at: now, size: 1_024).write(to: file)
                let replacement = try paddedEvent("task_complete", at: now.addingTimeInterval(100), size: size)
                let reader = CodexActivityReader(home: home, writerPaths: { paths in
                    // Synthetic writer confirmation races replacement after parsing.
                    do {
                        if atomic { try replacement.write(to: file, options: .atomic) }
                        else {
                            let writer = try FileHandle(forWritingTo: file)
                            defer { try? writer.close() }
                            try writer.truncate(atOffset: 0)
                            try writer.write(contentsOf: replacement)
                        }
                    } catch { XCTFail("Fixture replacement failed: \(error)") }
                    return paths
                })
                let raced = await reader.events(catalog: [row], now: now.addingTimeInterval(180))
                XCTAssertTrue(raced.isEmpty, "Old lifecycle state cannot be published under rewritten content")
                let next = await reader.events(catalog: [row], now: now.addingTimeInterval(180))
                XCTAssertEqual(next.first?.phase, .ready)
                XCTAssertNil(next.first?.runtimeObservedAt)
                XCTAssertNil(next.first?.turnStartedAt)
            }
        }
    }

    func testAppendDuringWriterProbePreservesTurnAndNextPollConsumesCompletion() async throws {
        let (home, file, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try paddedEvent("task_started", at: now, size: 1_024).write(to: file)
        let reader = CodexActivityReader(home: home, writerPaths: { paths in
            do {
                let writer = try FileHandle(forWritingTo: file)
                defer { try? writer.close() }
                try writer.seekToEnd()
                try writer.write(contentsOf: Data("{}\n".utf8))
            } catch { XCTFail("Fixture append failed: \(error)") }
            return paths
        })
        let later = now.addingTimeInterval(180)
        let running = await reader.events(catalog: [row], now: later)
        XCTAssertEqual(running.first?.phase, .running)
        XCTAssertEqual(running.first?.turnStartedAt, now)
        XCTAssertEqual(running.first?.runtimeObservedAt, later)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: event("task_complete", at: later) + Data([10]))
        let completed = await reader.events(catalog: [row], now: later)
        XCTAssertEqual(completed.first?.phase, .ready)
        XCTAssertNil(completed.first?.runtimeObservedAt)
    }

    func testReplacementRestartsBoundedTurnStartRecoveryEvenForTheSameTurnID() async throws {
        let (home, file, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        func largeJournal(start: Date) throws -> Data {
            try event("task_started", at: start) + Data([10]) +
                Data(repeating: 32, count: 17_000_000) + Data([10]) +
                event("item_completed", at: start.addingTimeInterval(10)) + Data([10])
        }
        try largeJournal(start: now).write(to: file)
        let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
        let first = await reader.events(catalog: [row], now: now.addingTimeInterval(10))
        XCTAssertEqual(first.first?.phase, .running)
        XCTAssertNil(first.first?.turnStartedAt, "Backward recovery has not reached the old marker yet")
        let newStart = now.addingTimeInterval(-100)
        try largeJournal(start: newStart).write(to: file, options: .atomic)
        var replaced = await reader.events(catalog: [row], now: now).first
        XCTAssertEqual(replaced?.observedAt, newStart.addingTimeInterval(10))
        XCTAssertNil(replaced?.turnStartedAt, "Replacement gets its own recovery cursor")
        for _ in 0..<3 where replaced?.turnStartedAt == nil {
            replaced = await reader.events(catalog: [row], now: now).first
        }
        XCTAssertEqual(replaced?.turnStartedAt, newStart)
    }

    func testSilentTurnSurvivesTwoMinutesOnlyWithItsLiveWriter() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-test-id.jsonl")
        var bytes = Data(#"{"type":"session_meta","payload":{"id":"test-id","originator":"codex_work_desktop"}}"#.utf8)
        bytes.append(10); bytes.append(try event("task_started", at: now)); bytes.append(10)
        try bytes.write(to: file)
        var row = catalog; row.activityPath = file.path
        let reader = CodexActivityReader(home: home, writerPaths: {
            CodexRuntimeReader.writablePaths($0, processID: getpid())
        })
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        let later = now.addingTimeInterval(131)
        let observed = await reader.events(catalog: [row], now: later)
        let running = try XCTUnwrap(observed.first)
        XCTAssertEqual(running.effectivePhase(now: later), .running)
        XCTAssertEqual(running.client, .desktop)
        XCTAssertEqual(running.observedAt, now)
        XCTAssertEqual(running.updatedAt, now)
        XCTAssertEqual(running.turnStartedAt, now)
        XCTAssertEqual(running.runtimeObservedAt, later)
        XCTAssertEqual(running.effectivePhase(now: later.addingTimeInterval(11)), .unknown)
        let merged = SessionList.merge(catalog: [row], events: observed, now: later)
        XCTAssertEqual(SessionList.filter(merged, query: "", provider: .codex, activeOnly: true, now: later).count, 1)

        try writer.close()
        let closed = await reader.events(catalog: [row], now: later.addingTimeInterval(1))
        XCTAssertNil(closed.first?.runtimeObservedAt)
        XCTAssertEqual(closed.first?.effectivePhase(now: later.addingTimeInterval(1)), .unknown)
    }

    func testCompletionAndCancellationWinEvenWhileCodexKeepsLogOpen() async throws {
        for finish in ["task_complete", "turn_aborted"] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: home) }
            let dir = home.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("rollout-test-id.jsonl")
            try (event("task_started", at: now) + Data([10])).write(to: file)
            var row = catalog; row.activityPath = file.path
            let reader = CodexActivityReader(home: home, writerPaths: {
                CodexRuntimeReader.writablePaths($0, processID: getpid())
            })
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            let later = now.addingTimeInterval(300)
            let running = await reader.events(catalog: [row], now: later)
            XCTAssertEqual(running.first?.effectivePhase(now: later), .running)
            try writer.seekToEnd()
            try writer.write(contentsOf: event(finish, at: later) + Data([10]))
            let finished = await reader.events(catalog: [row], now: later)
            XCTAssertEqual(finished.first?.phase, finish == "task_complete" ? .ready : .interrupted)
            XCTAssertNil(finished.first?.runtimeObservedAt)
            let repeated = await reader.events(catalog: [row], now: later.addingTimeInterval(601))
            XCTAssertEqual(repeated.first?.effectivePhase(now: later.addingTimeInterval(601)), .unknown)
        }
    }

    func testRuntimeProbeRequiresExactWritableFileAndCodexProcess() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl"), other = dir.appendingPathComponent("other.jsonl")
        try Data().write(to: file); try Data().write(to: other)
        let read = try FileHandle(forReadingFrom: file), unrelated = try FileHandle(forWritingTo: other)
        defer { try? read.close(); try? unrelated.close() }
        XCTAssertTrue(CodexRuntimeReader.writablePaths([file.path], processID: getpid()).isEmpty)
        let write = try FileHandle(forWritingTo: file)
        defer { try? write.close() }
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], processID: getpid()), [file.path])
        // This test runner is not Codex, even though it owns a writable log.
        XCTAssertTrue(CodexRuntimeReader.writablePaths([file.path]).isEmpty)
        XCTAssertTrue(CodexRuntimeReader.writablePaths([file.path], processID: -1).isEmpty)
        try Data("replacement".utf8).write(to: file, options: .atomic)
        XCTAssertTrue(CodexRuntimeReader.writablePaths([file.path], processID: getpid()).isEmpty,
                      "An old writable handle must not confirm a replacement at the same path")
    }

    func testRuntimeObservationCannotReviveCatalogOrAnotherProvider() {
        var row = catalog
        row.phase = .running; row.runtimeObservedAt = now; row.observedAt = now.addingTimeInterval(-300)
        XCTAssertEqual(row.effectivePhase(now: now), .unknown)
        row.runtimeConfirmed = true
        XCTAssertEqual(row.effectivePhase(now: now), .unknown)
        row.evidence = .localEvent; row.provider = .claude
        XCTAssertEqual(row.effectivePhase(now: now), .unknown)
        row.provider = .codex
        XCTAssertEqual(row.effectivePhase(now: now), .running)
        row.phase = .ready; row.observedAt = now.addingTimeInterval(-601)
        XCTAssertEqual(row.effectivePhase(now: now), .unknown)
    }

    func testLiveCodexWriterCanBridgeSilentReasoning() async throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_LIVE_CODEX_WRITER_TEST"] == "1" else {
            throw XCTSkip("Opt-in read-only check against a running local Codex task")
        }
        let catalog = try await SessionSources.codex(path: CodexProvider.discoverCLI() ?? "")
        let reader = CodexActivityReader()
        let current = await reader.events(catalog: catalog)
        let unfinished = current.filter { $0.phase == .running }
        let paths = Set(unfinished.compactMap(\.activityPath))
        let live = CodexRuntimeReader.writablePaths(paths)
        XCTAssertFalse(live.isEmpty, "A real Codex task must be running for this check")
        // Shift only the observation clock; never modify the user's journal.
        let later = Date().addingTimeInterval(131)
        let delayed = await reader.events(catalog: catalog, now: later)
        let bridged = delayed.filter { $0.activityPath.map(live.contains) == true && $0.phase == .running }
        XCTAssertFalse(bridged.isEmpty)
        for row in bridged {
            XCTAssertEqual(row.effectivePhase(now: later), .running)
            XCTAssertGreaterThan(later.timeIntervalSince(row.observedAt), 120)
            XCTAssertEqual(row.runtimeObservedAt, later)
        }
    }

    func testLargeLogRecoversExactTurnStartAfterRestartAndAcrossPolls() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-test-id.jsonl")
        var bytes = try event("task_started", at: now.addingTimeInterval(-500), turn: "older-turn") + Data([10])
        bytes.append(try event("task_started", at: now, turn: "current-turn")); bytes.append(10)
        // A single tool payload spans both the 8 MB tail and a recovery budget.
        bytes.append(Data(#"{"type":"response_item","payload":{"type":"message","text":""#.utf8))
        bytes.append(Data(repeating: 120, count: 17_000_000))
        bytes.append(Data("\"}}\n".utf8))
        bytes.append(try event("item_completed", at: now.addingTimeInterval(30), turn: "current-turn")); bytes.append(10)
        try bytes.write(to: file)
        var row = catalog; row.activityPath = file.path
        for _ in 0..<2 {
            // A new reader models an application restart without a saved cache.
            let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
            let first = await reader.events(catalog: [row], now: now.addingTimeInterval(30))
            XCTAssertEqual(first.first?.phase, .running)
            XCTAssertNil(first.first?.turnStartedAt, "Do not invent a timer before finding its marker")
            var recovered: AgentSession?
            for _ in 0..<3 {
                recovered = await reader.events(catalog: [row], now: now.addingTimeInterval(31)).first
                if recovered?.turnStartedAt != nil { break }
            }
            XCTAssertEqual(recovered?.turnStartedAt, now)
            XCTAssertEqual(recovered?.observedAt, now.addingTimeInterval(30))
            let repeated = await reader.events(catalog: [row], now: now.addingTimeInterval(40))
            XCTAssertEqual(repeated.first?.turnStartedAt, now)
            XCTAssertEqual(repeated.first?.updatedAt, now.addingTimeInterval(30))
        }
    }

    func testLargeAppendPreservesCurrentTimerButNewTurnGetsItsOwnStart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-test-id.jsonl")
        try (event("task_started", at: now) + Data([10])).write(to: file)
        var row = catalog; row.activityPath = file.path
        let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
        let initial = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(initial.first?.turnStartedAt, now)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        func appendGap(turn: String, at time: Date) throws {
            try writer.write(contentsOf: Data(repeating: 32, count: 8_100_000) + Data([10]))
            try writer.write(contentsOf: event("item_completed", at: time, turn: turn) + Data([10]))
        }
        try appendGap(turn: "turn-1", at: now.addingTimeInterval(10))
        let same = await reader.events(catalog: [row], now: now.addingTimeInterval(10))
        XCTAssertEqual(same.first?.turnStartedAt, now)
        let next = now.addingTimeInterval(20)
        try writer.write(contentsOf: event("task_started", at: next, turn: "turn-2") + Data([10]))
        try appendGap(turn: "turn-2", at: now.addingTimeInterval(30))
        var changed = await reader.events(catalog: [row], now: now.addingTimeInterval(30)).first
        for _ in 0..<2 where changed?.turnStartedAt == nil {
            changed = await reader.events(catalog: [row], now: now.addingTimeInterval(30)).first
        }
        XCTAssertEqual(changed?.turnStartedAt, next)
    }

    func testRecoveryDoesNotBorrowAnotherTurnOrThreadStart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-test-id.jsonl")
        var bytes = try event("task_started", at: now, turn: "older-turn") + Data([10])
        bytes.append(try event("task_started", at: now, extra: ["thread_id": "another-thread"])); bytes.append(10)
        bytes.append(Data(repeating: 32, count: 8_100_000)); bytes.append(10)
        bytes.append(try event("item_completed", at: now.addingTimeInterval(10))); bytes.append(10)
        try bytes.write(to: file)
        var row = catalog; row.activityPath = file.path
        let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
        for _ in 0..<3 {
            let rows = await reader.events(catalog: [row], now: now.addingTimeInterval(10))
            XCTAssertEqual(rows.first?.phase, .running)
            XCTAssertNil(rows.first?.turnStartedAt)
        }
    }

    func testLiveCodexTimerRecovery() async throws {
        guard let id = ProcessInfo.processInfo.environment["LUNAVECT_LIVE_CODEX_TIMER_SESSION_ID"] else {
            throw XCTSkip("Opt-in read-only timer recovery for a named running Codex session")
        }
        let catalog = try await SessionSources.codex(path: CodexProvider.discoverCLI() ?? "")
        let row = try XCTUnwrap(catalog.first { $0.sessionID == id })
        let reader = CodexActivityReader()
        var recovered = await reader.events(catalog: [row]).first
        guard recovered?.phase == .running else { throw XCTSkip("The selected real task has already stopped") }
        for _ in 0..<20 {
            recovered = await reader.events(catalog: [row]).first
            if recovered?.turnStartedAt != nil { break }
        }
        let start = try XCTUnwrap(recovered?.turnStartedAt)
        XCTAssertEqual(recovered?.phase, .running)
        XCTAssertLessThan(start, Date())
        let repeated = await reader.events(catalog: [row])
        XCTAssertEqual(repeated.first?.turnStartedAt, start)
    }
}
