import XCTest
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
    let listener = NSXPCListener.anonymous()
    override init() { super.init(); listener.delegate = self; listener.resume() }
    deinit { listener.invalidate() }

    /// An unresumed client connection, as the production factory returns.
    func connection() -> NSXPCConnection { NSXPCConnection(listenerEndpoint: listener.endpoint) }
    func hold(_ name: String) { lock.withLock { _ = holding.insert(name) } }
    func refuseConnections() { lock.withLock { accepts = false } }
    func received(_ name: String) -> Bool { lock.withLock { calls.contains(name) } }
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
        connection.exportedInterface = NSXPCInterface(with: LunavectAwakeProtocol.self)
        connection.exportedObject = self
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
        let first = AwakeServiceClient(service: service, registration: registration)
        await first.waitForStartupRefresh()
        XCTAssertEqual(first.registrationFailure as? AwakeFailure, .recovery)
        XCTAssertEqual(events, ["verify-sleep"], "Old helper must keep its recovery registration")
        sleepDisabled = false
        let retry = AwakeServiceClient(service: service, registration: registration)
        await retry.waitForStartupRefresh()
        XCTAssertNil(retry.registrationFailure)
        XCTAssertEqual(events, ["verify-sleep", "verify-sleep", "unregister", "register"])
    }
}
