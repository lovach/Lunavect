import XCTest
import ServiceManagement
import UserNotifications
@testable import Weekleft

@MainActor private final class DelayedFeatureStatus: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status = .enabled
    var requests = 0
    var pending: [Int: CheckedContinuation<UNAuthorizationStatus, Never>] = [:]
    var onRequest: (Int) -> Void = { _ in }
    func notificationStatus() async -> UNAuthorizationStatus {
        requests += 1
        let id = requests
        return await withCheckedContinuation { pending[id] = $0; onRequest(id) }
    }
    func resolve(_ id: Int, _ status: UNAuthorizationStatus) { pending.removeValue(forKey: id)?.resume(returning: status) }
    func finish() {
        let remaining = pending.values; pending.removeAll()
        for continuation in remaining { continuation.resume(returning: .notDetermined) }
    }
    func authorizeNotifications() async throws -> Bool { false }
    func registerLogin() throws {}
    func unregisterLogin() async throws {}
    func openNotificationSettings() -> Bool { false }
    func openLoginSettings() {}
}

final class AppFeatureRefreshRegressionTests: XCTestCase {
    @MainActor func testRepeatedRefreshWhileStatusIsPendingPublishesLatestResult() async throws {
        let name = "Lunavect.FeatureRefresh." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let access = DelayedFeatureStatus()
        let features = AppFeatures(defaults: defaults, permissionAccess: access)
        defer { features.stop(); access.finish(); defaults.removePersistentDomain(forName: name) }
        let first = expectation(description: "First status query starts")
        let followup = expectation(description: "A queued refresh reads the latest status")
        access.onRequest = { id in if id == 1 { first.fulfill() }; if id == 2 { followup.fulfill() } }
        features.refreshSystemState()
        await fulfillment(of: [first], timeout: 1)
        for _ in 0..<20 { features.refreshSystemState() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(access.requests, 1, "Pending refreshes must not overlap the system query")
        access.resolve(1, .authorized)
        await fulfillment(of: [followup], timeout: 1)
        XCTAssertEqual(features.notificationAuthorization, .authorized,
                       "Refreshing again must not discard the only completed status query")
        guard access.pending[2] != nil else { return }
        access.resolve(2, .denied)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(access.requests, 2, "A burst coalesces into one follow-up query")
        XCTAssertEqual(features.notificationAuthorization, .denied)
        XCTAssertFalse(features.notificationAllowed)
        XCTAssertEqual(features.launchStatus, .enabled)
    }

    @MainActor func testStopDiscardsQueuedRefreshAndLatePermissionResult() async throws {
        let name = "Lunavect.FeatureRefresh." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let access = DelayedFeatureStatus()
        let features = AppFeatures(defaults: defaults, permissionAccess: access)
        defer { features.stop(); access.finish(); defaults.removePersistentDomain(forName: name) }
        let first = expectation(description: "Status query starts")
        access.onRequest = { id in if id == 1 { first.fulfill() } }
        features.refreshSystemState()
        await fulfillment(of: [first], timeout: 1)
        features.refreshSystemState(); features.stop()
        access.resolve(1, .authorized)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(access.requests, 1)
        XCTAssertEqual(features.notificationAuthorization, .notDetermined)
        XCTAssertFalse(features.notificationAllowed)
    }

    @MainActor func testRestartWaitsForOldQueryAndThenFetchesFreshState() async throws {
        let name = "Lunavect.FeatureRefresh." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let access = DelayedFeatureStatus()
        let features = AppFeatures(defaults: defaults, permissionAccess: access)
        defer { features.stop(); access.finish(); defaults.removePersistentDomain(forName: name) }
        let first = expectation(description: "Old lifecycle query starts")
        let restarted = expectation(description: "New lifecycle eventually reads fresh state")
        access.onRequest = { id in if id == 1 { first.fulfill() }; if id == 2 { restarted.fulfill() } }
        features.start()
        await fulfillment(of: [first], timeout: 1)
        features.stop(); features.start()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(access.requests, 1)
        access.resolve(1, .authorized)
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(features.notificationAuthorization, .notDetermined,
                       "The previous lifecycle must not publish its authorized result")
        guard access.pending[2] != nil else { return }
        access.resolve(2, .denied)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(features.notificationAuthorization, .denied)
        XCTAssertFalse(features.notificationAllowed)
    }
}
