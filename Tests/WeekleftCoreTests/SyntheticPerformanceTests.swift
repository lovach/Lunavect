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
        static func named(_ name: String) throws -> Self {
            switch name {
            case "quick": return .init(files: 16, recordsPerFile: 32, sessions: 250, repetitions: 4)
            case "large": return .init(files: 256, recordsPerFile: 256, sessions: 5000, repetitions: 20)
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
                         "sessions": workload.sessions, "repetitions": workload.repetitions,
                         "fixed_now_unix_seconds": now.timeIntervalSince1970],
            "result": ["recovered_intervals": imported.intervals.count, "retained_history_intervals": history.intervals.count,
                       "encoded_history_bytes": encodedBytes, "summary_checksum_seconds": checksum,
                       "ordered_sessions": ordered.count],
            "limitations": ["getrusage max RSS is a cumulative process high-water mark, not a per-phase allocation delta.",
                            "I/O block counters are reported by the OS; zeros can reflect cached I/O and are not zero disk-cost proof.",
                            "Files are freshly generated; caches are not flushed. Fixture generation is measured separately.",
                            "XCTest/build/startup time is outside phase timers; this is not app idle, live-client or battery measurement."]]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
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
