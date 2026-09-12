import Foundation

public protocol SleepSetting {
    func isDisabled() throws -> Bool
    func setDisabled(_ disabled: Bool) throws
}

public protocol AwakeJournal {
    func hasPendingRestore() throws -> Bool
    func mark() throws
    func clear() throws
}

/// Used only on the daemon's serial queue. A durable marker precedes every
/// mutation, so a new daemon restores sleep before accepting any new lease.
public final class AwakeLease {
    private let setting: SleepSetting
    private let journal: AwakeJournal
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let safety: () -> AwakeFailure?
    private var owner: UUID?
    private var heartbeatDeadline: TimeInterval = 0
    private var endsAt: Date?
    private var pendingRestore = false
    public private(set) var lastFailure: AwakeFailure?

    public init(setting: SleepSetting, journal: AwakeJournal,
                now: @escaping () -> Date = Date.init,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                safety: @escaping () -> AwakeFailure? = { nil }) throws {
        self.setting = setting; self.journal = journal; self.now = now
        self.uptime = uptime; self.safety = safety
        pendingRestore = try journal.hasPendingRestore()
        if pendingRestore { try restore() }
    }

    public func begin(owner requestedOwner: UUID, seconds: Int) throws {
        guard [0, 900, 3600, 14400].contains(seconds) else { throw AwakeFailure.system }
        if let owner, owner != requestedOwner { throw AwakeFailure.busy }
        if let failure = safety() { throw failure }
        if owner == nil {
            if pendingRestore { try restore() }
            guard try !setting.isDisabled() else { throw AwakeFailure.external }
            do { try journal.mark() }
            catch {
                pendingRestore = (try? journal.hasPendingRestore()) ?? false
                throw error
            }
            pendingRestore = true
            do {
                try setting.setDisabled(true)
                guard try setting.isDisabled() else { throw AwakeFailure.system }
            } catch {
                // Even an error may follow a successful system mutation.
                do { try restore() } catch { throw AwakeFailure.recovery }
                throw AwakeFailure.system
            }
        } else {
            try validate()
        }
        owner = requestedOwner
        heartbeatDeadline = uptime() + AwakeServiceID.leaseSeconds
        endsAt = seconds == 0 ? nil : now().addingTimeInterval(TimeInterval(seconds))
        lastFailure = nil
    }

    public func keepAlive(owner requestedOwner: UUID) throws {
        guard owner == requestedOwner else { throw lastFailure ?? AwakeFailure.lost }
        try validate()
        heartbeatDeadline = uptime() + AwakeServiceID.leaseSeconds
    }

    public func end(owner requestedOwner: UUID) throws {
        guard owner == requestedOwner else {
            if owner == nil && pendingRestore { try restore() }
            return
        }
        try restore()
    }

    public func tick() {
        if owner != nil {
            do { try validate() } catch {
                lastFailure = error as? AwakeFailure ?? .system
                try? restore()
            }
        } else if pendingRestore { try? restore() }
    }

    public func shutdown() { if pendingRestore { try? restore() } }

    private func validate() throws {
        var failure: AwakeFailure?
        if uptime() >= heartbeatDeadline || endsAt.map({ now() >= $0 }) == true { failure = .expired }
        else if let unsafe = safety() { failure = unsafe }
        else if try !setting.isDisabled() { failure = .lost }
        if let failure {
            lastFailure = failure
            try restore()
            throw failure
        }
    }

    private func restore() throws {
        // Stop renewing even if restoration fails; tick keeps retrying.
        owner = nil; endsAt = nil
        guard pendingRestore else { return }
        try setting.setDisabled(false)
        guard try !setting.isDisabled() else { throw AwakeFailure.recovery }
        try journal.clear()
        pendingRestore = false
    }
}
