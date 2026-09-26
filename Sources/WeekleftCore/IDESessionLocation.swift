import Darwin
import Foundation

/// An editor's identity is separate from the provider and from the session's state.
public enum SessionIDE: String, Codable, Sendable {
    case vscode, jetbrains

    public static func identify(bundleIdentifier: String) -> SessionIDE? {
        let identifier = bundleIdentifier.lowercased()
        if ["com.microsoft.vscode", "com.microsoft.vscodeinsiders"].contains(identifier) { return .vscode }
        let products = ["intellij", "intellij.ce", "pycharm", "pycharm.ce", "webstorm", "phpstorm", "goland", "clion", "rider", "rubymine", "datagrip", "rustrover"]
        if products.contains(where: { identifier == "com.jetbrains." + $0 }) { return .jetbrains }
        return nil
    }

    public var client: SessionClient { self == .vscode ? .vscode : .jetbrains }
}

/// Birth time prevents a recycled PID from identifying a different session.
public struct SessionProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedAtMicroseconds: UInt64

    public init(pid: Int32, startedAtMicroseconds: UInt64) {
        self.pid = pid; self.startedAtMicroseconds = startedAtMicroseconds
    }
}

public struct IDESessionLocation: Codable, Equatable, Sendable {
    public let editor: SessionIDE
    public let bundleIdentifier: String
    public let appPath: String
    public let runtime: SessionProcessIdentity
    public let usesTerminal: Bool

    public init(editor: SessionIDE, bundleIdentifier: String, appPath: String,
                runtime: SessionProcessIdentity, usesTerminal: Bool) {
        self.editor = editor; self.bundleIdentifier = bundleIdentifier; self.appPath = appPath
        self.runtime = runtime; self.usesTerminal = usesTerminal
    }
}

public enum IDEProcessLocation {
    struct ProcessInfo {
        let identity: SessionProcessIdentity
        let parentPID: Int32
        let executable: String
        let hasTerminal: Bool
    }

    /// Reads only executable paths, process identities and the controlling-device flag.
    /// No foreign environment, command arguments or terminal contents are read.
    static func process(_ pid: Int32) -> ProcessInfo? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return ProcessInfo(identity: .init(pid: pid, startedAtMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec),
                           parentPID: Int32(info.pbi_ppid),
                           executable: String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self),
                           hasTerminal: info.e_tdev != UInt32.max)
    }

    static func bundleIdentifier(_ appPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    public static func locate(parentPID: Int32, provider: ProviderID) -> IDESessionLocation? {
        locate(parentPID: parentPID, provider: provider, read: process, bundle: bundleIdentifier)
    }

    static func locate(parentPID: Int32, provider: ProviderID, read: (Int32) -> ProcessInfo?,
                       bundle: (String) -> String?) -> IDESessionLocation? {
        var pid = parentPID, seen = Set<Int32>(), runtime: SessionProcessIdentity?, hasTerminal = false
        for _ in 0..<24 {
            guard pid > 1, seen.insert(pid).inserted, let current = read(pid) else { return nil }
            if runtime == nil, SessionProcess.runtimeProvider(ofExecutable: current.executable) == provider {
                runtime = current.identity
            }
            if let range = current.executable.range(of: ".app/Contents/") {
                let appPath = String(current.executable[..<range.lowerBound]) + ".app"
                // Bundled CLI executables do not identify their actual launch host.
                if !current.executable.contains("/Contents/Resources/"),
                   let identifier = bundle(appPath), let editor = SessionIDE.identify(bundleIdentifier: identifier),
                   let runtime {
                    return .init(editor: editor, bundleIdentifier: identifier, appPath: appPath,
                                 runtime: runtime, usesTerminal: hasTerminal)
                }
                if !current.executable.contains("/Contents/Resources/"),
                   ["com.apple.Terminal", "com.googlecode.iterm2", "com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat"].contains(bundle(appPath) ?? "") {
                    return nil
                }
            }
            hasTerminal = hasTerminal || current.hasTerminal
            pid = current.parentPID
        }
        return nil
    }

    /// Refresh ancestry at click time; never trust a persisted PID after a process exits.
    public static func liveAncestry(of runtime: SessionProcessIdentity) -> [Int32] {
        liveAncestry(of: runtime, read: process)
    }

    static func liveAncestry(of runtime: SessionProcessIdentity, read: (Int32) -> ProcessInfo?) -> [Int32] {
        guard let first = read(runtime.pid), first.identity == runtime else { return [] }
        var result: [Int32] = [], pid = runtime.pid
        for _ in 0..<24 {
            guard pid > 1, !result.contains(pid), let current = read(pid) else { break }
            result.append(pid); pid = current.parentPID
        }
        return result
    }
}
