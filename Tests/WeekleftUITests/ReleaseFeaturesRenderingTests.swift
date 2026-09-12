import XCTest
import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
@testable import Weekleft
import WeekleftCore

final class ReleaseFeaturesRenderingTests: XCTestCase {
    @MainActor func testDeniedNotificationPermissionReturnsToSettingsAndFinishesOnce() async throws {
        let suite = "FeaturePermissionTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFeaturePermissions(); client.notifications = .denied
        let features = AppFeatures(defaults: defaults, permissionAccess: client)
        var returns = 0; features.onPermissionFinished = { returns += 1 }
        await features.setBanners(true)
        XCTAssertEqual(client.openedNotifications, 1); XCTAssertEqual(client.requests, 0)
        XCTAssertFalse(features.banners)
        client.notifications = .authorized
        await features.checkSystemState(); await Task.yield(); await features.checkSystemState()
        XCTAssertTrue(features.banners); XCTAssertNil(features.waitingPermission); XCTAssertEqual(returns, 1)
    }
    @MainActor func testFreshNotificationDenialDoesNotReopenSettings() async throws {
        let suite = "FeaturePermissionTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFeaturePermissions(); client.grant = false
        let features = AppFeatures(defaults: defaults, permissionAccess: client)
        await features.setBanners(true)
        XCTAssertEqual(client.requests, 1); XCTAssertEqual(client.openedNotifications, 0)
        XCTAssertFalse(features.banners); XCTAssertNil(features.waitingPermission)
    }
    @MainActor func testCancelledAndExpiredPermissionsDoNotEnableNotificationsLater() async throws {
        let suite = "FeaturePermissionTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFeaturePermissions(); client.notifications = .denied
        var now = Date()
        let features = AppFeatures(defaults: defaults, permissionAccess: client, now: { now })
        await features.setBanners(true); await features.cancelPermissionWait()
        client.notifications = .authorized; await features.checkSystemState()
        XCTAssertFalse(features.banners)
        client.notifications = .denied
        await features.setBanners(true); now += 601
        client.notifications = .authorized
        await features.checkSystemState(); await Task.yield(); await features.checkSystemState()
        XCTAssertFalse(features.banners); XCTAssertNil(features.waitingPermission)
    }
    @MainActor func testPendingLoginRegistrationOpensSettingsEvenWhenRegisterThrows() async throws {
        let suite = "FeaturePermissionTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFeaturePermissions(); client.loginNeedsApproval = true
        let features = AppFeatures(defaults: defaults, permissionAccess: client)
        var returns = 0; features.onPermissionFinished = { returns += 1 }
        await features.setLogin(true)
        XCTAssertEqual(client.openedLogin, 1); XCTAssertEqual(features.waitingPermission, .login)
        client.loginStatus = .enabled
        await features.checkSystemState(); await Task.yield(); await features.checkSystemState()
        XCTAssertNil(features.waitingPermission); XCTAssertEqual(returns, 1)
    }
    @MainActor func testOfflineCacheSurvivesAndNetworkRestorationRefreshesOnce() async throws {
        let network = NetworkConnection(settle: {})
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let old = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: nil), fetchedAt: Date())
        let finished = expectation(description: "Network restored")
        var calls = 0, restored = 0
        let store = AppStore(state: SharedState(snapshots: [old], preferences: preferences), savesChanges: false, quotaFetcher: { id, _ in
            calls += 1
            return try UsageSnapshot(provider: id, weekly: QuotaWindow(usedPercent: 41, durationMinutes: 10080, resetsAt: nil), fetchedAt: Date())
        }, network: network)
        store.onNetworkRestored = { restored += 1; finished.fulfill() }
        network.update(available: false); await store.refresh()
        XCTAssertEqual(calls, 0); XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 40); XCTAssertNil(store.snapshots.first?.issue)
        network.update(available: true); network.update(available: true)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(calls, 1); XCTAssertEqual(restored, 1); XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 41)
    }
    @MainActor func testTargetedRetryDoesNotPollAnotherProvider() async {
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude, .codex]
        var calls: [ProviderID] = []
        let store = AppStore(state: SharedState(preferences: preferences), savesChanges: false, quotaFetcher: { id, _ in calls.append(id); return UsageSnapshot(provider: id) })
        await store.refresh(provider: .codex)
        XCTAssertEqual(calls, [.codex])
    }
    @MainActor func testUnstableNetworkCancelsRecovery() async {
        var gate: CheckedContinuation<Void, Never>?
        let network = NetworkConnection(settle: { await withCheckedContinuation { gate = $0 } })
        var calls = 0; network.onRestored = { calls += 1 }
        network.update(available: true)
        XCTAssertEqual(calls, 0)
        network.update(available: false); network.update(available: true)
        while gate == nil { await Task.yield() }
        network.update(available: false); gate?.resume()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(calls, 0); XCTAssertFalse(network.restoring)
    }
    @MainActor func testWidgetRegistrationNeverSkipsDesktopPlacement() async {
        var kinds = ["OtherWidget"]
        var fail = false
        let status = WidgetSetupStatus(fetch: { if fail { throw CocoaError(.fileReadUnknown) }; return kinds })
        await status.check(); XCTAssertEqual(status.state, .missing); XCTAssertEqual(status.nextStep(after: 1), 2)
        kinds = ["LunavectActivityWidget"]
        await status.check(); XCTAssertEqual(status.state, .registered); XCTAssertEqual(status.nextStep(after: 1), 2)
        fail = true
        await status.check(); XCTAssertEqual(status.state, .unavailable); XCTAssertEqual(status.nextStep(after: 1), 2)
    }
    @MainActor func testNativeSimplifiedFlows() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SIMPLIFY"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = WidgetSetupStatus(fetch: { [] }); await missing.check()
        let added = WidgetSetupStatus(fetch: { ["WeekleftWidget"] }); await added.check()
        try await render(WidgetSetupGuide(status: missing).padding(20), width: 570, height: 350, to: directory.appendingPathComponent("widget-missing.png"))
        try await render(WidgetSetupGuide(status: added).padding(20), width: 570, height: 410, to: directory.appendingPathComponent("widget-added.png"))
        let network = NetworkConnection(); network.update(available: false)
        try await render(NetworkStatusView(network: network).padding(20), width: 570, height: 120, to: directory.appendingPathComponent("offline.png"))
        let client = FakeFeaturePermissions(); client.notifications = .denied
        let suite = "FeaturePermissionRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let features = AppFeatures(defaults: defaults, permissionAccess: client)
        await features.setBanners(true)
        try await render(PermissionWaitView(features: features, kind: .notifications).padding(20), width: 570, height: 220, to: directory.appendingPathComponent("permission-wait.png"))
        await features.cancelPermissionWait()
    }
    @MainActor func testUnconfiguredUpdaterDoesNotStart() {
        let updater = AppUpdates(); updater.start()
        XCTAssertFalse(updater.configured); XCTAssertFalse(updater.canCheck); XCTAssertEqual(updater.phase, .unavailable)
    }
    @MainActor func testSparkleCallbacksAreActuallyExposedToObjectiveC() {
        let updater = AppUpdates()
        for selector in ["updater:didFindValidUpdate:", "updater:willDownloadUpdate:withRequest:",
                         "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:", "updater:userDidMakeChoice:forUpdate:state:",
                         "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                         "standardUserDriverWillHandleShowingUpdate:forUpdate:state:"] {
            XCTAssertTrue(updater.responds(to: NSSelectorFromString(selector)), selector)
        }
    }
    @MainActor func testNativeReleaseFeatures() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_RELEASE"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: directory.appendingPathComponent("sessions")), store = AppStore()
        store.snapshots = []
        for step in 0..<4 {
            try await render(WelcomeView(store: store, sessions: sessions, onFinish: {}, step: step), width: 640, height: 620, to: directory.appendingPathComponent("welcome-\(step).png"))
        }
        let diagnostics = ConnectionDiagnostics()
        diagnostics.results = [ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: true,
            snapshot: UsageSnapshot(provider: .claude, issue: UsageError.claudeUsageUnavailable.errorDescription), sessionIssue: nil),
            ConnectionDiagnostic(provider: .codex, clientFound: false, signIn: .unavailable, eventsConfigured: false, snapshot: nil, sessionIssue: nil)]
        try await render(ConnectionDiagnosticsView(store: store, sessions: sessions, diagnostics: diagnostics, onConnect: { _, _ in }), width: 620, height: 640, to: directory.appendingPathComponent("diagnostics.png"))
        let updates = AppUpdates()
        try await render(UpdateSettingsView(updates: updates).padding(24), width: 590, height: 400, to: directory.appendingPathComponent("updates-unconfigured.png"))
        updates.phase = .ready("0.2.0"); updates.canCheck = true
        try await render(UpdateNoticeView(updates: updates).padding(12), width: 360, height: 90, to: directory.appendingPathComponent("update-ready-example.png"))
    }
    @MainActor func testLiveConnectionDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_LIVE_DIAGNOSTICS"] == "1" else { throw XCTSkip("Opt-in installed client checks") }
        let diagnostics = ConnectionDiagnostics()
        await diagnostics.check(store: AppStore(), sessions: SessionStore())
        XCTAssertEqual(diagnostics.results.count, 2); XCTAssertNotNil(diagnostics.checkedAt)
        diagnostics.prepareReport(); XCTAssertNotNil(diagnostics.reportText)
        // Only allowlisted diagnostic codes reach test output.
        for result in diagnostics.results { print("Diagnostic \(result.provider.rawValue): \(result.state.rawValue), \(result.errorCode ?? "none")") }
    }
    @MainActor private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua); host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, CGSize(width: width, height: height))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url); window.contentView = nil
    }
}

@MainActor private final class FakeFeaturePermissions: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status = .notRegistered
    var notifications: UNAuthorizationStatus = .notDetermined
    var grant = true, loginNeedsApproval = false
    var openedNotifications = 0, openedLogin = 0, requests = 0
    func notificationStatus() async -> UNAuthorizationStatus { notifications }
    func authorizeNotifications() async throws -> Bool {
        requests += 1; notifications = grant ? .authorized : .denied; return grant
    }
    func registerLogin() throws {
        loginStatus = loginNeedsApproval ? .requiresApproval : .enabled
        if loginNeedsApproval { throw NSError(domain: "SMAppServiceErrorDomain", code: kSMErrorLaunchDeniedByUser) }
    }
    func unregisterLogin() async throws { loginStatus = .notRegistered }
    func openNotificationSettings() -> Bool { openedNotifications += 1; return true }
    func openLoginSettings() { openedLogin += 1 }
}
