import Darwin
import Foundation
import XCTest
@testable import WeekleftCore

/// Audit r2 (agent R): process resource probes for production code on synthetic
/// volumes. Heavy measurements run only with `LUNAVECT_R2_PERF=1`; each prints one
/// `R2PERF {json}` line. Only temporary folders are used: never the default hook,
/// Codex or Claude locations.
enum R2Probe {
    static var enabled: Bool { ProcessInfo.processInfo.environment["LUNAVECT_R2_PERF"] == "1" }
    static func requireEnabled() throws {
        guard enabled else { throw XCTSkip("Set LUNAVECT_R2_PERF=1 for R2 resource measurements") }
    }
    struct Sample {
        let cpu: Double
        let wall: Double
        let footprint: UInt64
        let resident: UInt64
        let descriptors: Int
        let threads: Int
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
    static func wall() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
    /// Physical footprint (what Activity Monitor calls Memory) and resident size.
    static func memory() -> (footprint: UInt64, resident: UInt64) {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (vm.phys_footprint, vm.resident_size)
    }
    /// Exact open descriptors of this process, by kernel type (libproc).
    static func descriptors() -> (total: Int, vnodes: Int, pipes: Int, kqueues: Int) {
        let pid = getpid()
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return (-1, -1, -1, -1) }
        var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 64)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &list, Int32(list.count * MemoryLayout<proc_fdinfo>.stride))
        let entries = list.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride)
        return (entries.count, entries.filter { $0.proc_fdtype == PROX_FDTYPE_VNODE }.count,
                entries.filter { $0.proc_fdtype == PROX_FDTYPE_PIPE }.count, entries.filter { $0.proc_fdtype == PROX_FDTYPE_KQUEUE }.count)
    }
    static func threads() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        return Int(count)
    }
    /// Direct children of this process that still exist (running or unreaped).
    static func children() -> Int {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return max(0, Int(count))
    }
    static func sample() -> Sample {
        let memory = memory()
        return Sample(cpu: cpuSeconds(), wall: wall(), footprint: memory.footprint, resident: memory.resident,
                      descriptors: descriptors().total, threads: threads())
    }
    /// CPU and wall seconds of `operation`, process-wide (XCTest runs serially).
    @discardableResult static func measure(_ operation: () throws -> Void) rethrows -> (cpu: Double, wall: Double) {
        let cpu = cpuSeconds(), start = wall()
        try operation()
        return (cpuSeconds() - cpu, wall() - start)
    }
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    static func report(_ name: String, _ fields: [String: Any]) {
        var object = fields
        object["measurement"] = name
        #if DEBUG
        object["build"] = "debug"
        #else
        object["build"] = "release"
        #endif
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        print("R2PERF " + String(decoding: data, as: UTF8.self))
    }
    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-R-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class R2PerformanceCoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Hook records (polled every 1-5 s by SessionStore)

    private func writeHookRecords(_ count: Int, to directory: URL, now: Date) throws -> [URL] {
        var files: [URL] = []
        for index in 0..<count {
            try autoreleasepool {
                let payload = try JSONSerialization.data(withJSONObject: [
                    "session_id": "r2-\(index)", "hook_event_name": "UserPromptSubmit", "cwd": "/synthetic/project-\(index % 20)"])
                let record = try SessionRecord.event(payload, provider: .claude, previous: nil, now: now)
                let file = directory.appendingPathComponent("claude-r2-\(index).json")
                try JSONEncoder().encode(record).write(to: file)
                // Settled (older than 2 s) but newer than the one-day prune cutoff.
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
                files.append(file)
            }
        }
        return files
    }

    /// R-I2: an unchanged hook directory must cost stat calls, not decoding. The
    /// warm poll cost per record should stay roughly constant from 100 to 5000.
    func testHookRecordPollCostScalesLinearlyAndReusesDecodedRecords() throws {
        try R2Probe.requireEnabled()
        let root = try R2Probe.temporaryDirectory("hooks")
        defer { try? FileManager.default.removeItem(at: root) }
        var perRecordWarm: [Int: Double] = [:]
        for count in [100, 1000, 5000] {
            let directory = root.appendingPathComponent("n\(count)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try writeHookRecords(count, to: directory, now: Date().addingTimeInterval(-3600))
            let before = R2Probe.memory().footprint
            var rows: [AgentSession] = []
            let cold = R2Probe.measure { rows = SessionHooks.load(at: directory) }
            XCTAssertEqual(rows.count, count)
            let afterCold = R2Probe.memory().footprint
            var warm: [Double] = [], warmCPU: [Double] = []
            for _ in 0..<15 {
                let cost = R2Probe.measure { rows = SessionHooks.load(at: directory) }
                warm.append(cost.wall); warmCPU.append(cost.cpu)
            }
            XCTAssertEqual(rows.count, count)
            // One percent of records change between polls (fresh writes are decoded until settled).
            var churn: [Double] = []
            for round in 0..<10 {
                for file in files.prefix(max(1, count / 100)) {
                    let payload = try JSONSerialization.data(withJSONObject: ["session_id": file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "claude-", with: ""),
                                                                              "hook_event_name": round.isMultiple(of: 2) ? "Stop" : "UserPromptSubmit"])
                    let old = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: file))
                    let record = try SessionRecord.event(payload, provider: .claude, previous: old, now: Date())
                    try JSONEncoder().encode(record).write(to: file, options: .atomic)
                }
                churn.append(R2Probe.measure { rows = SessionHooks.load(at: directory) }.wall)
            }
            let warmMedian = R2Probe.median(warm)
            perRecordWarm[count] = warmMedian / Double(count)
            R2Probe.report("hook-poll", ["records": count, "cold_wall_s": cold.wall, "cold_cpu_s": cold.cpu,
                                         "warm_wall_median_s": warmMedian, "warm_cpu_median_s": R2Probe.median(warmCPU),
                                         "warm_wall_per_record_us": warmMedian / Double(count) * 1e6,
                                         "churn1pct_wall_median_s": R2Probe.median(churn),
                                         "footprint_after_cold_delta_bytes": Int64(afterCold) - Int64(before)])
            // Cache hits must be clearly cheaper than decoding everything again.
            XCTAssertLessThan(warmMedian, cold.wall, "An unchanged directory is decoded again on every poll")
        }
        if let small = perRecordWarm[1000], let large = perRecordWarm[5000] {
            R2Probe.report("hook-poll-scaling", ["per_record_ratio_5000_vs_1000": large / small])
            XCTAssertLessThan(large / small, 3, "Warm poll cost per record grows with the number of records")
        }
    }

    // MARK: Codex local journals (read on every event poll for catalog rows)

    private func codexHome(_ root: URL) -> URL { root.appendingPathComponent("home", isDirectory: true) }
    private func rolloutFile(home: URL, id: String) throws -> URL {
        let day = home.appendingPathComponent("sessions/2026/09/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        return day.appendingPathComponent("rollout-2026-09-28T04-00-00-\(id).jsonl")
    }
    private func lifecycle(_ type: String, turn: String, at date: Date) -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = ["timestamp": formatter.string(from: date), "type": "event_msg", "payload": ["type": type, "turn_id": turn]]
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10)
        return data
    }
    /// Transcript-like filler: long lines without lifecycle markers.
    private func filler(bytes: Int) -> Data {
        let line = Data(("{\"timestamp\":\"2026-09-28T04:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"" +
                         String(repeating: "synthetic transcript text ", count: 150) + "\"}}\n").utf8)
        var data = Data(capacity: bytes + line.count)
        while data.count < bytes { data.append(line) }
        return data
    }

    /// R-I3: the first read of a very large journal is bounded (8 MB tail), later
    /// polls read only appended bytes, and an unchanged journal is not reopened.
    func testLargeCodexJournalFirstReadIsBoundedAndLaterPollsReadOnlyAppends() async throws {
        try R2Probe.requireEnabled()
        let root = try R2Probe.temporaryDirectory("codex-large")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = codexHome(root)
        for megabytes in [50, 200] {
            let id = UUID().uuidString.lowercased()
            let file = try rolloutFile(home: home, id: id)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            let meta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "originator": "codex_cli_rs"]])
            try handle.write(contentsOf: meta + Data([10]))
            let now = Date()
            try handle.write(contentsOf: lifecycle("task_started", turn: "t1", at: now.addingTimeInterval(-600)))
            let chunk = filler(bytes: 8 * 1024 * 1024)
            var written = 0
            while written < megabytes * 1024 * 1024 { try handle.write(contentsOf: chunk); written += chunk.count }
            try handle.write(contentsOf: lifecycle("item_started", turn: "t1", at: now.addingTimeInterval(-5)))
            try handle.close()
            let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
            var row = AgentSession(provider: .codex, sessionID: id, title: "Large", cwd: "/synthetic", phase: .unknown,
                                   updatedAt: now, observedAt: now)
            row.activityPath = file.path
            let footprint = R2Probe.memory().footprint
            let cpu = R2Probe.cpuSeconds(), start = R2Probe.wall()
            let first = await reader.events(catalog: [row], now: now)
            let firstWall = R2Probe.wall() - start, firstCPU = R2Probe.cpuSeconds() - cpu
            let afterFirst = R2Probe.memory().footprint
            XCTAssertEqual(first.first?.phase, .running)
            // Turn start lies ~megabytes before the tail: the bounded backward search may not reach it.
            let startRecovered = first.first?.turnStartedAt != nil
            // Unchanged journal. While the turn start is unknown, each poll continues a
            // bounded backward search (8 MB); afterwards a poll should cost metadata only.
            var steady: [Double] = []
            for _ in 0..<40 {
                let t = R2Probe.wall(); _ = await reader.events(catalog: [row], now: now); steady.append(R2Probe.wall() - t)
            }
            let recoveredLater = await reader.events(catalog: [row], now: now).first?.turnStartedAt != nil
            // Append one 64 KB burst and a completion.
            let append = try FileHandle(forWritingTo: file)
            try append.seekToEnd()
            try append.write(contentsOf: filler(bytes: 64 * 1024) + lifecycle("task_complete", turn: "t1", at: now.addingTimeInterval(1)))
            try append.close()
            let t = R2Probe.wall()
            let appended = await reader.events(catalog: [row], now: now.addingTimeInterval(2))
            let appendWall = R2Probe.wall() - t
            XCTAssertEqual(appended.first?.phase, .ready)
            R2Probe.report("codex-large-journal", ["journal_megabytes": megabytes, "first_poll_wall_s": firstWall, "first_poll_cpu_s": firstCPU,
                                                   "first_poll_footprint_delta_bytes": Int64(afterFirst) - Int64(footprint),
                                                   "turn_start_recovered_first_poll": startRecovered, "turn_start_recovered_after_40_polls": recoveredLater,
                                                   "unchanged_poll_walls_s": steady.map { ($0 * 1e5).rounded() / 1e5 },
                                                   "unchanged_poll_wall_median_last10_s": R2Probe.median(Array(steady.suffix(10))),
                                                   "append_64k_poll_wall_s": appendWall])
            XCTAssertLessThan(R2Probe.median(Array(steady.suffix(10))), firstWall / 10, "An unchanged journal is read again on every poll")
            try FileManager.default.removeItem(at: file)
        }
    }

    /// R-I2/R-I4: many small journals (catalog rows) cost metadata per poll, and a
    /// catalog that is replaced again and again does not grow retained memory.
    func testManyCodexRowsSteadyPollAndRotatingCatalogStayBounded() async throws {
        try R2Probe.requireEnabled()
        let root = try R2Probe.temporaryDirectory("codex-many")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = codexHome(root)
        let reader = CodexActivityReader(home: home, writerPaths: { _ in [] })
        let now = Date()
        func makeRows(_ count: Int, prefix: Int) throws -> [AgentSession] {
            try (0..<count).map { index in
                let id = String(format: "%08x-0000-4000-8000-%012x", prefix, index)
                let file = try rolloutFile(home: home, id: id)
                var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id]]); data.append(10)
                data.append(filler(bytes: 16 * 1024))
                data.append(lifecycle("task_started", turn: "t", at: now.addingTimeInterval(-30)))
                data.append(lifecycle("task_complete", turn: "t", at: now.addingTimeInterval(-10)))
                try data.write(to: file)
                var row = AgentSession(provider: .codex, sessionID: id, title: "", cwd: "/synthetic", phase: .unknown, updatedAt: now, observedAt: now)
                row.activityPath = file.path
                return row
            }
        }
        for count in [100, 1000] {
            let rows = try makeRows(count, prefix: count)
            let t0 = R2Probe.wall()
            let first = await reader.events(catalog: rows, now: now)
            let firstWall = R2Probe.wall() - t0
            XCTAssertEqual(first.count, count)
            var steady: [Double] = []
            for _ in 0..<10 { let t = R2Probe.wall(); _ = await reader.events(catalog: rows, now: now); steady.append(R2Probe.wall() - t) }
            R2Probe.report("codex-many-rows", ["rows": count, "first_poll_wall_s": firstWall, "steady_poll_wall_median_s": R2Probe.median(steady),
                                               "steady_poll_per_row_us": R2Probe.median(steady) / Double(count) * 1e6])
        }
        // Catalogs of 200 new sessions replace one another. Control: the same
        // fixture churn without the reader, so allocator noise is not called a leak.
        func settledFootprint() -> UInt64 { malloc_zone_pressure_relief(nil, 0); return R2Probe.memory().footprint }
        var control: [UInt64] = [], observed: [UInt64] = []
        for round in 0..<40 {
            let rows = try makeRows(200, prefix: 20_000 + round)
            for row in rows { try? FileManager.default.removeItem(atPath: row.activityPath!) }
            if round.isMultiple(of: 8) || round == 39 { control.append(settledFootprint()) }
        }
        for round in 0..<40 {
            let rows = try makeRows(200, prefix: 10_000 + round)
            _ = await reader.events(catalog: rows, now: now)
            for row in rows { try? FileManager.default.removeItem(atPath: row.activityPath!) }
            if round.isMultiple(of: 8) || round == 39 { observed.append(settledFootprint()) }
        }
        let retainedCursors = (Mirror(reflecting: reader).children.first { $0.label == "cursors" }?.value as? [String: Any])?.count ?? -1
        _ = await reader.events(catalog: [], now: now)
        let afterEmpty = (Mirror(reflecting: reader).children.first { $0.label == "cursors" }?.value as? [String: Any])?.count ?? -1
        R2Probe.report("codex-rotating-catalog", ["rounds": 40, "rows_per_round": 200,
                                                  "control_footprint_bytes": control.map { Int($0) }, "reader_footprint_bytes": observed.map { Int($0) },
                                                  "cursors_retained_after_last_round": retainedCursors, "cursors_after_empty_catalog": afterEmpty])
        XCTAssertLessThanOrEqual(retainedCursors, 200, "Cursors of vanished sessions are retained")
        XCTAssertEqual(afterEmpty, 0)
    }

    // MARK: Merge and ordering (main actor, every event poll)

    func testSessionMergeAndArrangementScaleNearLinearly() throws {
        try R2Probe.requireEnabled()
        var perRow: [Int: Double] = [:]
        for count in [100, 1000, 5000] {
            let catalog = (0..<count).map { index in
                AgentSession(provider: index.isMultiple(of: 2) ? .claude : .codex, sessionID: "s\(index)", title: "Task \(index)",
                             cwd: "/synthetic/p\(index % 10)", phase: .idle, updatedAt: base.addingTimeInterval(-Double(index)), observedAt: base)
            }
            let events = catalog.enumerated().map { index, row -> AgentSession in
                var event = row; event.evidence = .hook; event.phase = index.isMultiple(of: 3) ? .running : .ready
                event.observedAt = base.addingTimeInterval(-1); event.updatedAt = event.observedAt
                return event
            }
            var merged: [AgentSession] = []
            var walls: [Double] = []
            for _ in 0..<5 { walls.append(R2Probe.measure { merged = SessionList.merge(catalog: catalog, events: events, now: base) }.wall) }
            XCTAssertEqual(merged.count, count)
            var arrangement = SessionArrangement()
            arrangement.order = catalog.reversed().map(\.id)
            arrangement.pinned = Set(catalog.prefix(20).map(\.id))
            let arrange = R2Probe.measure { _ = arrangement.arranged(merged) }
            let filter = R2Probe.measure { _ = SessionList.filter(merged, query: "task 4", provider: nil, activeOnly: false, now: base) }
            perRow[count] = R2Probe.median(walls) / Double(count)
            R2Probe.report("session-merge", ["rows": count, "merge_wall_median_s": R2Probe.median(walls),
                                             "merge_per_row_us": R2Probe.median(walls) / Double(count) * 1e6,
                                             "arrange_wall_s": arrange.wall, "search_filter_wall_s": filter.wall])
        }
        if let small = perRow[1000], let large = perRow[5000] {
            XCTAssertLessThan(large / small, 3, "Merge cost per row grows superlinearly")
        }
    }

    // MARK: Activity history (main actor observation, full-file writes)

    /// R-I5/R-I6: per-observation cost at the 35-day/50,000-interval bound, and
    /// the bytes one checkpoint rewrites.
    func testActivityHistoryObservationCostAndCheckpointSizeAtRetentionBound() throws {
        try R2Probe.requireEnabled()
        for count in [1000, 10_000, 50_000] {
            var history = ActivityHistory()
            // Alternating provider masks prevent coalescing: one interval per state change.
            let step = 35 * 86400 / Double(count + 1)
            let start = base.addingTimeInterval(-35 * 86400 + 60)
            for index in 0..<count {
                let from = start.addingTimeInterval(Double(index) * step)
                history.append(start: from, end: from.addingTimeInterval(step), providers: index % 3, observedProviders: 3)
            }
            XCTAssertEqual(history.intervals.count, count)
            let last = history.intervals.last!.end
            var appends: [Double] = []
            var probe = history
            for index in 0..<200 {
                let from = last.addingTimeInterval(Double(index) * 2)
                appends.append(R2Probe.measure { probe.append(start: from, end: from.addingTimeInterval(2), providers: index % 2 + 1, observedProviders: 3) }.wall)
            }
            var data = Data()
            let encode = try R2Probe.measure { data = try JSONEncoder().encode(history) }
            let decode = try R2Probe.measure { _ = try JSONDecoder().decode(ActivityHistory.self, from: data) }
            let equality = R2Probe.measure { XCTAssertEqual(history, history) }
            let summary = R2Probe.measure { _ = history.summary(now: last, period: .month) }
            R2Probe.report("activity-history", ["intervals": count, "append_wall_median_us": R2Probe.median(appends) * 1e6,
                                                "encoded_bytes": data.count, "encode_wall_s": encode.wall, "decode_wall_s": decode.wall,
                                                "equality_wall_s": equality.wall, "month_summary_wall_s": summary.wall])
        }
        // Private details at their bounds: 2000 records, 100,000 intervals.
        var details = ActivityDetails()
        let detailStart = base.addingTimeInterval(-30 * 86400)
        for record in 0..<2000 {
            let session = AgentSession(provider: record.isMultiple(of: 2) ? .claude : .codex, sessionID: "d\(record)", title: "Synthetic title \(record)",
                                       cwd: "/Users/synthetic/Projects/project-\(record % 50)", phase: .running, updatedAt: base, observedAt: base)
            for span in 0..<50 {
                let from = detailStart.addingTimeInterval(Double(record * 50 + span) * 12)
                details.append(session, start: from, end: from.addingTimeInterval(6))
            }
        }
        var pruned = details
        let prune = R2Probe.measure { pruned.prune(now: base) }
        let equality = R2Probe.measure { _ = pruned == details }
        var encoded = Data()
        let encode = try R2Probe.measure { encoded = try JSONEncoder().encode(pruned) }
        R2Probe.report("activity-details", ["records": pruned.records.count, "intervals": pruned.records.values.reduce(0) { $0 + $1.intervals.count },
                                            "prune_wall_s": prune.wall, "equality_wall_s": equality.wall,
                                            "encoded_bytes": encoded.count, "encode_wall_s": encode.wall])
    }

    // MARK: Child processes (catalog polls spawn `claude`/`codex` every 15-45 s)

    /// R-I8: completed, timed-out and cancelled children leave no descriptors or
    /// unreaped processes behind. Uses only /bin/echo and /bin/sleep.
    func testChildProcessesNeverLeakDescriptorsOrChildren() async throws {
        try R2Probe.requireEnabled()
        _ = try SessionProcess.run(path: "/bin/echo", arguments: ["warm-up"])
        let before = R2Probe.descriptors(), childrenBefore = R2Probe.children()
        let normal = try R2Probe.measure {
            for index in 0..<100 { XCTAssertEqual(try SessionProcess.run(path: "/bin/echo", arguments: ["\(index)"]), Data("\(index)\n".utf8)) }
        }
        let afterNormal = R2Probe.descriptors()
        var timeouts = 0
        let timed = R2Probe.measure {
            for _ in 0..<5 {
                do { _ = try SessionProcess.run(path: "/bin/sleep", arguments: ["30"], timeout: 0.2) }
                catch SessionError.timeout { timeouts += 1 } catch { XCTFail("Unexpected \(error)") }
            }
        }
        XCTAssertEqual(timeouts, 5)
        var cancelled = 0
        for _ in 0..<5 {
            let task = Task.detached { try await SessionProcess.detached { try SessionProcess.run(path: "/bin/sleep", arguments: ["30"], timeout: 10) } }
            try await Task.sleep(for: .milliseconds(150))
            task.cancel()
            do { _ = try await task.value } catch is CancellationError { cancelled += 1 } catch { XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(cancelled, 5)
        // Allow Foundation's termination handling to reap the last child.
        for _ in 0..<50 where R2Probe.children() > childrenBefore { try await Task.sleep(for: .milliseconds(20)) }
        let after = R2Probe.descriptors()
        R2Probe.report("child-processes", ["echo_runs": 100, "echo_total_wall_s": normal.wall, "echo_per_run_ms": normal.wall * 10,
                                           "timeouts": timeouts, "timeout_total_wall_s": timed.wall, "cancelled": cancelled,
                                           "fds_before": before.total, "fds_after_echo": afterNormal.total, "fds_after_all": after.total,
                                           "pipes_before": before.pipes, "pipes_after": after.pipes,
                                           "children_before": childrenBefore, "children_after": R2Probe.children()])
        XCTAssertEqual(after.pipes, before.pipes, "Pipes of finished children remain open")
        XCTAssertLessThanOrEqual(after.total, before.total + 2, "Descriptors grow with child runs")
        XCTAssertEqual(R2Probe.children(), childrenBefore, "A child process is left running or unreaped")
    }
}
