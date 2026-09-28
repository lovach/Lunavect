import XCTest
@testable import WeekleftCore

/// Wall-clock jumps while the app observes: a clock set far ahead and then
/// corrected must not stop live collection in the corrected present (R2-P).
final class ActivityClockJumpTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(at date: Date, phase: SessionPhase = .running) -> AgentSession {
        AgentSession(provider: .claude, sessionID: "fixture", title: "Synthetic", cwd: "/tmp/fixture", phase: phase,
                     updatedAt: date, observedAt: date, evidence: .localEvent, runtimeConfirmed: true)
    }
    private func observe(_ tracker: inout ActivityTracker, from start: Date, seconds: [TimeInterval]) {
        for offset in seconds { tracker.observe([row(at: start.addingTimeInterval(offset))], now: start.addingTimeInterval(offset)) }
    }

    func testCorrectedForwardJumpKeepsRecordingThePresent() {
        for jump in [40.0, 400.0] {
            var tracker = ActivityTracker()
            observe(&tracker, from: base, seconds: [0, 5, 10])
            // The clock is set `jump` days ahead for a moment, then corrected.
            let ahead = base.addingTimeInterval(jump * 86400)
            observe(&tracker, from: ahead, seconds: [0, 5])
            let present = base.addingTimeInterval(3600)
            observe(&tracker, from: present, seconds: [0, 5, 10, 15, 20])
            XCTAssertEqual(tracker.history.summary(now: present.addingTimeInterval(20), period: .day).totals.claude, 20,
                           "\(Int(jump)) days ahead: work observed after the correction is recorded")
            // A restart after the correction reconciles the same way.
            var restarted = ActivityTracker(history: tracker.history, details: tracker.details)
            let later = present.addingTimeInterval(600)
            observe(&restarted, from: later, seconds: [0, 5, 10])
            XCTAssertEqual(restarted.history.summary(now: later.addingTimeInterval(10), period: .day).totals.claude, 30,
                           "\(Int(jump)) days ahead: a restarted tracker records the present too")
            XCTAssertEqual(restarted.details.records.values.first?.totals(in: DateInterval(start: present, end: later.addingTimeInterval(10))).active, 30)
        }
    }

    /// Property check with fixed seeds: random sessions, phases and providers,
    /// observed at 1-20 s steps of real time while the wall clock occasionally
    /// jumps back or far ahead, the app sleeps or restarts. Whatever happens,
    /// the files stay loadable and live work never exceeds the real time that
    /// passed (no second is counted twice, P-I1/P-I10).
    func testRandomObservationsWithClockJumpsStayLoadableAndNeverExceedRealTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityClockJumpTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("activity.json"), detailsURL = directory.appendingPathComponent("activity-details.json")
        for initial in [0x6C756E61 as UInt64, 0x72322D50, 0x5452414E] {
            var seed = initial
            func next(_ limit: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(limit))
            }
            var tracker = ActivityTracker(), real: TimeInterval = 0, offset: TimeInterval = 0
            let phases: [SessionPhase] = [.running, .running, .running, .input, .idle, .ready, .unknown, .permission]
            for step in 0..<3_000 {
                real += Double(1 + next(20))
                switch next(1_000) {
                case 0..<4: offset -= Double(60 + next(7_200))            // clock set back
                case 4..<6: offset += Double(36 + next(400)) * 86_400     // clock set far ahead
                case 6..<8: offset = 0                                     // clock corrected
                case 8..<14: tracker.interruptObservation()               // sleep or wake
                case 14..<17: tracker = ActivityTracker(history: tracker.history, details: tracker.details) // restart
                default: break
                }
                let now = base.addingTimeInterval(real + offset)
                let rows = (0..<3).compactMap { index -> AgentSession? in
                    guard next(5) != 0 else { return nil }
                    return AgentSession(provider: index == 2 ? .codex : .claude, sessionID: "fixture-\(index)", title: "Synthetic",
                        cwd: "/tmp/fixture", phase: phases[next(phases.count)], updatedAt: now, observedAt: now,
                        evidence: .localEvent, runtimeConfirmed: true)
                }
                tracker.observe(rows, now: now)
                if step % 500 == 499 || step == 2_999 {
                    try tracker.history.save(to: historyURL)
                    XCTAssertEqual(try ActivityHistory.load(from: historyURL), tracker.history, "seed \(initial) step \(step)")
                    try tracker.details.save(to: detailsURL)
                    XCTAssertNoThrow(try ActivityDetails.load(from: detailsURL), "seed \(initial) step \(step)")
                }
            }
            let active = tracker.history.intervals.filter { $0.providers != 0 }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            XCTAssertLessThanOrEqual(active, real, "seed \(initial): recorded work cannot exceed the real time that passed")
            for record in tracker.details.records.values {
                let seconds = ActivityHistory.union(record.intervals).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                XCTAssertLessThanOrEqual(seconds, real, "seed \(initial): \(record.sessionID)")
            }
            XCTAssertGreaterThan(active, 0, "seed \(initial): the sequence records some work")
        }
    }

    /// Retention removes only an expired prefix (R2-R-03). That is correct only
    /// while intervals stay ordered and disjoint, so a seeded run of live
    /// observations with clock jumps, recovered imports and save/load round
    /// trips checks that order after every step, and that every step which
    /// changed the history left nothing older than 35 days before its time.
    func testRetentionKeepsOrderedIntervalsAndDropsEveryExpiredOne() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityClockJumpTests-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        func assertOrdered(_ history: ActivityHistory, _ context: String) {
            var previous = Date.distantPast
            for span in history.intervals {
                XCTAssertLessThan(span.start, span.end, context)
                XCTAssertGreaterThanOrEqual(span.start, previous, "ordered and disjoint: \(context)")
                previous = span.end
            }
        }
        func assertRetained(_ history: ActivityHistory, at date: Date, _ context: String) {
            let cutoff = date.addingTimeInterval(-35 * 86400)
            XCTAssertFalse(history.intervals.contains { $0.end <= cutoff }, "nothing expired remains: \(context)")
        }
        for initial in [0x70727566 as UInt64, 0x52322D52, 0x31323334] {
            var seed = initial
            func next(_ limit: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(limit))
            }
            var tracker = ActivityTracker(), real: TimeInterval = 0, offset: TimeInterval = 0
            for step in 0..<4_000 {
                real += Double(1 + next(12))
                switch next(1_000) {
                case 0..<3: offset -= Double(60 + next(7_200))
                case 3..<6: offset += Double(1 + next(60)) * 86_400   // up to two months ahead
                case 6..<9: offset = 0
                case 9..<14: tracker.interruptObservation()
                default: break
                }
                let now = base.addingTimeInterval(real + offset), context = "seed \(initial) step \(step)"
                if next(200) == 0 {
                    // A recovered import before the first observation, partly outside the window.
                    var result = ActivityImportResult()
                    result.intervals = (0..<5).map { _ in
                        let start = now.addingTimeInterval(-Double(next(50 * 86_400)))
                        return ActivityInterval(start: start, end: start.addingTimeInterval(Double(60 + next(7_200))), providers: 1 + next(3), recovered: true)
                    }
                    tracker.mergeImport(result, now: now, providers: [.claude, .codex])
                    assertOrdered(tracker.history, context + " import")
                    assertRetained(tracker.history, at: now, context + " import")
                    continue
                }
                let before = tracker.history
                let phase: SessionPhase = next(4) == 0 ? .idle : .running
                let rows = [AgentSession(provider: next(2) == 0 ? .claude : .codex, sessionID: "fixture", title: "Synthetic", cwd: "/tmp/fixture",
                                         phase: phase, updatedAt: now, observedAt: now, evidence: .localEvent, runtimeConfirmed: true)]
                tracker.observe(rows, now: now)
                assertOrdered(tracker.history, context)
                // A dropped-gap diagnostic changes the history without an interval (no retention step).
                if tracker.history.intervals != before.intervals { assertRetained(tracker.history, at: now, context) }
                if step % 400 == 399 {
                    try tracker.history.save(to: url)
                    let loaded = try ActivityHistory.load(from: url)
                    XCTAssertEqual(loaded, tracker.history, context)
                    tracker = ActivityTracker(history: loaded, details: tracker.details)
                }
            }
        }
    }

    func testAJumpBeyondTheWindowDropsEveryOlderIntervalNotOnlyTheFirst() {
        var history = ActivityHistory()
        for index in 0..<100 {
            let start = base.addingTimeInterval(Double(index) * 600)
            history.append(start: start, end: start.addingTimeInterval(60), providers: 1 + index % 2)
        }
        XCTAssertEqual(history.intervals.count, 100)
        let later = base.addingTimeInterval(36 * 86400)
        history.append(start: later, end: later.addingTimeInterval(5), providers: 1)
        XCTAssertEqual(history.intervals.map(\.start), [later])
        // An interval that crosses the cutoff is kept and starts at the cutoff.
        var crossing = ActivityHistory()
        crossing.append(start: base, end: base.addingTimeInterval(7200), providers: 1)
        crossing.append(start: base.addingTimeInterval(7200), end: base.addingTimeInterval(7200 + 1), providers: 2)
        let edge = base.addingTimeInterval(35 * 86400 + 3600)
        crossing.append(start: edge, end: edge.addingTimeInterval(5), providers: 1)
        XCTAssertEqual(crossing.intervals.first?.start, base.addingTimeInterval(3600 + 5))
        XCTAssertEqual(crossing.intervals.count, 3)
    }
}
