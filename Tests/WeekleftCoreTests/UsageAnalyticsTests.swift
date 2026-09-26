import XCTest
@testable import WeekleftCore

private actor Captures {
    var requests: [URLRequest] = []
    var response = 200
    func send(_ request: URLRequest) -> Int { requests.append(request); return response }
    func status(_ value: Int) { response = value }
    func all() -> [URLRequest] { requests }
}
private actor SuspendedCapture {
    private var waiting: CheckedContinuation<Int, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    func send(_ request: URLRequest) async -> Int {
        didStart = true; started?.resume(); started = nil
        return await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { waiting?.resume(returning: 200); waiting = nil }
}

final class UsageAnalyticsTests: XCTestCase {
    private let config = UsageAnalyticsConfiguration(token: "phc_0123456789abcdefghijklmnop", host: "https://eu.i.posthog.com")!
    @MainActor private func fixture(configured: Bool = true, now: @escaping () -> Date = Date.init) -> (UsageAnalytics, UserDefaults, Captures, String) {
        let name = "Lunavect.AnalyticsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!, captures = Captures()
        let client = UsageAnalytics(defaults: defaults, configuration: configured ? config : nil, version: "0.2.4", build: "190",
                                    automaticDelivery: false, now: now, transport: { await captures.send($0) })
        return (client, defaults, captures, name)
    }
    private func events(_ request: URLRequest) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return try XCTUnwrap(root["batch"] as? [[String: Any]])
    }
    @MainActor func testUnknownDeniedAndUnconfiguredNeverSend() async {
        for configured in [true, false] {
            let (client, defaults, captures, name) = fixture(configured: configured)
            defer { client.stop(); defaults.removePersistentDomain(forName: name) }
            client.launch(); await client.flush()
            XCTAssertTrue(defaults.persistentDomain(forName: name)?.isEmpty ?? true)
            client.setEnabled(false); client.record(.sessionNavigation(.claude, .vscode, .failed)); await client.flush()
            if !configured { client.setEnabled(true); client.launch(); await client.flush() }
            let sent = await captures.all(); XCTAssertTrue(sent.isEmpty); XCTAssertEqual(client.queuedCount, 0)
        }
    }
    @MainActor func testOnlyConsentIsPersistedAndEveryEventHasIndependentIdentity() async throws {
        let (client, defaults, captures, name) = fixture()
        defer { client.stop(); defaults.removePersistentDomain(forName: name) }
        client.setEnabled(true); client.record(.sessionNavigation(.codex, .jetbrains, .failed)); await client.flush()
        let requests = await captures.all(), request = try XCTUnwrap(requests.first)
        let batch = try events(request)
        XCTAssertEqual(batch.count, 2)
        XCTAssertNotEqual(batch[0]["distinct_id"] as? String, batch[1]["distinct_id"] as? String)
        XCTAssertEqual(Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? []), [UsageAnalytics.decisionKey])
        for event in batch {
            XCTAssertEqual(event["distinct_id"] as? String, event["uuid"] as? String)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(event["uuid"] as? String)))
        }
    }
    @MainActor func testPayloadContainsOnlyDeclaredTechnicalDimensionsAndHourPrecision() async throws {
        let (client, defaults, captures, name) = fixture(now: { Date(timeIntervalSince1970: 1_800_000_123) })
        defer { client.stop(); defaults.removePersistentDomain(forName: name) }
        client.setEnabled(true); client.record(.sessionNavigation(.codex, .jetbrains, .failed)); await client.flush()
        let requests = await captures.all(), request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://eu.i.posthog.com/batch/")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        for event in try events(request) {
            XCTAssertEqual(Set(event.keys), ["event", "distinct_id", "uuid", "timestamp", "properties"])
            let properties = try XCTUnwrap(event["properties"] as? [String: Any])
            let permitted: Set<String> = ["app_version", "app_build", "os_major", "surface", "schema_version", "$geoip_disable", "$process_person_profile", "provider", "client", "outcome"]
            XCTAssertTrue(Set(properties.keys).isSubset(of: permitted))
            XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
            XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: XCTUnwrap(event["timestamp"] as? String)))
            XCTAssertEqual(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600), 0)
        }
    }
    @MainActor func testRevokePurgesQueueAndConsentIsIdempotent() async {
        let (client, defaults, captures, name) = fixture()
        defer { client.stop(); defaults.removePersistentDomain(forName: name) }
        client.setEnabled(true); client.setEnabled(true); XCTAssertEqual(client.queuedCount, 1)
        await client.flush()
        client.record(.sessionNavigation(.claude, .vscode, .failed)); client.setEnabled(false)
        XCTAssertEqual(client.queuedCount, 0)
        await client.flush(); let count = await captures.all().count; XCTAssertEqual(count, 1)
    }
    @MainActor func testRetriesPreserveEventIdentityAndPermanentRejectionDropsBatch() async throws {
        let (client, defaults, captures, name) = fixture()
        defer { client.stop(); defaults.removePersistentDomain(forName: name) }
        await captures.status(503); client.setEnabled(true); await client.flush()
        XCTAssertGreaterThan(client.queuedCount, 0)
        await captures.status(200); await client.flush()
        let requests = await captures.all()
        XCTAssertEqual(try events(requests[0]) as NSArray, try events(requests[1]) as NSArray); XCTAssertEqual(client.queuedCount, 0)
        await captures.status(400); client.launch(); await client.flush(); XCTAssertEqual(client.queuedCount, 0)
    }
    @MainActor func testOldInFlightResponseCannotDrainQueueAfterConsentIsRevokedAndRenewed() async {
        let name = "Lunavect.AnalyticsRace." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!, gate = SuspendedCapture()
        let client = UsageAnalytics(defaults: defaults, configuration: config, version: "0.2.4", build: "190",
                                    automaticDelivery: false, transport: { await gate.send($0) })
        defer { client.stop(); defaults.removePersistentDomain(forName: name) }
        client.setEnabled(true)
        let flush = Task { await client.flush() }; await gate.waitUntilStarted()
        client.setEnabled(false); XCTAssertEqual(client.queuedCount, 0)
        client.setEnabled(true); let newCount = client.queuedCount
        await gate.finish(); await flush.value
        XCTAssertEqual(client.queuedCount, newCount)
    }
    @MainActor func testOnlyChoiceSurvivesRelaunchAndPreviousQueueIsNotReplayed() async throws {
        let (client, defaults, captures, name) = fixture()
        defer { client.stop(); defaults.removePersistentDomain(forName: name) }
        client.setEnabled(true); await client.flush()
        client.record(.sessionNavigation(.codex, .vscode, .failed)); client.stop()
        let restarted = UsageAnalytics(defaults: defaults, configuration: config, version: "0.2.4", build: "190",
                                       automaticDelivery: false, transport: { await captures.send($0) })
        defer { restarted.stop() }
        XCTAssertTrue(restarted.enabled); XCTAssertTrue(restarted.hasDecision)
        restarted.launch(); await restarted.flush()
        let requests = await captures.all(), batch = try events(requests[1])
        XCTAssertEqual(batch.map { $0["event"] as? String }, ["app_launched"])
        XCTAssertNotEqual(batch[0]["distinct_id"] as? String, try events(requests[0])[0]["distinct_id"] as? String)
    }
    @MainActor func testQueueBoundExpiryAndRetryLimit() async {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let (client, defaults, captures, name) = fixture(now: { date })
        defer { client.stop(); defaults.removePersistentDomain(forName: name) }
        client.setEnabled(true)
        for _ in 0..<150 { client.launch() }; XCTAssertEqual(client.queuedCount, 100)
        date = date.addingTimeInterval(86_401); await client.flush()
        XCTAssertEqual(client.queuedCount, 0); let initial = await captures.all(); XCTAssertTrue(initial.isEmpty)
        client.launch(); await captures.status(503)
        for _ in 0..<4 { await client.flush() }; XCTAssertEqual(client.queuedCount, 0)
    }
    func testPersonalKeysAndOtherHostsAreRejected() {
        XCTAssertNil(UsageAnalyticsConfiguration(token: "phx_personal_api_key", host: "https://eu.i.posthog.com"))
        for host in ["https://us.i.posthog.com", "http://eu.i.posthog.com", "https://eu.i.posthog.com.evil.example"] {
            XCTAssertNil(UsageAnalyticsConfiguration(token: config.token, host: host))
        }
    }
}
