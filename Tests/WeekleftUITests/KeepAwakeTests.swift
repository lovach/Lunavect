import XCTest
import AppKit
import SwiftUI
import WeekleftCore
import AwakeService
import ServiceManagement
@testable import Weekleft

@MainActor private final class FakeAwakeClient: AwakeClient {
    /// Each read stands for one ServiceManagement status query (an IPC).
    private(set) var statusQueries = 0
    private var available = true
    var isAvailable: Bool {
        get { statusQueries += 1; return available }
        set { available = newValue }
    }
    var held = false, failBegin = false, failEnd = false
    var beginCount = 0, disconnectCount = 0, permissionCount = 0
    var failPermission = false
    var gate: CheckedContinuation<Void, Never>?
    var suspendBegin = false
    var keepAliveError: Error?, releaseCount = 0
    var startupProblem: Error?, repairError: Error?
    func registrationProblem() async -> Error? { startupProblem }
    func repairRegistration() async throws { if let repairError { throw repairError } }
    func requestPermission() throws {
        permissionCount += 1
        if failPermission { throw AwakeFailure.permission }
    }
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws {
        beginCount += 1
        if suspendBegin { await withCheckedContinuation { gate = $0 } }
        if failBegin { throw AwakeFailure.unavailable }
        held = true
    }
    func configure(policy: AwakeSafetyPolicy) async throws {}
    func keepAlive() async throws {
        if let keepAliveError { throw keepAliveError }
        if !held { throw AwakeFailure.lost }
    }
    func releaseAfterLostConnection() async { releaseCount += 1 }
    func end() async throws { if failEnd { throw AwakeFailure.unavailable }; held = false }
    func disconnect() { disconnectCount += 1; held = false }
}

