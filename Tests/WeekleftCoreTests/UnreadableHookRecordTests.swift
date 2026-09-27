import XCTest
@testable import WeekleftCore

/// S-09 / §5.18: a hook record that no longer decodes (damage, or a stricter
/// decoder such as the 0.2.4 background-count check) was never pruned, was
/// decoded again on every poll, and the next hook silently started from zero.
final class UnreadableHookRecordTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnreadableHookRecord-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ text: String, _ name: String, in directory: URL, modified: Date) throws {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testPruneRemovesOwnedRecordsThatNoLongerDecodeAfterADay() throws {
        let root = try directory(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-2 * 86400), recent = now.addingTimeInterval(-3600)
        try write("{not json", "claude-broken.json", in: root, modified: old)
        try write(#"{"session":{"backgroundWork":{"commands":-1}}}"#, "codex-strict.json", in: root, modified: old)
        try write("{not json", "claude-recent.json", in: root, modified: recent)
        try write("{not json", "claude-kept.json.corrupt-\(UUID().uuidString)", in: root, modified: recent)
        try write("{not json", "claude-gone.json.corrupt-\(UUID().uuidString)", in: root, modified: old)
        try write("{not json", "notes.json", in: root, modified: old)
        try write("{not json", "claude-not valid.json", in: root, modified: old)
        XCTAssertEqual(try SessionHooks.prune(at: root, now: now), 3)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(left.filter { !$0.contains(".corrupt-") }, ["claude-not valid.json", "claude-recent.json", "notes.json"],
                       "Only this monitor's own names are pruned, and only after a day")
        XCTAssertEqual(left.filter { $0.contains(".corrupt-") }.count, 1)
        XCTAssertTrue(left.contains { $0.hasPrefix("claude-kept.json.corrupt-") })
    }

    func testCaptureKeepsAnUnreadableRecordAsideAndSaysSo() throws {
        let root = try directory()
        try write("{not json", "claude-damaged.json", in: root, modified: Date())
        let prompt = try JSONSerialization.data(withJSONObject: ["session_id": "damaged", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture"])
        try SessionHooks.capture(prompt, provider: .claude, at: root, isInternal: { _ in false })
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let aside = names.filter { $0.hasPrefix("claude-damaged.json.corrupt-") }
        XCTAssertEqual(aside.count, 1, "The damaged bytes are kept for diagnosis, not overwritten")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(aside.first))), Data("{not json".utf8))
        let session = try XCTUnwrap(SessionHooks.load(at: root).first)
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(session.hookDiagnostic?.kind, .unreadableRecord, "The lost context is visible to the app")
        // The next event keeps the fact without setting it aside again.
        let tool = try JSONSerialization.data(withJSONObject: ["session_id": "damaged", "hook_event_name": "PreToolUse", "tool_name": "Read", "cwd": "/Users/fixture"])
        try SessionHooks.capture(tool, provider: .claude, at: root, isInternal: { _ in false })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".corrupt-") }.count, 1)
        XCTAssertEqual(SessionHooks.load(at: root).first?.hookDiagnostic?.at, session.hookDiagnostic?.at)
    }
}
