import Foundation
import ServiceManagement
#if SWIFT_PACKAGE
import AwakeService
#endif

@MainActor protocol AwakeClient: AnyObject {
    var isAvailable: Bool { get }
    func requestPermission() throws
    func begin(seconds: Int) async throws
    func keepAlive() async throws
    func end() async throws
    func disconnect()
}

@MainActor final class AwakeServiceClient: AwakeClient {
    private let service = SMAppService.daemon(plistName: AwakeServiceID.plist)
    private var connection: NSXPCConnection?
    private let registration = AwakeServiceRegistration()
    var isAvailable: Bool { service.status == .enabled }
    func requestPermission() throws {
        try AwakePermissionAccess.request(status: { service.status }, register: { try service.register() },
                                          openSettings: { SMAppService.openSystemSettingsLoginItems() })
        registration.rememberCurrentBuild()
    }
    func begin(seconds: Int) async throws {
        guard isAvailable else { throw AwakeFailure.permission }
        if connection == nil {
            try await registration.refreshIfNeeded(status: { service.status },
                unregister: { try await self.service.unregister() }, register: { try self.service.register() })
        }
        guard isAvailable else { throw AwakeFailure.permission }
        try await call { $0.begin(seconds: seconds, withReply: $1) }
    }
    func keepAlive() async throws { try await call { $0.keepAlive(withReply: $1) } }
    func end() async throws {
        guard connection != nil else { return }
        try await call { $0.end(withReply: $1) }
        disconnect()
    }
    func disconnect() { connection?.invalidate(); connection = nil }
    deinit { connection?.invalidate() }
    private func call(_ request: @escaping (LunavectAwakeProtocol, @escaping (Bool, String) -> Void) -> Void) async throws {
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
    func refreshIfNeeded(status: () -> SMAppService.Status,
                         unregister: () async throws -> Void, register: () throws -> Void,
                         pause: (Int) async throws -> Void = { attempt in
                             try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                         }) async throws {
        guard let build, defaults.string(forKey: key) != build else { return }
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
