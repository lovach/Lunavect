import Foundation

/// macOS checks a just-written executable on its first run; while other new programs start that check
/// can take over a second (audit 30.09, `agents/flaky.md`). A test whose budget is about the program's
/// answer, not its first launch, runs the fixture once before timing it. Output and input are discarded.
func warmUpFreshExecutable(_ url: URL, timeout: TimeInterval = 10) {
    let process = Process()
    process.executableURL = url
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning { process.terminate(); process.waitUntilExit() }
}
