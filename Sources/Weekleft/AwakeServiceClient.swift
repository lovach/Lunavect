import Foundation
import OSLog
import ServiceManagement
#if SWIFT_PACKAGE
import AwakeService
import WeekleftCore
#endif

@MainActor protocol AwakeClient: AnyObject {
    var isAvailable: Bool { get }
    func requestPermission() throws
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws
    func configure(policy: AwakeSafetyPolicy) async throws
    func keepAlive() async throws
    func end() async throws
    func disconnect()
    /// The launch-time registration renewal that failed, once it has finished.
    func registrationProblem() async -> Error?
    /// Unregisters and registers the helper again at the user's request.
    func repairRegistration() async throws
    /// After losing the helper, starts a new instance so it restores sleep.
    func releaseAfterLostConnection() async
    func openLoginItems()
}
extension AwakeClient {
    func registrationProblem() async -> Error? { nil }
    func repairRegistration() async throws {}
    func releaseAfterLostConnection() async {}
    func openLoginItems() {}
}

/// The helper is registered but launchd does not start it: it answered neither a
/// short ping nor a lease request, even after one renewal of its registration.
/// Typical cause: a background-item record left by an older build or signing team.
struct AwakeHelperNotStarting: Error {}

/// The helper did not answer in time. One slow reply says nothing about its
/// registration; only a second timeout in a row or an unanswered first ping in a
/// new build renews the registration, once per launch.
struct AwakeCallTimeout: Error {}

/// ServiceManagement refused to renew the helper's registration while Keep Awake
/// was being turned on. Retrying the connection repeats the refusal; the manual
/// repair steps apply (audit r2 R2-Y-02).
struct AwakeRegistrationRefused: Error { let underlying: Error }

