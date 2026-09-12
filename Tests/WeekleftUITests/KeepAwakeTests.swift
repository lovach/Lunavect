import XCTest
import AppKit
import SwiftUI
import WeekleftCore
import AwakeService
import ServiceManagement
@testable import Weekleft

@MainActor private final class FakeAwakeClient: AwakeClient {
    var isAvailable = true, held = false, failBegin = false, failEnd = false
    var beginCount = 0, disconnectCount = 0, permissionCount = 0
    var failPermission = false
    var gate: CheckedContinuation<Void, Never>?
    var suspendBegin = false
    func requestPermission() throws {
        permissionCount += 1
        if failPermission { throw AwakeFailure.permission }
    }
    func begin(seconds: Int) async throws {
        beginCount += 1
        if suspendBegin { await withCheckedContinuation { gate = $0 } }
        if failBegin { throw AwakeFailure.unavailable }
        held = true
    }
    func keepAlive() async throws { if !held { throw AwakeFailure.lost } }
    func end() async throws { if failEnd { throw AwakeFailure.unavailable }; held = false }
    func disconnect() { disconnectCount += 1; held = false }
}

final class KeepAwakeTests: XCTestCase {
    @MainActor func testUpdatedBuildRestartsHelperOnceBeforeUse() async throws {
        let suite = "awake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = AwakeServiceRegistration(defaults: defaults, build: "new")
        var events: [String] = []
        var status = SMAppService.Status.enabled
        for _ in 0..<2 {
            try await registration.refreshIfNeeded(status: { status }, unregister: {
                events.append("unregister"); await Task.yield(); status = .notRegistered
            }, register: {
                XCTAssertEqual(status, .notRegistered)
                events.append("register"); status = .enabled
            })
        }
        XCTAssertEqual(events, ["unregister", "register"])
    }
    @MainActor func testFailedHelperUpdateCanBeRetried() async throws {
        let suite = "awake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = AwakeServiceRegistration(defaults: defaults, build: "new")
        do {
            try await registration.refreshIfNeeded(status: { .enabled }, unregister: { throw AwakeFailure.system }, register: { XCTFail("Must wait for unregister") })
            XCTFail("Expected failure")
        } catch {}
        var retried = false
        try await registration.refreshIfNeeded(status: { .enabled }, unregister: { retried = true }, register: {})
        XCTAssertTrue(retried)
    }
    @MainActor func testHelperUpdateDoesNotOverrideDeniedPermission() async throws {
        let suite = "awake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = AwakeServiceRegistration(defaults: defaults, build: "new")
        do {
            try await registration.refreshIfNeeded(status: { .requiresApproval }, unregister: { XCTFail("Permission missing") }, register: { XCTFail("Permission missing") })
            XCTFail("Expected permission failure")
        } catch { XCTAssertEqual(error as? AwakeFailure, .permission) }
    }
    @MainActor func testHelperUpdateWaitsForBackgroundRegistrationToSettle() async throws {
        let suite = "awake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = AwakeServiceRegistration(defaults: defaults, build: "new")
        var status = SMAppService.Status.enabled
        var attempts = 0, waits: [Int] = []
        try await registration.refreshIfNeeded(status: { status }, unregister: { status = .notRegistered }, register: {
            attempts += 1
            if attempts < 3 { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
            status = .enabled
        }, pause: { waits.append($0) })
        XCTAssertEqual(attempts, 3); XCTAssertEqual(waits, [0, 1])
    }
    @MainActor func testHelperUpdateDoesNotRetryInvalidSignature() async throws {
        let suite = "awake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = AwakeServiceRegistration(defaults: defaults, build: "new")
        var status = SMAppService.Status.enabled
        do {
            try await registration.refreshIfNeeded(status: { status }, unregister: { status = .notRegistered }, register: {
                throw NSError(domain: "SMAppServiceErrorDomain", code: kSMErrorInvalidSignature)
            }, pause: { _ in XCTFail("Do not retry invalid signatures") })
            XCTFail("Expected signing failure")
        } catch { XCTAssertEqual((error as NSError).code, kSMErrorInvalidSignature) }
    }
    func testRegistrationAwaitingApprovalStillOpensSystemSettings() throws {
        var status = SMAppService.Status.notRegistered
        var opened = 0
        try AwakePermissionAccess.request(status: { status }, register: {
            status = .requiresApproval
            throw AwakeFailure.permission
        }, openSettings: { opened += 1 })
        XCTAssertEqual(opened, 1)
    }
    func testAlreadyPendingPermissionDoesNotRegisterAgain() throws {
        var registered = 0, opened = 0
        try AwakePermissionAccess.request(status: { .requiresApproval }, register: { registered += 1 }, openSettings: { opened += 1 })
        XCTAssertEqual(registered, 0); XCTAssertEqual(opened, 1)
    }
    func testRealRegistrationFailureDoesNotOpenUnrelatedSettings() {
        var opened = false
        XCTAssertThrowsError(try AwakePermissionAccess.request(status: { .notRegistered }, register: { throw AwakeFailure.system }, openSettings: { opened = true }))
        XCTAssertFalse(opened)
    }
    @MainActor func testPermissionApprovalStartsOnceWithChosenDurationAndReturnsToPanel() async {
        let client = FakeAwakeClient(); client.isAvailable = false
        let now = Date(), awake = KeepAwake(client: client)
        var returned = 0
        awake.onPermissionFinished = { returned += 1 }
        awake.duration = .oneHour; awake.requestPermission()
        XCTAssertTrue(awake.isAwaitingPermission); XCTAssertEqual(client.permissionCount, 1)
        await awake.checkPermission(); XCTAssertEqual(client.beginCount, 0)
        client.isAvailable = true
        await awake.checkPermission(); await awake.checkPermission()
        XCTAssertFalse(awake.isAwaitingPermission); XCTAssertTrue(awake.isEnabled)
        XCTAssertEqual(client.beginCount, 1); XCTAssertEqual(returned, 1)
        XCTAssertGreaterThanOrEqual(awake.endsAt ?? .distantPast, now.addingTimeInterval(3600))
        await awake.stop()
    }
    @MainActor func testCancelPreventsActivationAfterLaterApproval() async {
        let client = FakeAwakeClient(); client.isAvailable = false
        let awake = KeepAwake(client: client)
        awake.requestPermission(); awake.cancelPermission()
        client.isAvailable = true; await awake.checkPermission()
        XCTAssertTrue(awake.isAvailable); XCTAssertFalse(awake.isEnabled)
        XCTAssertEqual(client.beginCount, 0)
    }
    @MainActor func testExpiredPermissionIntentDoesNotStartHoursLater() async {
        let client = FakeAwakeClient(); client.isAvailable = false
        var now = Date()
        let awake = KeepAwake(client: client, now: { now })
        awake.requestPermission(); now += 601
        client.isAvailable = true; await awake.checkPermission()
        XCTAssertFalse(awake.isAwaitingPermission); XCTAssertFalse(awake.isEnabled)
        XCTAssertNotNil(awake.issue); XCTAssertEqual(client.beginCount, 0)
    }
    @MainActor func testPermissionGrantedButHelperFailureDoesNotClaimActive() async {
        let client = FakeAwakeClient(); client.isAvailable = false
        let awake = KeepAwake(client: client)
        var returned = 0; awake.onPermissionFinished = { returned += 1 }
        awake.requestPermission(); client.isAvailable = true; client.failBegin = true
        await awake.checkPermission()
        XCTAssertFalse(awake.isEnabled); XCTAssertNotNil(awake.issue); XCTAssertEqual(returned, 1)
    }
    @MainActor func testFailedPermissionRequestEndsWaiting() async {
        let client = FakeAwakeClient(); client.isAvailable = false; client.failPermission = true
        let awake = KeepAwake(client: client)
        awake.requestPermission(); await awake.checkPermission()
        XCTAssertFalse(awake.isAwaitingPermission); XCTAssertNotNil(awake.issue)
        XCTAssertEqual(client.beginCount, 0)
    }
    @MainActor func testNoPermissionDoesNotStartOrPretendEnabled() async {
        let client = FakeAwakeClient(); client.isAvailable = false
        let awake = KeepAwake(client: client)
        await awake.start()
        XCTAssertEqual(client.beginCount, 0); XCTAssertFalse(awake.isEnabled); XCTAssertNotNil(awake.issue)
    }
    @MainActor func testEnabledOnlyAfterHelperConfirmation() async {
        let client = FakeAwakeClient(); client.suspendBegin = true
        let awake = KeepAwake(client: client)
        let task = Task { await awake.start() }
        while client.gate == nil { await Task.yield() }
        XCTAssertFalse(awake.isEnabled); XCTAssertTrue(awake.isBusy)
        client.gate?.resume(); await task.value
        XCTAssertTrue(awake.isEnabled); XCTAssertFalse(awake.isBusy)
        await awake.stop()
    }
    @MainActor func testLateConfirmationAfterShutdownCannotEnableUI() async {
        let client = FakeAwakeClient(); client.suspendBegin = true
        let awake = KeepAwake(client: client)
        let task = Task { await awake.start() }
        while client.gate == nil { await Task.yield() }
        awake.shutdown(); client.gate?.resume(); await task.value
        XCTAssertFalse(awake.isEnabled); XCTAssertNil(awake.endsAt)
    }
    @MainActor func testDurationSelectionDoesNotStartUntilSwitchIsEnabled() async {
        let client = FakeAwakeClient(), now = Date()
        let awake = KeepAwake(client: client, now: { now })
        awake.duration = .oneHour
        XCTAssertEqual(client.beginCount, 0)
        await awake.toggle()
        XCTAssertTrue(client.held); XCTAssertEqual(awake.endsAt, now.addingTimeInterval(3600))
        await awake.toggle(); XCTAssertFalse(client.held)
        XCTAssertFalse(KeepAwake(client: client).isEnabled)
    }
    @MainActor func testFailedBeginDoesNotClaimEnabled() async {
        let client = FakeAwakeClient(); client.failBegin = true
        let awake = KeepAwake(client: client)
        await awake.start(for: .oneHour)
        XCTAssertFalse(awake.isEnabled); XCTAssertNil(awake.endsAt); XCTAssertNotNil(awake.issue)
    }
    @MainActor func testFailedStopInvalidatesLeaseAndShowsUnconfirmedResult() async {
        let client = FakeAwakeClient()
        let subject = KeepAwake(client: client)
        await subject.start(); client.failEnd = true; await subject.stop()
        XCTAssertFalse(subject.isEnabled); XCTAssertNotNil(subject.issue); XCTAssertEqual(client.disconnectCount, 1)
    }
    @MainActor func testAbsoluteExpiryAndRenewal() async {
        var now = Date()
        let client = FakeAwakeClient()
        let timed = KeepAwake(client: client, now: { now })
        await timed.start(for: .fifteenMinutes)
        now += 899; await timed.check(); XCTAssertTrue(timed.isEnabled)
        await timed.start(for: .oneHour)
        now += 900; await timed.check(); XCTAssertTrue(timed.isEnabled)
        now += 4000; await timed.check()
        XCTAssertFalse(timed.isEnabled); XCTAssertFalse(client.held); XCTAssertNil(timed.endsAt)
    }
    @MainActor func testLostHelperIsNotDisplayedAsActive() async {
        let client = FakeAwakeClient()
        let subject = KeepAwake(client: client)
        await subject.start(); client.held = false; await subject.check()
        XCTAssertFalse(subject.isEnabled); XCTAssertNotNil(subject.issue)
    }
    @MainActor func testRenderNativeButtonInPanel() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_AWAKE"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory), now = Date()
        store.acceptSessions([AgentSession(provider: .codex, sessionID: "awake-preview", title: "Работа над Lunavect", cwd: "/tmp/Example", client: .desktop, phase: .running, updatedAt: now, observedAt: now)])
        let backend = FakeAwakeClient()
        let awake = KeepAwake(client: backend)
        for (available, enabled, expanded, waiting) in [(false, false, true, false), (false, false, true, true), (true, false, false, false), (true, false, true, false), (true, true, true, false), (true, true, false, false)] {
            awake.cancelPermission()
            backend.isAvailable = available; awake.refreshPermission()
            if enabled { await awake.start(for: .oneHour) } else { await awake.stop() }
            if waiting { awake.requestPermission() }
            let host = NSHostingView(rootView: SessionsView(store: store, awake: awake, onSettings: {}, showingAwake: expanded).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            XCTAssertEqual(host.frame.width, 360)
            XCTAssertLessThanOrEqual(host.frame.height, 480)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + (waiting ? "-waiting" : "") + (available ? "" : "-permission") + (enabled ? "-on" : "-off") + (expanded ? "-expanded.png" : ".png")))
            window.contentView = nil
        }
        await awake.stop()
    }
}
