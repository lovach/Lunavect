import Foundation
import Darwin
import IOKit.ps

public struct SystemSleepSetting: SleepSetting {
    public init() {}
    public func isDisabled() throws -> Bool {
        let output = try run(["-g"])
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.first == "SleepDisabled", fields.count == 2 {
                guard fields[1] == "0" || fields[1] == "1" else { throw AwakeFailure.system }
                return fields[1] == "1"
            }
        }
        // pmset omits SleepDisabled when no override has ever been set.
        guard output.contains("System-wide power settings:") else { throw AwakeFailure.system }
        return false
    }
    public func setDisabled(_ disabled: Bool) throws {
        _ = try run(["-a", "disablesleep", disabled ? "1" : "0"])
    }
    private func run(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw AwakeFailure.system
        }
        guard process.terminationStatus == 0 else { throw AwakeFailure.system }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// Root-only, symlink-resistant recovery record. No client supplies a path.
public final class SystemAwakeJournal: AwakeJournal {
    private let directory: Int32
    public init() throws {
        guard geteuid() == 0 else { throw AwakeFailure.permission }
        let path = "/var/db/com.weekleft.awake"
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw AwakeFailure.recovery }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AwakeFailure.recovery }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & 0o077 == 0 else {
            close(fd); throw AwakeFailure.recovery
        }
        directory = fd
    }
    deinit { close(directory) }
    public func hasPendingRestore() throws -> Bool {
        var metadata = stat()
        if fstatat(directory, "restore-sleep", &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw AwakeFailure.recovery
        }
        guard metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0 else { throw AwakeFailure.recovery }
        return true
    }
    public func mark() throws {
        let fd = openat(directory, "restore-sleep", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AwakeFailure.recovery }
        defer { close(fd) }
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw AwakeFailure.recovery }
    }
    public func clear() throws {
        guard unlinkat(directory, "restore-sleep", 0) == 0 || errno == ENOENT,
              fsync(directory) == 0 else { throw AwakeFailure.recovery }
    }
}

public enum AwakeSafety {
    public static func failure(policy: AwakeSafetyPolicy) -> AwakeFailure? {
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        if let failure = policy.failure(onBattery: false, batteryPercent: nil, thermalSeverity: thermal) { return failure }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTransportTypeKey] as? String == kIOPSInternalType,
                  values[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue else { continue }
            var percent: Double?
            if let capacity = values[kIOPSCurrentCapacityKey] as? Int,
               let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percent = Double(capacity) / Double(maximum) * 100
            }
            return policy.failure(onBattery: true, batteryPercent: percent, thermalSeverity: thermal)
        }
        return nil
    }
}