final class KeepAwakeTests: XCTestCase {
    /// Each test owns its preferences; nothing is left in the test runner's standard domain.
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "Lunavect.KeepAwakeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }
    @MainActor func testRenderAutomaticControls() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_AWAKE_CONTROLS"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let suite = "awake-controls-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldLanguage = L10n.selection
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        L10n.defaults.set("en", forKey: "languageCode")
        let awake = KeepAwake(client: FakeAwakeClient(), defaults: defaults), now = Date()
        awake.observe([AgentSession(provider: .codex, sessionID: "preview", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now)])
        await awake.setAutomatic(true)
        let host = NSHostingView(rootView: KeepAwakeControls(awake: awake).padding(10).frame(width: 330)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; awake.shutdown() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    /// Opt-in: the registration recovery states of the panel, rendered for review.
    @MainActor func testRenderRegistrationRecovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_AWAKE_REGISTRATION"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let oldLanguage = L10n.selection
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        L10n.defaults.set(ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LANGUAGE"] ?? "en", forKey: "languageCode")
        var images: [NSImage] = []
        for repairFails in [false, true] {
            let suite = "awake-registration-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = FakeAwakeClient()
            client.startupProblem = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            client.repairError = repairFails ? AwakeFailure.permission : nil
            let awake = KeepAwake(client: client, defaults: defaults)
            await awake.waitForRegistrationCheck()
            if repairFails { await awake.repairRegistration() }
            let host = NSHostingView(rootView: KeepAwakeControls(awake: awake).padding(10).frame(width: 330)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size); image.addRepresentation(bitmap); images.append(image)
        }
        let size = NSSize(width: images.map(\.size.width).reduce(0, +) + 10, height: images.map(\.size.height).max() ?? 0)
        let sheet = NSImage(size: size)
        sheet.lockFocus()
        var x: CGFloat = 0
        for image in images { image.draw(at: NSPoint(x: x, y: size.height - image.size.height), from: .zero, operation: .copy, fraction: 1); x += image.size.width + 10 }
        sheet.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
    @MainActor func testForcedRepairRefreshesAnAlreadyRememberedBuild() async throws {
        let suite = "awake-repair-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = AwakeServiceRegistration(defaults: defaults, build: "same-build")
        registration.rememberCurrentBuild()
        var calls = 0
        try await registration.refreshIfNeeded(force: true, status: { .enabled },
            unregister: { calls += 1 }, register: { calls += 1 })
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testAutomaticModeFollowsWorkWithGraceAndDoesNotTreatWaitingAsWork() async throws {
        let suite = "awake-auto-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let client = FakeAwakeClient(), awake = KeepAwake(client: FakeAwakeClient(), defaults: defaults)
        XCTAssertFalse(awake.automatic)
        let subject = KeepAwake(client: client, now: { now }, defaults: defaults)
        subject.duration = .oneHour
        await subject.setAutomatic(true)
        XCTAssertFalse(subject.isEnabled)
        var row = AgentSession(provider: .codex, sessionID: "work", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        subject.observe([row]); await subject.reconcileAutomatic()
        XCTAssertTrue(subject.isEnabled); XCTAssertEqual(client.beginCount, 1)
        XCTAssertEqual(subject.duration, .oneHour)
        row.phase = .permission
        subject.observe([row]); await subject.reconcileAutomatic()
        now += 59; await subject.check(); XCTAssertTrue(subject.isEnabled)
        row.phase = .running; row.observedAt = now
        subject.observe([row]); await subject.reconcileAutomatic()
        XCTAssertNil(subject.idleDeadline); XCTAssertEqual(client.beginCount, 1)
        row.phase = .ready
        subject.observe([row]); await subject.reconcileAutomatic()
        now += 61; await subject.check()
        XCTAssertFalse(subject.isEnabled); XCTAssertTrue(subject.automatic)
        XCTAssertTrue(KeepAwake(client: client, defaults: defaults).automatic)
        await subject.setAutomatic(false)
        row.phase = .running; row.observedAt = now
        subject.observe([row]); await subject.reconcileAutomatic()
        XCTAssertFalse(subject.isEnabled)
    }
    @MainActor func testAutomaticHelperFailureDoesNotLoopOrClaimActive() async throws {
        let suite = "awake-auto-failure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeAwakeClient(); client.failBegin = true
        let subject = KeepAwake(client: client, defaults: defaults), now = Date()
        subject.observe([AgentSession(provider: .codex, sessionID: "work", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now)])
        await subject.setAutomatic(true)
        for _ in 0..<10 { await subject.reconcileAutomatic() }
        XCTAssertEqual(client.beginCount, 1); XCTAssertFalse(subject.isEnabled); XCTAssertNotNil(subject.issue)
        client.failBegin = false; await subject.setAutomatic(true)
        XCTAssertTrue(subject.isEnabled); XCTAssertEqual(client.beginCount, 2)
        await subject.setAutomatic(false)
    }
    /// A safety stop pauses automatic mode, says so, and resumes by itself:
    /// at once when the stop conditions change, otherwise after five minutes.
    @MainActor func testAutomaticSuspensionIsVisibleAndResumes() async throws {
        let suite = "awake-auto-resume-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeAwakeClient(); client.failBegin = true
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let subject = KeepAwake(client: client, now: { clock }, defaults: defaults)
        subject.observe([AgentSession(provider: .codex, sessionID: "work", title: "Example", cwd: "", phase: .running, updatedAt: clock, observedAt: clock)])
        await subject.setAutomatic(true)
        XCTAssertEqual(subject.statusDescription, L("Приостановлено, повторим через 5 минут"))
        clock += 120; await subject.reconcileAutomatic()
        XCTAssertEqual(client.beginCount, 1, "no loop within the pause")
        clock += 200; client.failBegin = false
        subject.observe([AgentSession(provider: .codex, sessionID: "work", title: "Example", cwd: "", phase: .running, updatedAt: clock, observedAt: clock)])
        await subject.reconcileAutomatic()
        XCTAssertEqual(client.beginCount, 2); XCTAssertTrue(subject.isEnabled)
        await subject.stop()

        client.failBegin = true
        subject.observe([AgentSession(provider: .codex, sessionID: "work", title: "Example", cwd: "", phase: .running, updatedAt: clock, observedAt: clock)])
        await subject.reconcileAutomatic()
        XCTAssertFalse(subject.isEnabled)
        let beforePolicy = client.beginCount
        client.failBegin = false
        var policy = subject.safetyPolicy; policy.thermalProtection.toggle()
        await subject.setSafetyPolicy(policy)
        XCTAssertEqual(client.beginCount, beforePolicy + 1, "changed conditions resume at once")
        XCTAssertTrue(subject.isEnabled)
        await subject.setAutomatic(false)
    }
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
    @MainActor func testPermissionApprovalStartsOnceWithChosenDurationAndReturnsToPanel() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false
        let now = Date(), awake = KeepAwake(client: client, defaults: defaults)
        var returned = 0
        awake.onPermissionFinished = { _ in returned += 1 }
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
    @MainActor func testCancelPreventsActivationAfterLaterApproval() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false
        let awake = KeepAwake(client: client, defaults: defaults)
        awake.requestPermission(); awake.cancelPermission()
        client.isAvailable = true; await awake.checkPermission()
        XCTAssertTrue(awake.isAvailable); XCTAssertFalse(awake.isEnabled)
        XCTAssertEqual(client.beginCount, 0)
    }
    @MainActor func testExpiredPermissionIntentDoesNotStartHoursLater() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false
        var now = Date()
        let awake = KeepAwake(client: client, now: { now }, defaults: defaults)
        awake.requestPermission(); now += 601
        client.isAvailable = true; await awake.checkPermission()
        XCTAssertFalse(awake.isAwaitingPermission); XCTAssertFalse(awake.isEnabled)
        XCTAssertNotNil(awake.issue); XCTAssertEqual(client.beginCount, 0)
    }
    @MainActor func testPermissionGrantedButHelperFailureDoesNotClaimActive() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false
        let awake = KeepAwake(client: client, defaults: defaults)
        var returned = 0; awake.onPermissionFinished = { _ in returned += 1 }
        awake.requestPermission(); client.isAvailable = true; client.failBegin = true
        await awake.checkPermission()
        XCTAssertFalse(awake.isEnabled); XCTAssertNotNil(awake.issue); XCTAssertEqual(returned, 1)
    }
    @MainActor func testFailedPermissionRequestEndsWaiting() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false; client.failPermission = true
        let awake = KeepAwake(client: client, defaults: defaults)
        awake.requestPermission(); await awake.checkPermission()
        XCTAssertFalse(awake.isAwaitingPermission); XCTAssertNotNil(awake.issue)
        XCTAssertEqual(client.beginCount, 0)
    }
    @MainActor func testNoPermissionDoesNotStartOrPretendEnabled() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false
        let awake = KeepAwake(client: client, defaults: defaults)
        await awake.start()
        XCTAssertEqual(client.beginCount, 0); XCTAssertFalse(awake.isEnabled); XCTAssertNotNil(awake.issue)
    }
    @MainActor func testEnabledOnlyAfterHelperConfirmation() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.suspendBegin = true
        let awake = KeepAwake(client: client, defaults: defaults)
        let task = Task { await awake.start() }
        while client.gate == nil { await Task.yield() }
        XCTAssertFalse(awake.isEnabled); XCTAssertTrue(awake.isBusy)
        client.gate?.resume(); await task.value
        XCTAssertTrue(awake.isEnabled); XCTAssertFalse(awake.isBusy)
        await awake.stop()
    }
    @MainActor func testLateConfirmationAfterShutdownCannotEnableUI() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.suspendBegin = true
        let awake = KeepAwake(client: client, defaults: defaults)
        let task = Task { await awake.start() }
        while client.gate == nil { await Task.yield() }
        awake.shutdown(); client.gate?.resume(); await task.value
        XCTAssertFalse(awake.isEnabled); XCTAssertNil(awake.endsAt)
    }
    @MainActor func testRestoreDuringAStartReportsItInsteadOfLeavingKeepAwakeOnSilently() async throws {
        let suite = "awake-restore-busy-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeAwakeClient(); client.suspendBegin = true
        let awake = KeepAwake(client: client, defaults: defaults)
        awake.duration = .fourHours
        let starting = Task { await awake.start() }
        while client.gate == nil { await Task.yield() }
        let whileStarting = await awake.restoreDefaults()
        XCTAssertFalse(whileStarting, "A reset that cannot stop Keep Awake yet is reported")
        client.suspendBegin = false; client.gate?.resume(); await starting.value
        XCTAssertTrue(awake.isEnabled)
        let afterwards = await awake.restoreDefaults()
        XCTAssertTrue(afterwards)
        XCTAssertFalse(awake.isEnabled); XCTAssertFalse(client.held)
        XCTAssertEqual(awake.duration, AppDefaultSettings.awakeDuration)
    }
    @MainActor func testDurationSelectionDoesNotStartUntilSwitchIsEnabled() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(), now = Date()
        let awake = KeepAwake(client: client, now: { now }, defaults: defaults)
        awake.duration = .oneHour
        XCTAssertEqual(client.beginCount, 0)
        await awake.toggle()
        XCTAssertTrue(client.held); XCTAssertEqual(awake.endsAt, now.addingTimeInterval(3600))
        await awake.toggle(); XCTAssertFalse(client.held)
        XCTAssertFalse(KeepAwake(client: client, defaults: defaults).isEnabled)
    }
    @MainActor func testFailedBeginDoesNotClaimEnabled() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.failBegin = true
        let awake = KeepAwake(client: client, defaults: defaults)
        await awake.start(for: .oneHour)
        XCTAssertFalse(awake.isEnabled); XCTAssertNil(awake.endsAt); XCTAssertNotNil(awake.issue)
    }
    @MainActor func testFailedStopInvalidatesLeaseAndShowsUnconfirmedResult() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient()
        let subject = KeepAwake(client: client, defaults: defaults)
        await subject.start(); client.failEnd = true; await subject.stop()
        XCTAssertFalse(subject.isEnabled); XCTAssertNotNil(subject.issue); XCTAssertEqual(client.disconnectCount, 1)
    }
    @MainActor func testAbsoluteExpiryAndRenewal() async throws {
        let defaults = try isolatedDefaults()
        var now = Date()
        let client = FakeAwakeClient()
        let timed = KeepAwake(client: client, now: { now }, defaults: defaults)
        await timed.start(for: .fifteenMinutes)
        now += 899; await timed.check(); XCTAssertTrue(timed.isEnabled)
        await timed.start(for: .oneHour)
        now += 900; await timed.check(); XCTAssertTrue(timed.isEnabled)
        now += 4000; await timed.check()
        XCTAssertFalse(timed.isEnabled); XCTAssertFalse(client.held); XCTAssertNil(timed.endsAt)
    }
    /// launchd no longer restarts a crashed helper (decision 16). A heartbeat
    /// without any answer asks a new instance to restore sleep; a helper that
    /// answered with a stop reason already restored it itself.
    @MainActor func testUnansweredHeartbeatStartsAFreshHelperOnlyWhenNoHelperAnswered() async throws {
        for (error, releases) in [(AwakeFailure.unavailable as Error, 1), (AwakeCallTimeout(), 1), (AwakeFailure.battery, 0)] {
            let suite = "awake-release-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = FakeAwakeClient(), awake = KeepAwake(client: client, defaults: defaults, scheduleTimer: { _, _ in Timer() })
            await awake.start()
            client.keepAliveError = error
            await awake.check()
            XCTAssertFalse(awake.isEnabled)
            XCTAssertEqual(client.releaseCount, releases, "\(error)")
        }
    }
    /// Matrix M12 (audit r2): repeated failure and recovery never leaves more than
    /// one heartbeat timer or one permission poll running.
    @MainActor func testRepeatedFailureAndRecoveryKeepsAtMostOneTimerOfEachKind() async throws {
        let defaults = try isolatedDefaults()
        var timers: [(interval: TimeInterval, timer: Timer)] = []
        let client = FakeAwakeClient()
        let awake = KeepAwake(client: client, defaults: defaults, scheduleTimer: { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true, block: action)
            RunLoop.main.add(timer, forMode: .common)
            timers.append((interval, timer))
            return timer
        })
        defer { awake.shutdown() }
        func running(_ interval: TimeInterval) -> Int { timers.filter { $0.interval == interval && $0.timer.isValid }.count }
        for cycle in 0..<5 {
            await awake.start(for: .untilStopped)
            await awake.start(for: .oneHour)  // a new duration while on keeps the same heartbeat
            XCTAssertEqual(running(10), 1, "cycle \(cycle)")
            client.keepAliveError = AwakeFailure.unavailable
            await awake.check()
            client.keepAliveError = nil
            XCTAssertFalse(awake.isEnabled)
            XCTAssertEqual(running(10), 0, "a lost helper stops the heartbeat, cycle \(cycle)")
            client.isAvailable = false
            awake.requestPermission(); awake.requestPermission()
            XCTAssertEqual(running(1), 1, "one permission poll, cycle \(cycle)")
            awake.cancelPermission()
            client.isAvailable = true
            XCTAssertEqual(running(1), 0)
        }
        XCTAssertEqual(client.releaseCount, 5)
        XCTAssertEqual(timers.filter(\.timer.isValid).count, 0)
    }
    /// R2-R-05: automatic mode with an unapproved helper asked ServiceManagement for
    /// its status (an IPC on the main actor) on every session observation, up to
    /// 34 times a second, and republished unchanged values. The status is re-read
    /// at most every five seconds there; an approval is noticed within that time.
    @MainActor func testAutomaticModeReadsTheHelperStatusAtMostEveryFiveSeconds() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        var clock = start
        let awake = KeepAwake(client: client, now: { clock }, defaults: defaults, scheduleTimer: { _, _ in Timer() })
        defer { awake.shutdown() }
        let row = AgentSession(provider: .codex, sessionID: "work", title: "Example", cwd: "", phase: .running,
                               updatedAt: start, observedAt: start)
        awake.observe([row])  // manual mode: nothing to reconcile yet
        await awake.setAutomatic(true)
        XCTAssertFalse(awake.isEnabled)
        var changes = 0
        let observer = awake.objectWillChange.sink { _ in changes += 1 }
        defer { observer.cancel() }
        let initial = client.statusQueries
        for _ in 0..<100 {  // one second of observations at 100 per second
            clock += 0.01
            await awake.reconcileAutomatic()
        }
        XCTAssertLessThanOrEqual(client.statusQueries - initial, 1, "at most one status query in a second")
        XCTAssertEqual(changes, 0, "unchanged values are not republished")
        clock = start.addingTimeInterval(5)
        await awake.reconcileAutomatic()
        let afterFiveSeconds = client.statusQueries - initial
        XCTAssertGreaterThanOrEqual(afterFiveSeconds, 1, "five seconds later the status is read again")
        XCTAssertLessThanOrEqual(afterFiveSeconds, 2)
        XCTAssertFalse(awake.isEnabled)
        // The user approves the helper in System Settings: noticed within five seconds.
        client.isAvailable = true
        let approved = clock
        while !awake.isEnabled && clock < approved.addingTimeInterval(5) {
            clock += 0.5
            await awake.reconcileAutomatic()
        }
        XCTAssertTrue(awake.isEnabled, "approval started automatic mode within five seconds")
        XCTAssertEqual(client.beginCount, 1)
    }

    /// The explicit permission path is never served from that cache: "Allow and
    /// turn on", its polling and opening the panel read the status at once.
    @MainActor func testPermissionActionsReadTheHelperStatusWithoutDelay() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient(); client.isAvailable = false
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let awake = KeepAwake(client: client, now: { clock }, defaults: defaults, scheduleTimer: { _, _ in Timer() })
        defer { awake.shutdown() }
        let row = AgentSession(provider: .codex, sessionID: "work", title: "Example", cwd: "", phase: .running,
                               updatedAt: clock, observedAt: clock)
        awake.observe([row])
        await awake.setAutomatic(true)
        await awake.reconcileAutomatic()
        XCTAssertFalse(awake.isAvailable)
        awake.requestPermission()
        XCTAssertTrue(awake.isAwaitingPermission)
        clock += 1
        client.isAvailable = true  // approved one second after the last automatic read
        await awake.checkPermission()
        XCTAssertTrue(awake.isAvailable, "the permission poll reads the status at once")
        XCTAssertTrue(awake.isEnabled, "and turns the mode on")
        await awake.setAutomatic(false)
        // Opening the panel (.task / didBecomeActive → checkPermission) also reads it at once.
        client.isAvailable = false
        let before = client.statusQueries
        await awake.checkPermission()
        XCTAssertEqual(client.statusQueries, before + 1)
        XCTAssertFalse(awake.isAvailable, "the panel offers Allow and turn on again")
        var changes = 0
        let observer = awake.objectWillChange.sink { _ in changes += 1 }
        defer { observer.cancel() }
        for _ in 0..<3 { await awake.checkPermission() }
        XCTAssertEqual(changes, 0, "an unchanged status read does not redraw the panel")
    }
    @MainActor func testLostHelperIsNotDisplayedAsActive() async throws {
        let defaults = try isolatedDefaults()
        let client = FakeAwakeClient()
        let subject = KeepAwake(client: client, defaults: defaults)
        await subject.start(); client.held = false; await subject.check()
        XCTAssertFalse(subject.isEnabled); XCTAssertNotNil(subject.issue)
    }
    @MainActor func testRenderNativeButtonInPanel() async throws {
        let defaults = try isolatedDefaults()
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_AWAKE"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory), now = Date()
        store.acceptSessions([
            AgentSession(
                provider: .codex, sessionID: "awake-preview", title: "Работа над Lunavect", cwd: "/tmp/Example",
                client: .desktop, phase: .running, updatedAt: now, observedAt: now)
        ])
        let backend = FakeAwakeClient()
        let awake = KeepAwake(client: backend, defaults: defaults)
        for (available, enabled, expanded, waiting) in [
            (false, false, true, false), (false, false, true, true), (true, false, false, false),
            (true, false, true, false), (true, true, true, false), (true, true, false, false),
        ] {
            awake.cancelPermission()
            backend.isAvailable = available; awake.refreshPermission()
            if enabled { await awake.start(for: .oneHour) } else { await awake.stop() }
            if waiting { awake.requestPermission() }
            let host = NSHostingView(rootView: SessionsView(store: store, updates: uiDependencies.updates, awake: awake, onSettings: {}, showingAwake: expanded).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            XCTAssertEqual(host.frame.width, 360)
            XCTAssertLessThanOrEqual(host.frame.height, 480)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(
                    fileURLWithPath: path + (waiting ? "-waiting" : "") + (available ? "" : "-permission")
                        + (enabled ? "-on" : "-off") + (expanded ? "-expanded.png" : ".png")))
            window.contentView = nil
        }
        await awake.stop()
    }
}
