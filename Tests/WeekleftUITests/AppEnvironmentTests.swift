import XCTest
import ServiceManagement
import UserNotifications
import WeekleftCore
@testable import Weekleft

@MainActor private final class EnvironmentPermissionSpy: FeaturePermissionAccess {
    var calls = 0
    var pendingStatus: CheckedContinuation<UNAuthorizationStatus, Never>?
    var suspendStatus = false
    var loginStatus: SMAppService.Status { calls += 1; return .enabled }
    func notificationStatus() async -> UNAuthorizationStatus {
        calls += 1
        if suspendStatus { return await withCheckedContinuation { pendingStatus = $0 } }
        return .authorized
    }
    func authorizeNotifications() async throws -> Bool { calls += 1; return true }
    func registerLogin() throws { calls += 1 }
    func unregisterLogin() async throws { calls += 1 }
    func openNotificationSettings() -> Bool { calls += 1; return true }
    func openLoginSettings() { calls += 1 }
}

final class AppEnvironmentTests: XCTestCase {
    func testInstanceLeaseRejectsConcurrentWriterAndReleasesOnClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = try AppInstanceLease.acquire(directory: directory)
        XCTAssertNotNil(first)
        XCTAssertNil(try AppInstanceLease.acquire(directory: directory))
        first = nil
        let next = try AppInstanceLease.acquire(directory: directory)
        XCTAssertNotNil(next)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("app-instance.lock").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        withExtendedLifetime(next) {}
    }

    func testInstanceLeaseDoesNotFollowSymlinkOrModifyTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("unrelated.txt")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("app-instance.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try AppInstanceLease.acquire(directory: directory))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    @MainActor func testActivityContinuityBalancesLeaseAcrossIndependentReasons() {
        var began = 0
        var ended = 0
        let token = NSObject()
        let continuity = ActivityContinuity(begin: { began += 1; return token }, end: {
            XCTAssertTrue(($0 as AnyObject) === token)
            ended += 1
        })
        continuity.setRunning(false)
        XCTAssertEqual(began, 0)
        continuity.setRunning(true)
        continuity.setRunning(true)
        continuity.setKeepAwake(true)
        continuity.setRunning(false)
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, 0, "The helper still needs heartbeats after a session finishes")
        continuity.setKeepAwake(false)
        XCTAssertEqual(ended, 1)
        continuity.setRunning(true)
        continuity.stop()
        continuity.stop()
        XCTAssertEqual(began, 2)
        XCTAssertEqual(ended, 2)
    }
    func testPreviewArgumentsFailClosedBeforeLiveLaunch() throws {
        XCTAssertNil(try AppPreviewRequest.parse(["app"], enabled: false))
        for arguments in [["app", "--session-preview"], ["app", "--render-native", "--probe"],
                          ["app", "--session-preview", "a", "--render-native", "b"]] {
            XCTAssertThrowsError(try AppPreviewRequest.parse(arguments, enabled: true))
        }
        XCTAssertThrowsError(try AppPreviewRequest.parse(["app", "--session-preview", "a"], enabled: false))
        XCTAssertEqual(try AppPreviewRequest.parse(["app", "--render-native", "/tmp/example.png"], enabled: true),
                       .render(URL(fileURLWithPath: "/tmp/example.png")))
    }

    @MainActor func testPreviewOwnsStateAndCannotStartLiveServices() async throws {
        let first = try AppEnvironment.preview(rows: [], languageCode: "de")
        let second = try AppEnvironment.preview(rows: [], languageCode: "ru")
        defer { first.stop(); second.stop() }
        XCTAssertEqual(first.language.code, "de")
        first.language.code = "fr"
        first.defaults.set("connections", forKey: "settingsSection")
        XCTAssertEqual(second.language.code, "ru")
        XCTAssertNil(second.defaults.string(forKey: "settingsSection"))
        first.features.start(); first.updates.start(); first.store.start()
        first.sessions.start(clientResolver: { ClientExecutableResolver(codexPath: "") })
        await first.features.setLogin(true)
        await first.features.setBanners(true)
        first.features.openPermissionSettings(.notifications)
        XCTAssertFalse(first.updates.configured)
        XCTAssertFalse(first.features.banners)
        XCTAssertNil(first.features.waitingPermission)
        XCTAssertFalse(first.awake.isAvailable)
        first.awake.requestPermission()
        XCTAssertFalse(first.awake.isAwaitingPermission)
        XCTAssertFalse(first.awake.isEnabled)
        XCTAssertTrue(first.store.snapshots.allSatisfy { !$0.hasQuota })
    }

    @MainActor func testIsolatedFeaturesNeverTouchInjectedSystemAccessOrSound() async throws {
        let name = "Lunavect.EnvironmentTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let access = EnvironmentPermissionSpy()
        var sounds = 0, banners = 0
        let features = AppFeatures(defaults: defaults, permissionAccess: access,
            playSound: { _ in sounds += 1 }, sendBanner: { _, _ in banners += 1 }, isolated: true)
        features.sounds = true; features.banners = true
        features.start(); features.refreshSystemState(); await features.checkSystemState()
        await features.setLogin(true); await features.setBanners(true)
        features.openPermissionSettings(.login); features.openPermissionSettings(.notifications)
        features.testNotification(); features.previewCompletionSound()
        features.registerShortcut(PanelShortcut(keyCode: 0, modifiers: 0, label: "Preview"))
        features.stop()
        XCTAssertEqual(access.calls, 0); XCTAssertEqual(sounds, 0); XCTAssertEqual(banners, 0)
        XCTAssertNil(features.shortcut)
    }

    @MainActor func testPermissionResultAfterStopCannotPublishState() async throws {
        let name = "Lunavect.EnvironmentTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let access = EnvironmentPermissionSpy(); access.suspendStatus = true
        let features = AppFeatures(defaults: defaults, permissionAccess: access)
        let query = Task { await features.checkSystemState() }
        for _ in 0..<200 where access.pendingStatus == nil { await Task.yield() }
        let pending = try XCTUnwrap(access.pendingStatus)
        features.stop()
        pending.resume(returning: .authorized)
        await query.value
        XCTAssertEqual(features.launchStatus, .notRegistered)
        XCTAssertEqual(features.notificationAuthorization, .notDetermined)
        XCTAssertFalse(features.notificationAllowed)
    }
}
