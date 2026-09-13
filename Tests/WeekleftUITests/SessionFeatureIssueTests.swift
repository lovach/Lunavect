import XCTest
import ServiceManagement
import UserNotifications
@testable import Weekleft

@MainActor private final class FailingFeaturePermissions: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status = .notRegistered
    func notificationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func authorizeNotifications() async throws -> Bool { throw CocoaError(.featureUnsupported) }
    func registerLogin() throws { throw CocoaError(.featureUnsupported) }
    func unregisterLogin() async throws {}
    func openNotificationSettings() -> Bool { false }
    func openLoginSettings() {}
}
final class SessionFeatureIssueTests: XCTestCase {
    @MainActor func testNotificationCallbacksCarryOnlyValuesAndStopWithFeatureLifecycle() async throws {
        let suite = "Lunavect.NotificationCallbacks." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = AppFeatures(defaults: defaults, permissionAccess: FailingFeaturePermissions(), playSound: { _ in })
        features.banners = true; features.sounds = true
        var opened: [String] = []
        features.onOpenSession = { opened.append($0) }
        let options = await Task.detached { await features.notificationPresentationOptions(hasSound: true) }.value
        XCTAssertEqual(options, [.banner, .list, .sound])
        await Task.detached { await features.receiveNotificationResponse(sessionID: "claude:fixture") }.value
        XCTAssertEqual(opened, ["claude:fixture"])
        features.stop()
        let stopped = await Task.detached { await features.notificationPresentationOptions(hasSound: true) }.value
        XCTAssertTrue(stopped.isEmpty)
        await Task.detached { await features.receiveNotificationResponse(sessionID: "claude:late") }.value
        XCTAssertEqual(opened, ["claude:fixture"])
    }
    @MainActor func testLoginAndNotificationFailuresRemainOnTheirOwnSettingsPage() async throws {
        let suite = "Lunavect.FeatureIssue." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = AppFeatures(defaults: defaults, permissionAccess: FailingFeaturePermissions(), playSound: { _ in })
        defer { features.stop() }
        await features.setLogin(true)
        let loginIssue = try XCTUnwrap(features.generalIssue)
        XCTAssertNil(features.notificationIssue)
        await features.setBanners(true)
        XCTAssertNotNil(features.notificationIssue)
        XCTAssertEqual(features.generalIssue, loginIssue)
        await features.setBanners(false)
        XCTAssertNil(features.notificationIssue)
        XCTAssertEqual(features.generalIssue, loginIssue)
        XCTAssertEqual(features.issue, loginIssue)
        await features.setLogin(false)
        XCTAssertNil(features.generalIssue)
        XCTAssertNil(features.notificationIssue)
        XCTAssertNil(features.issue)
    }
}
