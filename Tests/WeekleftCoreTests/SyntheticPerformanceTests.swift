import Darwin
import Foundation
import XCTest
@testable import WeekleftCore

/// Opt-in measurements of production algorithms. No localSources/default storage paths.
final class SyntheticPerformanceTests: XCTestCase {
    struct Workload {
        let files: Int
        let recordsPerFile: Int
        let sessions: Int
        let repetitions: Int
        /// Claude transcripts: files × answered turns of about 27 KB each, with
        /// long thinking/tool output strings like real project logs.
        var claudeFiles = 8
        var claudeTurnsPerFile = 20
        static func named(_ name: String) throws -> Self {
            switch name {
            case "quick": return .init(files: 16, recordsPerFile: 32, sessions: 250, repetitions: 4)
            case "large": return .init(files: 256, recordsPerFile: 256, sessions: 5000, repetitions: 20, claudeFiles: 64, claudeTurnsPerFile: 300)
            default: throw NSError(domain: "SyntheticPerformance", code: 1)
            }
        }
    }

    func testRunSyntheticWorkload() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["LUNAVECT_BENCHMARK_OUTPUT"],
              let name = environment["LUNAVECT_BENCHMARK_PROFILE"] else {
            throw XCTSkip("Use scripts/measure-performance.py --run for explicit synthetic measurements")
        }
        let workload = try Workload.named(name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var phases: [[String: Any]] = []
        var bytesWritten = 0
        try measure("fixture-generation", into: &phases) {
            for file in 0..<workload.files {
                try autoreleasepool {
                var data = Data()
                for record in 0..<workload.recordsPerFile {
                    let index = file * workload.recordsPerFile + record
                    let end = now.timeIntervalSince1970 - Double(index * 10 + 10)
                    let event: [String: Any] = ["type": "event_msg", "payload": ["type": "task_complete",
                        "turn_id": "synthetic-\(index)", "started_at": end - 8, "completed_at": end, "duration_ms": 8000]]
                    data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])); data.append(10)
                }
                bytesWritten += data.count
                let path = directory.appendingPathComponent("synthetic-\(file).jsonl")
                try data.write(to: path)
                try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
                }
            }
        }
        var imported = ActivityImportResult()
        measure("archive-import", into: &phases) {
            imported = ActivityHistoryImporter.read(sources: [.init(directory: directory, provider: .codex)],
                before: now, now: now, maximumSeconds: 90)
        }
        let expected = workload.files * workload.recordsPerFile
        XCTAssertEqual(imported.intervals.count, expected)
        XCTAssertFalse(imported.limited)
        let claudeDirectory = directory.appendingPathComponent("claude", isDirectory: true)
        var claudeBytes = 0
        try measure("claude-fixture-generation", into: &phases) {
            claudeBytes = try writeClaudeArchive(to: claudeDirectory, workload: workload, now: now)
        }
        var claude = ActivityImportResult()
        measure("claude-archive-import", into: &phases) {
            claude = ActivityHistoryImporter.read(sources: [.init(directory: claudeDirectory, provider: .claude)],
                before: now, now: now, maximumSeconds: 90)
        }
        let claudeTurns = workload.claudeFiles * workload.claudeTurnsPerFile
        XCTAssertEqual(claude.report.providers.first?.taskRecords, claudeTurns)
        XCTAssertFalse(claude.limited)
        let claudeSeconds = phases.last?["wall_seconds"] as? Double ?? .infinity
        var history = ActivityHistory()
        var encodedBytes = 0
        var checksum: Double = 0
        try measure("history-merge-summary-roundtrip", into: &phases) {
            history.mergeRecovered(imported.intervals, now: now, limited: false)
            for _ in 0..<workload.repetitions {
                let data = try JSONEncoder().encode(history)
                encodedBytes = data.count
                let decoded = try JSONDecoder().decode(ActivityHistory.self, from: data)
                checksum += decoded.summary(now: now, period: .month).totals.active
            }
        }
        XCTAssertGreaterThan(checksum, 0)
        let rows = (0..<workload.sessions).map { index in
            AgentSession(provider: index.isMultiple(of: 2) ? .claude : .codex,
                sessionID: "synthetic-\(index)", title: "Synthetic task \(index)", cwd: "/synthetic/project-\(index % 10)",
                phase: index.isMultiple(of: 3) ? .running : .ready, updatedAt: now, observedAt: now)
        }
        var arrangement = SessionArrangement()
        arrangement.order = rows.reversed().map(\.id)
        arrangement.pinned = Set(rows.prefix(20).map(\.id))
        var ordered = [AgentSession]()
        measure("session-arrangement", into: &phases) {
            for _ in 0..<workload.repetitions { ordered = arrangement.arranged(rows) }
        }
        XCTAssertEqual(ordered.count, workload.sessions)
        XCTAssertEqual(Set(ordered.prefix(20).map(\.id)), arrangement.pinned)
        let result: [String: Any] = ["schema_version": 1, "profile": name, "phases": phases,
            "scenario": ["archive_files": workload.files, "records_per_file": workload.recordsPerFile,
                         "archive_records": expected, "archive_logical_bytes": bytesWritten,
                         "claude_files": workload.claudeFiles, "claude_turns": claudeTurns, "claude_logical_bytes": claudeBytes,
                         "sessions": workload.sessions, "repetitions": workload.repetitions,
                         "fixed_now_unix_seconds": now.timeIntervalSince1970],
            "result": ["recovered_intervals": imported.intervals.count, "retained_history_intervals": history.intervals.count,
                       "encoded_history_bytes": encodedBytes, "summary_checksum_seconds": checksum,
                       "ordered_sessions": ordered.count, "claude_recovered_seconds": claude.report.providers.first?.recoveredSeconds ?? 0,
                       "claude_import_bytes_per_second": Double(claudeBytes) / claudeSeconds,
                       // Linear extrapolation to a 6 GB (6e9 B) Claude archive within the 90 s import budget.
                       "claude_projected_seconds_for_6gb": 6e9 / (Double(claudeBytes) / claudeSeconds)],
            "limitations": ["getrusage max RSS is a cumulative process high-water mark, not a per-phase allocation delta.",
                            "I/O block counters are reported by the OS; zeros can reflect cached I/O and are not zero disk-cost proof.",
                            "Files are freshly generated; caches are not flushed. Fixture generation is measured separately.",
                            "XCTest/build/startup time is outside phase timers; this is not app idle, live-client or battery measurement."]]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }

    /// Each turn: prompt, long thinking, tool call, large tool output, answer,
    /// Stop hook summary and two rows the importer ignores (progress, snapshot).
    private func writeClaudeArchive(to root: URL, workload: Workload, now: Date) throws -> Int {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let common: [String: Any] = ["cwd": "/synthetic/project", "sessionId": "SESSION", "isSidechain": false, "userType": "external",
                                     "version": "2.1.0", "gitBranch": "main", "uuid": "UUID", "parentUuid": "PARENT", "timestamp": "TIMESTAMP"]
        func row(_ type: String, _ extra: [String: Any]) throws -> String { try line(common.merging(extra) { $1 }.merging(["type": type]) { $1 }) }
        let thinking = String(repeating: "synthetic reasoning ", count: 450), output = String(repeating: "synthetic output line\n", count: 560)
        let templates = [
            try row("user", ["message": ["role": "user", "content": "Synthetic prompt"]]),
            try row("assistant", ["message": ["role": "assistant", "model": "synthetic", "content": [["type": "thinking", "thinking": thinking, "signature": "sig"]]]]),
            try row("assistant", ["message": ["role": "assistant", "model": "synthetic", "content": [["type": "tool_use", "id": "toolu_ID", "name": "Bash",
                "input": ["command": String(repeating: "x", count: 1500)]]]]]),
            try row("progress", ["data": ["type": "hook_progress", "hookName": "PostToolUse"]]),
            try row("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_ID", "content": output]]],
                             "toolUseResult": ["stdout": output, "stderr": "", "interrupted": false]]),
            try row("assistant", ["message": ["role": "assistant", "model": "synthetic", "content": [["type": "text", "text": String(repeating: "a", count: 500)]]]]),
            try row("system", ["subtype": "stop_hook_summary", "level": "info", "content": "hooks"]),
            try line(["type": "file-history-snapshot", "messageId": "ID", "snapshot": ["trackedFileBackups": ["file": String(repeating: "b", count: 2000)]]]),
        ]
        let offsets: [TimeInterval] = [0, 5, 20, 21, 80, 95, 96, 96]
        var total = 0
        for file in 0..<workload.claudeFiles {
            try autoreleasepool {
                var text = ""
                let session = UUID().uuidString.lowercased()
                for turn in 0..<workload.claudeTurnsPerFile {
                    // Turns two minutes apart in file order; the first file holds the newest turns.
                    let start = now.addingTimeInterval(-Double(((file + 1) * workload.claudeTurnsPerFile - turn) * 120))
                    for (template, offset) in zip(templates, offsets) {
                        text += template.replacingOccurrences(of: "TIMESTAMP", with: formatter.string(from: start.addingTimeInterval(offset)))
                            .replacingOccurrences(of: "SESSION", with: session).replacingOccurrences(of: "toolu_ID", with: "toolu_\(turn)") + "\n"
                    }
                }
                let data = Data(text.utf8); total += data.count
                let path = root.appendingPathComponent(session + ".jsonl")
                try data.write(to: path)
                try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
            }
        }
        return total
    }

    private func measure(_ name: String, into phases: inout [[String: Any]], operation: () throws -> Void) rethrows {
        var before = rusage(), after = rusage()
        let first = getrusage(RUSAGE_SELF, &before)
        let start = ProcessInfo.processInfo.systemUptime
        try operation()
        let duration = ProcessInfo.processInfo.systemUptime - start
        let last = getrusage(RUSAGE_SELF, &after)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
        var phase: [String: Any] = ["name": name, "wall_seconds": duration,
                                   "resource_counters_status": first == 0 && last == 0 ? "passed" : "unavailable"]
        if first == 0 && last == 0 {
            phase["cpu_user_seconds"] = seconds(after.ru_utime) - seconds(before.ru_utime)
            phase["cpu_system_seconds"] = seconds(after.ru_stime) - seconds(before.ru_stime)
            phase["rss_peak_process_bytes"] = after.ru_maxrss // Darwin reports bytes, not Linux KiB.
            phase["io_input_blocks"] = after.ru_inblock - before.ru_inblock
            phase["io_output_blocks"] = after.ru_oublock - before.ru_oublock
        }
        phases.append(phase)
    }
}
