import XCTest
import os
import ServiceManagement
import AwakeService
@testable import Weekleft

/// An in-process helper on an anonymous listener: real NSXPC connections,
/// invalidation and error handlers, with replies the test can hold back.
private final class FakeAwakeHelper: NSObject, LunavectAwakeProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    typealias Reply = @Sendable (Bool, String) -> Void
    private let lock = NSLock()
    private var holding: Set<String> = []
    private var held: [String: [Reply]] = [:]
    private var calls: [String] = []
    private var accepts = true
    private var invalidations = 0
    private var connectHandler: (@Sendable () -> Void)?
    /// Runs when launchd would start the helper for a new connection.
    var onConnect: (@Sendable () -> Void)? {
        get { lock.withLock { connectHandler } }
        set { lock.withLock { connectHandler = newValue } }
    }
    let listener = NSXPCListener.anonymous()
    override init() { super.init(); listener.delegate = self; listener.resume() }
    deinit { listener.invalidate() }

    /// An unresumed client connection, as the production factory returns.
    func connection() -> NSXPCConnection { NSXPCConnection(listenerEndpoint: listener.endpoint) }
    func hold(_ name: String) { lock.withLock { _ = holding.insert(name) } }
    func refuseConnections() { lock.withLock { accepts = false } }
    func received(_ name: String) -> Bool { lock.withLock { calls.contains(name) } }
    func count(_ name: String) -> Int { lock.withLock { calls.filter { $0 == name }.count } }
    /// Client connections that ended; the real helper then ends their lease.
    var endedConnections: Int { lock.withLock { invalidations } }
    func release(_ name: String) {
        let replies: [Reply] = lock.withLock { holding.remove(name); return held.removeValue(forKey: name) ?? [] }
        replies.forEach { $0(true, "") }
    }
    private func handle(_ name: String, _ reply: @escaping Reply) {
        let hold: Bool = lock.withLock {
            calls.append(name)
            guard holding.contains(name) else { return false }
            held[name, default: []].append(reply); return true
        }
        if !hold { reply(true, "") }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard lock.withLock({ accepts }) else { return false }
        onConnect?()
        connection.exportedInterface = NSXPCInterface(with: LunavectAwakeProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.lock.withLock { self?.invalidations += 1 } }
        connection.resume()
        return true
    }
    func begin(seconds: Int, withReply reply: @escaping Reply) { handle("begin", reply) }
    func beginConfigured(seconds: Int, allowBattery: Bool, batteryProtection: Bool, minimumBatteryPercent: Int,
                         thermalProtection: Bool, withReply reply: @escaping Reply) { handle("begin", reply) }
    func configure(allowBattery: Bool, batteryProtection: Bool, minimumBatteryPercent: Int,
                   thermalProtection: Bool, withReply reply: @escaping Reply) { handle("configure", reply) }
    func keepAlive(withReply reply: @escaping Reply) { handle("keepAlive", reply) }
    func end(withReply reply: @escaping Reply) { handle("end", reply) }
}

