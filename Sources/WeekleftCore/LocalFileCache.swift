import Darwin
import Foundation

/// Identity of a regular file as reported by lstat. Atomic replacement changes
/// the inode, and in-place writes change size or modification time.
struct LocalFileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    /// Nil for missing files, symbolic links and other non-regular entries.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    /// Two in-place writes of equal size within one timestamp tick are
    /// indistinguishable. Only files unchanged for a moment are reused.
    func isSettled(now: Date = Date()) -> Bool {
        now.timeIntervalSince1970 - (Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9) > 2
    }
}

/// Values decoded from small local files, reused while each file keeps its identity.
/// Pollers call `retain` with the current listing so removed files are forgotten.
final class LocalFileCache<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let identity: LocalFileIdentity
        let value: Value?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for path: String, identity: LocalFileIdentity, now: Date = Date(), decode: () -> Value?) -> Value? {
        guard identity.isSettled(now: now) else { return decode() }
        lock.lock()
        let cached = entries[path]
        lock.unlock()
        if let cached, cached.identity == identity { return cached.value }
        let value = decode()
        // A write between lstat and read leaves an old identity here; the next
        // poll sees the new identity and decodes again.
        lock.lock()
        entries[path] = Entry(identity: identity, value: value)
        lock.unlock()
        return value
    }

    func retain(_ paths: [String]) {
        let current = Set(paths)
        lock.lock()
        entries = entries.filter { current.contains($0.key) }
        lock.unlock()
    }
}