@MainActor final class AwakeServiceClient: AwakeClient {
    typealias ConnectionFactory = @MainActor () throws -> NSXPCConnection
    /// Longer than the helper's slowest begin: three pmset runs of up to 6 s each.
    nonisolated static let callTimeout: TimeInterval = 20
    /// A keep-alive without a lease runs no pmset: a started helper answers at once.
    nonisolated static let pingTimeout: TimeInterval = 3
    private let service: AwakeServiceAccess
    private let makeConnection: ConnectionFactory
    private let callTimeout: TimeInterval
    private let pingTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.weekleft.app", category: "awake")
    /// Timeouts renew the registration at most once per launch: no unregister loop.
    private var timeoutRenewalUsed = false
    /// So does a refused connection (audit r2 R2-Y-01).
    private var refusalRenewalUsed = false
    private var consecutiveTimeouts = 0
    // The nonisolated lifetime holder can invalidate during destruction without
    // reading main-actor storage from a nonisolated deinit.
    private let connectionLifetime = AwakeConnectionLifetime()
    private var connection: NSXPCConnection? {
        get { connectionLifetime.connection }
        set { connectionLifetime.connection = newValue }
    }
    private let registration: AwakeServiceRegistration
    private var startupRefresh: Task<Void, Never>?
    private(set) var registrationFailure: Error?
    /// - Parameter makeConnection: an unresumed connection to the helper; the
    ///   default is the privileged service with its code-signing requirement.
    init(service: AwakeServiceAccess? = nil, registration: AwakeServiceRegistration? = nil,
         refreshAtStartup: Bool = true, makeConnection: ConnectionFactory? = nil,
         callTimeout: TimeInterval = AwakeServiceClient.callTimeout, pingTimeout: TimeInterval = AwakeServiceClient.pingTimeout) {
        self.service = service ?? .live(); self.registration = registration ?? AwakeServiceRegistration()
        self.callTimeout = callTimeout; self.pingTimeout = min(pingTimeout, callTimeout)
        self.makeConnection = makeConnection ?? {
            // Fixtures inject their helper; a test never reaches the root daemon.
            guard !LiveWriteGuard.underTestsForStores else { throw AwakeFailure.unavailable }
            let connection = NSXPCConnection(machServiceName: AwakeServiceID.label, options: .privileged)
            connection.setCodeSigningRequirement(try AwakeServiceID.requirement(for: AwakeServiceID.label))
            return connection
        }
        if refreshAtStartup {
            startupRefresh = Task { [weak self] in
                guard let self else { return }
                self.registration.resumeInterruptedRefresh(status: { self.service.status },
                                                           register: { try self.service.register() })
                guard self.isAvailable else { return }
                do { try await self.refreshRegistration(); self.registrationFailure = nil }
                catch {
                    self.registrationFailure = error
                    self.logger.error("Helper registration renewal failed at launch: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
    func registrationProblem() async -> Error? {
        await startupRefresh?.value
        return registrationFailure
    }
    func repairRegistration() async throws {
        await startupRefresh?.value
        do {
            try await renewRegistration()
            registrationFailure = nil
            logger.notice("Helper registration renewed on request")
        } catch {
            logger.error("Requested helper registration renewal failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
    func openLoginItems() { service.openSettings() }
    /// Invoke after a lease connection failed. The Mach service starts a new helper
    /// instance, whose launch restores sleep a crashed instance left disabled; an
    /// end from this new connection never touches another connection's lease.
    func releaseAfterLostConnection() async {
        disconnect()
        do { try await call({ $0.end(withReply: $1) }, timeout: min(5, callTimeout)) }
        catch { logger.error("No helper answered after a lost connection: \(String(describing: error), privacy: .public)") }
        disconnect()
    }
    var isAvailable: Bool { service.status == .enabled }
    private func refreshRegistration() async throws {
        try await registration.refreshIfNeeded(status: { service.status },
            unregister: {
                try await self.verifySleepRestoredThroughHelper()
                try await self.service.unregister()
            }, register: { try self.service.register() })
    }
    /// A helper that stopped during a lease leaves sleep disabled with its recovery
    /// marker until launchd starts it again, and its launch restores sleep. Start it
    /// once through its Mach service before refusing to touch the registration;
    /// never while this client may hold a lease (audit r2 R2-Y-03).
    private func verifySleepRestoredThroughHelper() async throws {
        do { try await service.verifySleepRestored() }
        catch AwakeFailure.recovery where connection == nil {
            logger.notice("Sleep is still disabled; asking the helper to restore it first")
            await releaseAfterLostConnection()
            try await service.verifySleepRestored()
        }
    }
    /// Registration errors during a start keep their meaning: AwakeFailure
    /// (permission, recovery) as before, a ServiceManagement error as a refusal.
    private func renewing(_ body: () async throws -> Void) async throws {
        do { try await body() }
        catch let failure as AwakeFailure { throw failure }
        catch { throw AwakeRegistrationRefused(underlying: error) }
    }
    /// Waits for proactive old-helper maintenance without starting a lease.
    func waitForStartupRefresh() async { await startupRefresh?.value }
    func requestPermission() throws {
        let wasRegistered = service.status == .enabled || service.status == .requiresApproval
        try AwakePermissionAccess.request(status: { service.status }, register: { try service.register() },
                                          openSettings: { service.openSettings() })
        if !wasRegistered { registration.rememberCurrentBuild() }
    }
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws {
        await startupRefresh?.value
        guard isAvailable else { throw AwakeFailure.permission }
        let fresh = connection == nil
        if fresh {
            try await renewing { try await self.refreshRegistration() }
        }
        guard isAvailable else { throw AwakeFailure.permission }
        let request: (LunavectAwakeProtocol, @escaping @Sendable (Bool, String) -> Void) -> Void = {
            $0.beginConfigured(seconds: seconds, allowBattery: policy.allowBattery,
                               batteryProtection: policy.batteryProtection, minimumBatteryPercent: policy.minimumBatteryPercent,
                               thermalProtection: policy.thermalProtection, withReply: $1)
        }
        var renewed = false
        // launchd accepts messages for a registered service it cannot start (a
        // background-item record of an older build or signing team) and never
        // answers. Before the first lease in a build, a short ping tells that apart
        // from a helper that is slow to change the sleep setting (audit H-01, H-03).
        if fresh, !registration.helperAnswered {
            do {
                try await call({ $0.keepAlive(withReply: $1) }, timeout: pingTimeout)
                registration.rememberAnswer()
            } catch let error where error is AwakeCallTimeout || error as? AwakeFailure == .unavailable {
                logger.error("Helper did not answer a ping: \(String(describing: error), privacy: .public)")
                guard !timeoutRenewalUsed else { throw AwakeHelperNotStarting() }
                timeoutRenewalUsed = true
                try await renewing { try await self.renewRegistration() }
                renewed = true
            } catch {
                // Refusing a keep-alive without a lease is an answer: the helper runs.
                registration.rememberAnswer()
            }
        }
        do {
            try await call(request)
        } catch AwakeFailure.unavailable where !renewed && !refusalRenewalUsed {
            // BTM may retain the old bundle's file identity after an atomic update.
            // Refresh that registration once per launch; permission and signing
            // errors never retry, and a later refusal is reported as it is.
            logger.error("Helper connection was refused; renewing its registration")
            refusalRenewalUsed = true
            try await renewing { try await self.renewRegistration() }
            try await call(request)
        } catch is AwakeCallTimeout {
            consecutiveTimeouts += 1
            // One slow reply says nothing about the registration. A helper that
            // never answered after a renewal, or a second timeout in a row, does.
            if renewed { throw AwakeHelperNotStarting() }
            guard consecutiveTimeouts >= 2, !timeoutRenewalUsed else { throw AwakeCallTimeout() }
            logger.error("Second helper timeout in a row; renewing its registration")
            timeoutRenewalUsed = true
            try await renewing { try await self.renewRegistration() }
            do { try await call(request) }
            catch is AwakeCallTimeout { throw AwakeHelperNotStarting() }
        } catch let failure as AwakeFailure where failure != .unavailable {
            // A refusal (battery, busy, external override) is an answer.
            consecutiveTimeouts = 0; registration.rememberAnswer()
            throw failure
        }
        consecutiveTimeouts = 0
        registration.rememberAnswer()
    }
    private func renewRegistration() async throws {
        try await registration.refreshIfNeeded(force: true, status: { service.status },
            unregister: {
                try await self.verifySleepRestoredThroughHelper()
                try await self.service.unregister()
            }, register: { try self.service.register() })
        guard isAvailable else { throw AwakeFailure.permission }
    }
    func configure(policy: AwakeSafetyPolicy) async throws {
        try await call {
            $0.configure(allowBattery: policy.allowBattery, batteryProtection: policy.batteryProtection,
                         minimumBatteryPercent: policy.minimumBatteryPercent,
                         thermalProtection: policy.thermalProtection, withReply: $1)
        }
    }
    func keepAlive() async throws { try await call { $0.keepAlive(withReply: $1) } }
    func end() async throws {
        guard connection != nil else { return }
        try await call { $0.end(withReply: $1) }
        disconnect()
    }
    func disconnect() { connection?.invalidate(); connection = nil }
    /// Invoke from this installed app before deleting its bundle. Never unregister
    /// while sleep restoration is pending: the daemon must remain able to retry.
    func prepareForRemoval(verifyRestored: (() throws -> Void)? = nil) async throws {
        await startupRefresh?.value
        try await end()
        disconnect()
        if let verifyRestored { try verifyRestored() } else { try await verifySleepRestoredThroughHelper() }
        if service.status == .enabled || service.status == .requiresApproval {
            try await service.unregister()
        }
        guard service.status == .notRegistered || service.status == .notFound else { throw AwakeFailure.permission }
        registration.forgetCurrentBuild()
    }
    private func call(_ request: @escaping (LunavectAwakeProtocol, @escaping @Sendable (Bool, String) -> Void) -> Void,
                      timeout: TimeInterval? = nil) async throws {
        let connection: NSXPCConnection
        if let existing = self.connection { connection = existing }
        else {
            connection = try makeConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: LunavectAwakeProtocol.self)
            connection.resume()
            self.connection = connection
        }
        let timeout = timeout ?? callTimeout
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let reply = AwakeReply(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { reply.finish(.failure(AwakeCallTimeout())) }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(.failure(AwakeFailure.unavailable)) }) as? LunavectAwakeProtocol else {
                    reply.finish(.failure(AwakeFailure.unavailable)); return
                }
                request(proxy) { success, reason in
                    reply.finish(success ? .success(()) : .failure(AwakeFailure(rawValue: reason) ?? .system))
                }
            }
        } catch {
            // Drop only the connection this call used. A stop and a new start
            // can replace it meanwhile; that newer lease must survive.
            connection.invalidate()
            if self.connection === connection { self.connection = nil }
            throw error
        }
    }
}

/// Replacing an app bundle leaves the old daemon executable mapped in memory.
/// Renew its registration before the first session in an updated build, so XPC
/// can validate the helper's current on-disk signature. Never weaken that check.
@MainActor final class AwakeServiceRegistration {
    private let defaults: UserDefaults
    private let build: String?
    private let key = "awake.registeredBuild"
    private let pendingKey = "awake.registrationRenewalPending"
    /// The build whose helper has answered at least once.
    private let answeredKey = "awake.answeredBuild"
    init(defaults: UserDefaults = .standard,
         build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        self.defaults = defaults; self.build = build
    }
    func rememberCurrentBuild() {
        if let build { defaults.set(build, forKey: key) }
    }
    func forgetCurrentBuild() {
        defaults.removeObject(forKey: key); defaults.removeObject(forKey: pendingKey); defaults.removeObject(forKey: answeredKey)
    }
    var helperAnswered: Bool { build == nil || defaults.string(forKey: answeredKey) == build }
    func rememberAnswer() {
        if let build, defaults.string(forKey: answeredKey) != build { defaults.set(build, forKey: answeredKey) }
    }
    /// Completes a renewal that quitting interrupted after its unregister step.
    /// Only that unfinished maintenance is resumed: a helper that is still
    /// registered, awaits approval or was removed on purpose is left alone.
    func resumeInterruptedRefresh(status: () -> SMAppService.Status, register: () throws -> Void) {
        guard defaults.bool(forKey: pendingKey) else { return }
        defaults.removeObject(forKey: pendingKey)
        guard status() == .notRegistered else { return }
        try? register()
        if status() == .enabled || status() == .requiresApproval { rememberCurrentBuild() }
    }
    func refreshIfNeeded(force: Bool = false, status: () -> SMAppService.Status,
                         unregister: () async throws -> Void, register: () throws -> Void,
                         pause: (Int) async throws -> Void = { attempt in
                             try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                         }) async throws {
        guard force || (build != nil && defaults.string(forKey: key) != build) else { return }
        guard status() == .enabled else { throw AwakeFailure.permission }
        // Quitting between unregister and register would leave the approved
        // helper unregistered; the next launch then completes the renewal.
        defaults.set(true, forKey: pendingKey)
        defer { defaults.removeObject(forKey: pendingKey) }
        try await unregister()
        for attempt in 0...3 {
            do { try register(); break }
            catch {
                if status() == .requiresApproval || status() == .enabled { break }
                // BTM can briefly return EPERM after a successful asynchronous
                // unregister. Retry only that observed transition, never a
                // signature failure or a pending user-approval state.
                let failure = error as NSError
                guard attempt < 3, status() == .notRegistered,
                      failure.domain == "SMAppServiceErrorDomain", failure.code == 1 else { throw error }
                try await pause(attempt)
            }
        }
        guard status() == .enabled || status() == .requiresApproval else { throw AwakeFailure.permission }
        rememberCurrentBuild()
    }
}

enum AwakePermissionAccess {
    /// register() may report LaunchDeniedByUser even though the daemon was
    /// registered successfully and is now waiting for approval in Settings.
    static func request(status: () -> SMAppService.Status, register: () throws -> Void,
                        openSettings: () -> Void) throws {
        if status() != .enabled && status() != .requiresApproval {
            do { try register() }
            catch {
                guard status() == .requiresApproval || status() == .enabled else { throw error }
            }
        }
        switch status() {
        case .enabled: return
        case .requiresApproval: openSettings()
        default: throw AwakeFailure.permission
        }
    }
}

/// XPC error, response and timeout can race. Resume exactly once.
private final class AwakeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

/// Accessed only by the owning main-actor client. NSXPC invalidation itself is thread-safe.
private final class AwakeConnectionLifetime {
    var connection: NSXPCConnection?
    deinit { connection?.invalidate() }
}

/// SMAppService boundaries are injected for migration/removal fixtures.
@MainActor struct AwakeServiceAccess {
    var readStatus: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () async throws -> Void
    var openSettings: () -> Void
    /// Spawns pmset; runs off the main actor so a slow power query cannot freeze the UI.
    var verifySleepRestored: () async throws -> Void
    var status: SMAppService.Status { readStatus() }
    static func live() -> Self {
        let service = SMAppService.daemon(plistName: AwakeServiceID.plist)
        return Self(readStatus: { service.status }, register: { try service.register() },
                    unregister: { try await service.unregister() },
                    openSettings: { SMAppService.openSystemSettingsLoginItems() },
                    verifySleepRestored: { try await Task.detached(priority: .utility) { try AwakeRemovalSafety.verifyRestored() }.value })
    }
}

enum AwakeRemovalSafety {
    static func verifyRestored() throws {
        // The root-only recovery marker cannot be inspected by this app. The
        // system state must be restored before launchd's final SIGTERM shutdown.
        guard try !SystemSleepSetting().isDisabled() else { throw AwakeFailure.recovery }
    }
}