final class AwakeMaintenanceTests: XCTestCase {
    @MainActor private func registration() throws -> AwakeServiceRegistration {
        let name = "Lunavect.AwakeMaintenance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        // The published 103 helper has no recorded current-build key.
        return AwakeServiceRegistration(defaults: defaults, build: "104")
    }
    @MainActor func testClientStartupReplacesLegacyDaemonWithoutStartingALease() async throws {
        var status = SMAppService.Status.enabled
        var events: [String] = []
        var legacyKeepAlive = true
        let registration = try registration()
        let service = AwakeServiceAccess(readStatus: { status }, register: {
            events.append("register-current"); legacyKeepAlive = false; status = .enabled
        }, unregister: {
            events.append("unregister-103"); await Task.yield(); status = .notRegistered
        }, openSettings: { XCTFail("Startup must not request new permission") }, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: registration)
        await client.waitForStartupRefresh()
        XCTAssertNil(client.registrationFailure)
        XCTAssertEqual(events, ["unregister-103", "register-current"])
        XCTAssertFalse(legacyKeepAlive)
        let restarted = AwakeServiceClient(service: service, registration: registration)
        await restarted.waitForStartupRefresh()
        XCTAssertEqual(events.count, 2, "Same build must not churn registration")
    }
    @MainActor func testALateFailureOfAnEndedConnectionLeavesTheNewLeaseConnected() async throws {
        let helper = FakeAwakeHelper()
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: {}, unregister: {}, openSettings: {}, verifySleepRestored: {})
        var connections = 0
        let client = AwakeServiceClient(service: service, registration: try registration(), refreshAtStartup: false,
                                        makeConnection: { connections += 1; return helper.connection() })
        defer { client.disconnect() }
        helper.hold("keepAlive")
        let heartbeat = Task { try await client.keepAlive() }
        while !helper.received("keepAlive") { try await Task.sleep(for: .milliseconds(10)) }
        // Keep Awake stops (ending connection A) and a new start opens connection B
        // before A's pending heartbeat reports its failure.
        try await client.end()
        helper.hold("configure")
        let releaseAfterHeartbeat = Task { _ = await heartbeat.result; helper.release("configure") }
        try await client.configure(policy: .init())
        _ = await releaseAfterHeartbeat.value
        let heartbeatResult = await heartbeat.result
        XCTAssertThrowsError(try heartbeatResult.get(), "The heartbeat of the ended connection fails")
        helper.release("keepAlive")
        try await client.keepAlive()
        XCTAssertEqual(connections, 2, "The new lease keeps its connection")
    }
    @MainActor func testASlowHelperReplyNeverReRegistersTheDaemon() async throws {
        let helper = FakeAwakeHelper()
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: { events.append("verify-sleep") })
        let registration = try registration()
        registration.rememberCurrentBuild()
        let client = AwakeServiceClient(service: service, registration: registration, refreshAtStartup: false,
                                        makeConnection: { helper.connection() }, callTimeout: 0.2)
        defer { client.disconnect(); helper.release("begin") }
        // pmset under load can keep the helper's begin busy past the client's patience.
        helper.hold("begin")
        do {
            try await client.begin(seconds: 0, policy: .init())
            XCTFail("An unanswered begin must fail")
        } catch {
            XCTAssertTrue(error is AwakeCallTimeout, "A slow helper is not reported as a missing one: \(error)")
        }
        XCTAssertEqual(events, [], "A slow reply never unregisters the approved daemon")
        XCTAssertGreaterThan(AwakeServiceClient.callTimeout, 18, "The default outlasts three 6-second pmset runs")
    }
    @MainActor func testARefusedConnectionStillRenewsTheRegistrationOnce() async throws {
        let helper = FakeAwakeHelper()
        helper.refuseConnections()
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: { events.append("verify-sleep") })
        let registration = try registration()
        registration.rememberCurrentBuild()
        let client = AwakeServiceClient(service: service, registration: registration, refreshAtStartup: false,
                                        makeConnection: { helper.connection() }, callTimeout: 5)
        defer { client.disconnect() }
        do {
            try await client.begin(seconds: 0, policy: .init())
            XCTFail("A refused connection must fail")
        } catch { XCTAssertEqual(error as? AwakeFailure, .unavailable) }
        XCTAssertEqual(events, ["verify-sleep", "unregister", "register"], "The post-update BTM repair still runs once")
    }
    @MainActor func testAQuitBetweenUnregisterAndRegisterIsCompletedAtTheNextLaunch() async throws {
        let name = "Lunavect.AwakeRenewal." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var status = SMAppService.Status.enabled
        var events: [String] = []
        var quitPoint: CheckedContinuation<Void, Never>?
        // First launch of an updated build: the old registration is removed, then the app quits.
        let updating = AwakeServiceAccess(readStatus: { status }, register: { events.append("register"); status = .enabled },
            unregister: { events.append("unregister"); status = .notRegistered; await withCheckedContinuation { quitPoint = $0 } },
            openSettings: {}, verifySleepRestored: {})
        let first = AwakeServiceClient(service: updating, registration: AwakeServiceRegistration(defaults: defaults, build: "104"))
        while quitPoint == nil { await Task.yield() }
        let relaunch = AwakeServiceAccess(readStatus: { status }, register: { events.append("register"); status = .enabled },
            unregister: { XCTFail("Nothing is left to unregister") }, openSettings: { XCTFail("No new permission request") },
            verifySleepRestored: {})
        let second = AwakeServiceClient(service: relaunch, registration: AwakeServiceRegistration(defaults: defaults, build: "104"))
        await second.waitForStartupRefresh()
        XCTAssertTrue(second.isAvailable, "The next launch completes the interrupted renewal")
        XCTAssertNil(second.registrationFailure)
        XCTAssertEqual(events, ["unregister", "register"])
        let third = AwakeServiceClient(service: relaunch, registration: AwakeServiceRegistration(defaults: defaults, build: "104"))
        await third.waitForStartupRefresh()
        XCTAssertEqual(events.count, 2, "A completed renewal is not repeated")
        quitPoint?.resume()
        await first.waitForStartupRefresh()
    }
    @MainActor func testAnInterruptedRenewalLeavesAHelperAwaitingApprovalOrRemovedOnPurposeAlone() async throws {
        let name = "Lunavect.AwakeRenewalOwner." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var status = SMAppService.Status.enabled
        var quitPoint: CheckedContinuation<Void, Never>?
        let registration = AwakeServiceRegistration(defaults: defaults, build: "104")
        let renewal = Task { try? await registration.refreshIfNeeded(status: { status }, unregister: {
            status = .notRegistered; await withCheckedContinuation { quitPoint = $0 }
        }, register: {}) }
        while quitPoint == nil { await Task.yield() }
        // The user turned the helper off in System Settings before the next launch.
        status = .requiresApproval
        AwakeServiceRegistration(defaults: defaults, build: "104").resumeInterruptedRefresh(status: { status }, register: {
            XCTFail("A helper awaiting the user's approval is not registered again")
        })
        quitPoint?.resume(); _ = await renewal.value
        // Removal through --unregister-awake-helper forgets any unfinished renewal.
        status = .enabled
        let removal = Task { try? await registration.refreshIfNeeded(force: true, status: { status }, unregister: {
            status = .notRegistered; await withCheckedContinuation { quitPoint = $0 }
        }, register: {}) }
        while status != .notRegistered { await Task.yield() }
        AwakeServiceRegistration(defaults: defaults, build: "104").forgetCurrentBuild()
        AwakeServiceRegistration(defaults: defaults, build: "104").resumeInterruptedRefresh(status: { status }, register: {
            XCTFail("A helper removed on purpose stays removed")
        })
        quitPoint?.resume(); _ = await removal.value
    }
    @MainActor func testStartupLeavesDeniedAndUnregisteredServicesAlone() async throws {
        for status in [SMAppService.Status.requiresApproval, .notRegistered, .notFound] {
            let service = AwakeServiceAccess(readStatus: { status }, register: { XCTFail("No permission") },
                unregister: { XCTFail("No permission") }, openSettings: { XCTFail("No unsolicited settings") },
                verifySleepRestored: { XCTFail("No unsolicited power inspection") })
            let client = AwakeServiceClient(service: service, registration: try registration())
            await client.waitForStartupRefresh()
            XCTAssertFalse(client.isAvailable)
        }
    }
    @MainActor func testRemovalVerifiesSleepBeforeUnregisterAndKeepsRecoveryAvailableOnFailure() async throws {
        var status = SMAppService.Status.enabled
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { status }, register: { XCTFail("Removal must not register") },
            unregister: { events.append("unregister"); status = .notRegistered }, openSettings: {}, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: try registration(), refreshAtStartup: false)
        do {
            try await client.prepareForRemoval { events.append("sleep-pending"); throw AwakeFailure.recovery }
            XCTFail("Must preserve recovery service")
        } catch { XCTAssertEqual(error as? AwakeFailure, .recovery) }
        XCTAssertEqual(status, .enabled)
        XCTAssertEqual(events, ["sleep-pending"])
        try await client.prepareForRemoval { events.append("sleep-restored") }
        XCTAssertEqual(events, ["sleep-pending", "sleep-restored", "unregister"])
        XCTAssertEqual(status, .notRegistered)
    }
    @MainActor func testRemovalFailureDoesNotPretendServiceIsGone() async throws {
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: {},
            unregister: { throw AwakeFailure.permission }, openSettings: {}, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: try registration(), refreshAtStartup: false)
        do { try await client.prepareForRemoval {}; XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? AwakeFailure, .permission) }
        XCTAssertTrue(client.isAvailable)
    }
    @MainActor func testUpgradePreservesBothExplicitAndLegacyUpdatePreferences() throws {
        for previous: Bool? in [nil, false, true] {
            let name = "Lunavect.UpdateMigration." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            if let previous { defaults.set(previous, forKey: "SUAutomaticallyUpdate") }
            AppDefaultSettings.prepare(defaults: defaults, existingInstallation: true)
            let updates = AppUpdates(defaults: defaults, isolated: true)
            XCTAssertEqual(updates.automatic, previous ?? true)
            XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, previous)
        }
        let name = "Lunavect.FreshUpdates." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: false)
        let updates = AppUpdates(defaults: defaults, isolated: true)
        XCTAssertFalse(updates.automatic); XCTAssertTrue(updates.checkingAutomatically)
    }
    @MainActor func testInterruptedLegacyLeaseKeepsRecoveryRegisteredUntilSleepIsRestored() async throws {
        var sleepDisabled = true
        var events: [String] = []
        let registration = try registration()
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: {
                events.append("verify-sleep")
                if sleepDisabled { throw AwakeFailure.recovery }
            })
        // The old helper answers but cannot restore sleep yet (pmset keeps failing).
        let helper = FakeAwakeHelper()
        let first = AwakeServiceClient(service: service, registration: registration,
                                       makeConnection: { helper.connection() }, callTimeout: 2)
        await first.waitForStartupRefresh()
        XCTAssertEqual(first.registrationFailure as? AwakeFailure, .recovery)
        XCTAssertEqual(events, ["verify-sleep", "verify-sleep"], "Old helper must keep its recovery registration")
        XCTAssertTrue(helper.received("end"), "it was asked once to restore sleep before the refusal")
        sleepDisabled = false
        let retry = AwakeServiceClient(service: service, registration: registration,
                                       makeConnection: { helper.connection() }, callTimeout: 2)
        await retry.waitForStartupRefresh()
        XCTAssertNil(retry.registrationFailure)
        XCTAssertEqual(events, ["verify-sleep", "verify-sleep", "verify-sleep", "unregister", "register"])
    }

    // MARK: Audit 05 H-01, H-03 and §5 items 9 and 11

    /// The owner's Mac: the recorded build is old and ServiceManagement refuses to
    /// unregister the previous registration. The panel says so and offers repair.
    @MainActor func testStartupRenewalFailureIsShownInThePanelAndCanBeRepaired() async throws {
        var status = SMAppService.Status.enabled, failUnregister = true
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { status }, register: { events.append("register"); status = .enabled }, unregister: {
            events.append("unregister")
            if failUnregister { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            status = .notRegistered
        }, openSettings: {}, verifySleepRestored: {})
        let registration = try registration()
        let client = AwakeServiceClient(service: service, registration: registration)
        let problem = await client.registrationProblem()
        XCTAssertEqual((problem as NSError?)?.code, Int(EPERM))
        let name = "Lunavect.AwakeStartupProblem." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let awake = KeepAwake(client: client, defaults: defaults)
        await awake.waitForRegistrationCheck()
        XCTAssertNotNil(awake.issue, "a failed renewal is visible, not only stored")
        XCTAssertEqual(awake.recoveryAction, .repairRegistration)
        await awake.repairRegistration()
        XCTAssertEqual(awake.recoveryAction, .openLoginItems, "a second refusal leads to the manual steps")
        XCTAssertTrue(KeepAwake.unregisterCommand(executable: "/Users/a b/Applications/Lunavect.app/Contents/MacOS/Lunavect")
            .hasPrefix("'/Users/a b/Applications/Lunavect.app/Contents/MacOS/Lunavect' --unregister-awake-helper"))
        failUnregister = false
        await awake.repairRegistration()
        XCTAssertNil(awake.issue)
        XCTAssertEqual(events.suffix(2), ["unregister", "register"])
        let restarted = AwakeServiceClient(service: service, registration: registration)
        let repeated = await restarted.registrationProblem()
        XCTAssertNil(repeated)
        XCTAssertEqual(events.filter { $0 == "register" }.count, 1, "the repaired build is not renewed again")
    }
    /// A registration launchd cannot start accepts messages and never answers. The
    /// first lease in a new build pings briefly and renews the registration once.
    @MainActor func testUnansweredPingInANewBuildRenewsTheRegistrationOnce() async throws {
        let helper = FakeAwakeHelper()
        helper.hold("keepAlive"); helper.hold("begin")
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: { events.append("verify-sleep") })
        let registration = try registration()
        registration.rememberCurrentBuild()
        let client = AwakeServiceClient(service: service, registration: registration, refreshAtStartup: false,
                                        makeConnection: { helper.connection() }, callTimeout: 0.4, pingTimeout: 0.2)
        defer { client.disconnect(); helper.release("keepAlive"); helper.release("begin") }
        for attempt in 0..<2 {
            do {
                try await client.begin(seconds: 0, policy: .init())
                XCTFail("A helper that never answers cannot start a lease")
            } catch {
                XCTAssertTrue(error is AwakeHelperNotStarting, "attempt \(attempt): \(error)")
            }
        }
        XCTAssertEqual(events, ["verify-sleep", "unregister", "register"], "exactly one renewal, no loop on retries")
    }
    @MainActor func testSecondTimeoutInARowRenewsTheRegistrationOnce() async throws {
        let helper = FakeAwakeHelper()
        helper.hold("begin")
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: { events.append("verify-sleep") })
        let registration = try registration()
        registration.rememberCurrentBuild()
        let client = AwakeServiceClient(service: service, registration: registration, refreshAtStartup: false,
                                        makeConnection: { helper.connection() }, callTimeout: 0.3, pingTimeout: 0.2)
        defer { client.disconnect(); helper.release("begin") }
        var errors: [Error] = []
        for _ in 0..<3 {
            do { try await client.begin(seconds: 0, policy: .init()) } catch { errors.append(error) }
        }
        XCTAssertEqual(errors.count, 3)
        XCTAssertTrue(errors[0] is AwakeCallTimeout, "one slow reply keeps the registration")
        XCTAssertTrue(errors[1] is AwakeHelperNotStarting, "\(errors[1])")
        XCTAssertEqual(events, ["verify-sleep", "unregister", "register"])
        XCTAssertEqual(helper.count("keepAlive"), 1, "the helper answered its first ping; later leases do not ping")
    }
    /// launchd no longer restarts a crashed helper. When the app loses it, a new
    /// helper instance is started through its Mach service to restore sleep.
    @MainActor func testLostConnectionStartsAFreshHelperThatRestoresSleep() async throws {
        let helper = FakeAwakeHelper()
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: {}, unregister: {}, openSettings: {}, verifySleepRestored: {})
        var connections = 0
        let client = AwakeServiceClient(service: service, registration: try registration(), refreshAtStartup: false,
                                        makeConnection: { connections += 1; return helper.connection() })
        defer { client.disconnect() }
        try await client.begin(seconds: 0, policy: .init())
        await client.releaseAfterLostConnection()
        XCTAssertEqual(connections, 2)
        XCTAssertTrue(helper.received("end"), "the new instance receives an end and restores a pending marker")
    }
    /// §5 item 11: installing an update quits the app; quitting invalidates the
    /// lease connection so the helper restores sleep before the bundle changes.
    @MainActor func testQuittingForAnUpdateEndsTheHelperConnection() async throws {
        let helper = FakeAwakeHelper()
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: {}, unregister: {}, openSettings: {}, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: try registration(), refreshAtStartup: false,
                                        makeConnection: { helper.connection() })
        let name = "Lunavect.AwakeUpdateQuit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let awake = KeepAwake(client: client, defaults: defaults, scheduleTimer: { _, _ in Timer() })
        await awake.start(for: .fifteenMinutes)
        XCTAssertTrue(awake.isEnabled)
        awake.shutdown()
        let deadline = Date().addingTimeInterval(5)
        while helper.endedConnections == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(helper.endedConnections, 1)
        XCTAssertFalse(awake.isEnabled)
    }

    // MARK: Audit r2 (Y)

    /// R2-Y-03: a helper that stopped during a lease leaves sleep disabled and its
    /// recovery marker behind until launchd starts it again. The first launch of
    /// an updated build must start it through its Mach service (its launch
    /// restores sleep) before refusing to renew the registration; otherwise the
    /// refusal also blocks every Keep Awake start, and nothing ever restores sleep.
    @MainActor func testAStoppedHelpersSleepOverrideIsRestoredThroughItBeforeTheRenewal() async throws {
        let helper = FakeAwakeHelper()
        let sleepDisabled = OSAllocatedUnfairLock(initialState: true)
        helper.onConnect = { sleepDisabled.withLock { $0 = false } }
        var status = SMAppService.Status.enabled
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { status }, register: { events.append("register"); status = .enabled },
            unregister: { events.append("unregister"); status = .notRegistered }, openSettings: {}, verifySleepRestored: {
                events.append("verify-sleep")
                if sleepDisabled.withLock({ $0 }) { throw AwakeFailure.recovery }
            })
        let client = AwakeServiceClient(service: service, registration: try registration(),
                                        makeConnection: { helper.connection() }, callTimeout: 2)
        defer { client.disconnect() }
        await client.waitForStartupRefresh()
        XCTAssertNil(client.registrationFailure, "\(String(describing: client.registrationFailure))")
        XCTAssertTrue(helper.received("end"), "the stopped helper was started once to restore sleep")
        XCTAssertEqual(events, ["verify-sleep", "verify-sleep", "unregister", "register"])
    }

    /// The same path never unregisters while sleep stays disabled: a helper that
    /// cannot restore it (or cannot start) keeps its recovery registration.
    @MainActor func testASleepOverrideTheHelperCannotRestoreStillKeepsTheRegistration() async throws {
        for refuses in [false, true] {
            let helper = FakeAwakeHelper()
            if refuses { helper.refuseConnections() }
            var events: [String] = []
            let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
                unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: {
                    events.append("verify-sleep"); throw AwakeFailure.recovery
                })
            let client = AwakeServiceClient(service: service, registration: try registration(),
                                            makeConnection: { helper.connection() }, callTimeout: 2)
            defer { client.disconnect() }
            await client.waitForStartupRefresh()
            XCTAssertEqual(client.registrationFailure as? AwakeFailure, .recovery)
            XCTAssertFalse(events.contains("unregister"), "refuses=\(refuses): \(events)")
            XCTAssertEqual(events.filter { $0 == "verify-sleep" }.count, 2, "one attempt, no loop: \(events)")
        }
    }

    /// Keep Awake's own active lease is what disables sleep: a registration repair
    /// while it runs is refused as before and never drops that lease's connection.
    @MainActor func testARenewalDuringAnActiveLeaseNeverEndsItToVerifySleep() async throws {
        let helper = FakeAwakeHelper()
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: {
                events.append("verify-sleep"); throw AwakeFailure.recovery
            })
        let registration = try registration()
        registration.rememberCurrentBuild(); registration.rememberAnswer()
        let client = AwakeServiceClient(service: service, registration: registration, refreshAtStartup: false,
                                        makeConnection: { helper.connection() }, callTimeout: 2)
        defer { client.disconnect() }
        try await client.begin(seconds: 0, policy: .init())
        do { try await client.repairRegistration(); XCTFail("Sleep is disabled by the active lease") }
        catch { XCTAssertEqual(error as? AwakeFailure, .recovery) }
        XCTAssertEqual(events, ["verify-sleep"])
        XCTAssertFalse(helper.received("end"), "the active lease was not ended")
        try await client.keepAlive()
    }

    /// R2-Y-02: macOS refuses to renew the registration when Keep Awake is turned
    /// on. The panel keeps the manual repair steps; it does not claim the helper
    /// did not answer, and "Retry connection" would only repeat the refusal.
    @MainActor func testARenewalRefusedWhileStartingKeepsTheManualRepairSteps() async throws {
        let helper = FakeAwakeHelper()
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") }, unregister: {
            events.append("unregister"); throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }, openSettings: {}, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: try registration(),
                                        makeConnection: { helper.connection() }, callTimeout: 2)
        defer { client.disconnect() }
        let name = "Lunavect.AwakeRenewalRefused." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let awake = KeepAwake(client: client, defaults: defaults, scheduleTimer: { _, _ in Timer() })
        await awake.waitForRegistrationCheck()
        XCTAssertEqual(awake.recoveryAction, .repairRegistration)
        await awake.start()
        XCTAssertFalse(awake.isEnabled)
        XCTAssertFalse(helper.received("begin"), "no lease through a registration macOS refused to renew")
        XCTAssertEqual(awake.recoveryAction, .openLoginItems, "\(String(describing: awake.issue))")
        XCTAssertEqual(awake.issue, KeepAwake.registrationGuidance)
    }

    /// R2-Y-01: a refused connection renews the registration at most once per
    /// launch. Repeating unregister/register on every start (manual retries, or
    /// automatic mode every five minutes) cannot repair a refusal it already met.
    @MainActor func testARefusedConnectionRenewsTheRegistrationAtMostOncePerLaunch() async throws {
        let helper = FakeAwakeHelper()
        helper.refuseConnections()
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: { events.append("verify-sleep") })
        let registration = try registration()
        registration.rememberCurrentBuild()
        registration.rememberAnswer()  // the helper answered earlier in this build: no ping
        let client = AwakeServiceClient(service: service, registration: registration, refreshAtStartup: false,
                                        makeConnection: { helper.connection() }, callTimeout: 2)
        defer { client.disconnect() }
        for attempt in 0..<3 {
            do {
                try await client.begin(seconds: 0, policy: .init())
                XCTFail("A refused connection cannot start a lease")
            } catch { XCTAssertEqual(error as? AwakeFailure, .unavailable, "attempt \(attempt): \(error)") }
        }
        XCTAssertEqual(events, ["verify-sleep", "unregister", "register"], "one renewal, then no unregister loop")
    }
}
