import Foundation
import ServiceManagement
#if SWIFT_PACKAGE
import AwakeService
#endif

@MainActor protocol AwakeClient: AnyObject {
    var isAvailable: Bool { get }
    func requestPermission() throws
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws
    func configure(policy: AwakeSafetyPolicy) async throws
    func keepAlive() async throws
    func end() async throws
    func disconnect()
}

@MainActor final class AwakeServiceClient: AwakeClient {
    private let service: AwakeServiceAccess
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
    init(service: AwakeServiceAccess? = nil, registration: AwakeServiceRegistration? = nil,
         refreshAtStartup: Bool = true) {
        self.service = service ?? .live(); self.registration = registration ?? AwakeServiceRegistration()
        if refreshAtStartup {
            startupRefresh = Task { [weak self] in
                guard let self, self.isAvailable else { return }
                do { try await self.refreshRegistration(); self.registrationFailure = nil }
                catch { self.registrationFailure = error }
            }
        }
    }
    var isAvailable: Bool { service.status == .enabled }
    private func refreshRegistration() async throws {
        try await registration.refreshIfNeeded(status: { service.status },
            unregister: {
                try await self.service.verifySleepRestored()
                try await self.service.unregister()
            }, register: { try self.service.register() })
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
        if connection == nil {
            try await refreshRegistration()
        }
        guard isAvailable else { throw AwakeFailure.permission }
        let request: (LunavectAwakeProtocol, @escaping @Sendable (Bool, String) -> Void) -> Void = {
            $0.beginConfigured(seconds: seconds, allowBattery: policy.allowBattery,
                               batteryProtection: policy.batteryProtection, minimumBatteryPercent: policy.minimumBatteryPercent,
                               thermalProtection: policy.thermalProtection, withReply: $1)
        }
        do { try await call(request) }
        catch AwakeFailure.unavailable {
            // BTM may retain the old bundle's file identity after an atomic update.
            // Refresh that registration once; permission and signing errors never retry.
            try await registration.refreshIfNeeded(force: true, status: { service.status },
                unregister: {
                    try await self.service.verifySleepRestored()
                    try await self.service.unregister()
                }, register: { try self.service.register() })
            guard isAvailable else { throw AwakeFailure.permission }
            try await call(request)
        }
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
        if let verifyRestored { try verifyRestored() } else { try await service.verifySleepRestored() }
        if service.status == .enabled || service.status == .requiresApproval {
            try await service.unregister()
        }
        guard service.status == .notRegistered || service.status == .notFound else { throw AwakeFailure.permission }
        registration.forgetCurrentBuild()
    }
    private func call(_ request: @escaping (LunavectAwakeProtocol, @escaping @Sendable (Bool, String) -> Void) -> Void) async throws {
        let connection: NSXPCConnection
        if let existing = self.connection { connection = existing }
        else {
            connection = NSXPCConnection(machServiceName: AwakeServiceID.label, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: LunavectAwakeProtocol.self)
            connection.setCodeSigningRequirement(try AwakeServiceID.requirement(for: AwakeServiceID.label))
            connection.resume()
            self.connection = connection
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let reply = AwakeReply(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { reply.finish(.failure(AwakeFailure.unavailable)) }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(.failure(AwakeFailure.unavailable)) }) as? LunavectAwakeProtocol else {
                    reply.finish(.failure(AwakeFailure.unavailable)); return
                }
                request(proxy) { success, reason in
                    reply.finish(success ? .success(()) : .failure(AwakeFailure(rawValue: reason) ?? .system))
                }
            }
        } catch { disconnect(); throw error }
    }
}

/// Replacing an app bundle leaves the old daemon executable mapped in memory.
/// Renew its registration before the first session in an updated build, so XPC
/// can validate the helper's current on-disk signature. Never weaken that check.
@MainActor final class AwakeServiceRegistration {
    private let defaults: UserDefaults
    private let build: String?
    private let key = "awake.registeredBuild"
    init(defaults: UserDefaults = .standard,
         build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        self.defaults = defaults; self.build = build
    }
    func rememberCurrentBuild() {
        if let build { defaults.set(build, forKey: key) }
    }
    func forgetCurrentBuild() { defaults.removeObject(forKey: key) }
    func refreshIfNeeded(force: Bool = false, status: () -> SMAppService.Status,
                         unregister: () async throws -> Void, register: () throws -> Void,
                         pause: (Int) async throws -> Void = { attempt in
                             try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                         }) async throws {
        guard force || (build != nil && defaults.string(forKey: key) != build) else { return }
        guard status() == .enabled else { throw AwakeFailure.permission }
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
