import XCTest
@testable import WeekleftCore

final class ActivityProvenanceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testLaterProviderImportKeepsLiveSourceAndCombinedWallTimeThroughPersistence() throws {
        let end = start.addingTimeInterval(60)
        var history = ActivityHistory()
        _ = history.prepareImport(providers: [.claude], now: start)
        history.append(start: start, end: end, providers: 1, observedProviders: 1)
        let imported = [ActivityInterval(start: start, end: end, providers: 2)]
        history.mergeRecovered(imported, now: end, limited: false, providers: [.codex])
        let original = history
        history.mergeRecovered(imported, now: end, limited: false, providers: [.codex])
        XCTAssertEqual(history, original, "Retry preserves provenance as well as durations")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("activity.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try history.save(to: file)
        history = try ActivityHistory.load(from: file)
        XCTAssertEqual(history, original)
        XCTAssertEqual(history.intervals.first?.recoveredProviderMask, 2)
        XCTAssertEqual(history.intervals.first?.liveObservedProviderMask, 1)
        for providers: [ProviderID] in [[.claude], [.codex], [.claude, .codex]] {
            let summary = history.summary(now: end, providers: providers)
            XCTAssertEqual(summary.totals.active, 60)
            XCTAssertEqual(summary.totals.recovered, providers == [.codex] ? 60 : 0)
            XCTAssertEqual(summary.lastLiveObservedAt, providers == [.codex] ? nil : end)
            XCTAssertEqual(summary.lastObservedAt, end)
        }
    }

    func testLiveIdleSourceAndImportedWorkRemainSeparate() {
        let end = start.addingTimeInterval(60)
        var history = ActivityHistory()
        history.append(start: start, end: end, providers: 0, observedProviders: 1)
        history.mergeRecovered([.init(start: start, end: end, providers: 2)], now: end, limited: false, providers: [.codex])
        let claude = history.summary(now: end, providers: [.claude])
        XCTAssertEqual(claude.totals.observed, 60)
        XCTAssertEqual(claude.totals.active, 0)
        XCTAssertEqual(claude.lastLiveObservedAt, end)
        let codex = history.summary(now: end, providers: [.codex])
        XCTAssertEqual(codex.totals.recovered, 60)
        XCTAssertNil(codex.lastLiveObservedAt)
        XCTAssertEqual(history.summary(now: end).totals.recovered, 60)
    }

    func testPartialSameSourceLiveOverlapWinsOnlyWithinItsBounds() throws {
        let spans: [ActivityInterval] = [
            .init(start: start, end: start.addingTimeInterval(60), providers: 2, recovered: true),
            .init(start: start.addingTimeInterval(20), end: start.addingTimeInterval(40), providers: 2, observedProviders: 2)
        ]
        let union = ActivityHistory.union(spans)
        XCTAssertEqual(union.map(\.recoveredProviderMask), [2, 0, 2])
        XCTAssertEqual(union.map(\.liveObservedProviderMask), [0, 2, 0])
        let totals = ActivityDetailRecord(provider: .codex, sessionID: "fixture", intervals: union)
            .totals(in: DateInterval(start: start, duration: 60))
        XCTAssertEqual(totals.active, 60)
        XCTAssertEqual(totals.recovered, 40)
        let live = ActivityDetailRecord(provider: .claude, sessionID: "live", intervals: [
            .init(start: start, end: start.addingTimeInterval(60), providers: 1, observedProviders: 1)
        ])
        let imported = ActivityDetailRecord(provider: .codex, sessionID: "imported", intervals: [spans[0]])
        let combined = ActivityDetails.totals(for: [live, imported], in: DateInterval(start: start, duration: 60))
        XCTAssertEqual(combined.active, 60)
        XCTAssertEqual(combined.recovered, 0)
    }

    func testLegacyProvenanceDecodesWithoutInventingLiveEvidence() throws {
        let data = Data(
            "{\"intervals\":[{\"start\":800000000,\"end\":800000060,\"providers\":3,\"recovered\":true,\"observedProviders\":3},{\"start\":800000060,\"end\":800000120,\"providers\":1,\"observedProviders\":1}]}"
                .utf8)
        let history = try JSONDecoder().decode(ActivityHistory.self, from: data)
        XCTAssertEqual(history.intervals.map(\.recoveredProviderMask), [3, 0])
        XCTAssertEqual(history.intervals.map(\.liveObservedProviderMask), [0, 1])
        let end = try XCTUnwrap(history.intervals.last?.end)
        XCTAssertNil(history.summary(now: end, providers: [.codex]).lastLiveObservedAt)
        XCTAssertEqual(history.summary(now: end, providers: [.claude]).lastLiveObservedAt, end)
    }
    func testSeededOverlapMatrixMatchesAnIndependentSecondBySecondOracle() {
        var seed: UInt64 = 0x6C756E61
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        for sample in 0..<100 {
            let spans = (0..<25).map { _ -> ActivityInterval in
                let first = next(120), last = next(120), mask = next(4), observed = mask | next(4)
                return ActivityInterval(start: start.addingTimeInterval(Double(first)), end: start.addingTimeInterval(Double(last)),
                    providers: mask, recovered: next(2) == 0, observedProviders: observed)
            }
            let merged = ActivityHistory.union(spans)
            XCTAssertEqual(ActivityHistory.union(Array(spans.reversed())), merged, "Input order, sample \(sample)")
            XCTAssertEqual(ActivityHistory.union(merged + spans), merged, "Retry cannot double count, sample \(sample)")
            for second in 0..<120 {
                let date = start.addingTimeInterval(Double(second) + 0.5)
                let covering = spans.filter { $0.start <= date && date < $0.end }
                let result = merged.filter { $0.start <= date && date < $0.end }
                XCTAssertEqual(result.count, covering.isEmpty ? 0 : 1, "At most one result for each real second")
                guard let actual = result.first else { continue }
                let active = covering.reduce(0) { $0 | $1.providers }
                let live = covering.filter { $0.recovered != true }.reduce(0) { $0 | $1.providers }
                let observed = covering.reduce(0) { $0 | ($1.observedProviders ?? 0) }
                let liveObserved = covering.filter { $0.recovered != true }.reduce(0) { $0 | ($1.observedProviders ?? 0) }
                XCTAssertEqual(actual.providers, active)
                XCTAssertEqual(actual.knownProviders, observed)
                XCTAssertEqual(actual.recoveredProviderMask, active & ~live)
                XCTAssertEqual(actual.liveObservedProviderMask, liveObserved)
            }
        }
    }
}
