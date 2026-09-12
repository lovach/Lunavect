import Foundation
import Darwin
#if SWIFT_PACKAGE
import AwakeService
#endif

final class AwakePeer: NSObject, LunavectAwakeProtocol {
    let id = UUID()
    let queue: DispatchQueue
    let lease: AwakeLease
    init(queue: DispatchQueue, lease: AwakeLease) { self.queue = queue; self.lease = lease }
    private func perform(_ reply: @escaping (Bool, String) -> Void, _ action: @escaping () throws -> Void) {
        queue.async {
            do { try action(); reply(true, "") }
            catch { reply(false, (error as? AwakeFailure ?? .system).rawValue) }
        }
    }
    func begin(seconds: Int, withReply reply: @escaping (Bool, String) -> Void) {
        perform(reply) { try self.lease.begin(owner: self.id, seconds: seconds) }
    }
    func keepAlive(withReply reply: @escaping (Bool, String) -> Void) {
        perform(reply) { try self.lease.keepAlive(owner: self.id) }
    }
    func end(withReply reply: @escaping (Bool, String) -> Void) {
        perform(reply) { try self.lease.end(owner: self.id) }
    }
    func disconnected() { queue.async { try? self.lease.end(owner: self.id) } }
}

final class AwakeListener: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "com.weekleft.awake-lease")
    let lease: AwakeLease
    init(lease: AwakeLease) { self.lease = lease }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let peer = AwakePeer(queue: queue, lease: lease)
        connection.exportedInterface = NSXPCInterface(with: LunavectAwakeProtocol.self)
        connection.exportedObject = peer
        connection.invalidationHandler = { peer.disconnected() }
        connection.interruptionHandler = { peer.disconnected() }
        connection.resume()
        return true
    }
}

do {
    guard geteuid() == 0 else { throw AwakeFailure.permission }
    let lease = try AwakeLease(setting: SystemSleepSetting(), journal: SystemAwakeJournal(), safety: AwakeSafety.failure)
    let delegate = AwakeListener(lease: lease)
    let listener = NSXPCListener(machServiceName: AwakeServiceID.label)
    listener.setConnectionCodeSigningRequirement(try AwakeServiceID.requirement(for: AwakeServiceID.app))
    listener.delegate = delegate
    let timer = DispatchSource.makeTimerSource(queue: delegate.queue)
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler { lease.tick() }
    timer.resume()
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: delegate.queue)
    termination.setEventHandler { lease.shutdown(); exit(0) }
    termination.resume()
    listener.resume()
    withExtendedLifetime((listener, delegate, timer, termination)) { dispatchMain() }
} catch {
    // launchd retries, including restoration after transient pmset failures.
    fputs("Lunavect Awake could not initialize: \((error as? AwakeFailure ?? .system).rawValue)\n", stderr)
    exit(1)
}
