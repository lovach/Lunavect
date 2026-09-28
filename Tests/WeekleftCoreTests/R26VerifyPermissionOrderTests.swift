import XCTest
@testable import WeekleftCore

/// V2 (independent check of 0.2.6, S2): hook helpers of concurrently started tool
/// calls can write in either order. Their record keeps the time each helper started
/// (f38ab8c) and drops an event older than the record. The outcome of one delivery
/// order must equal the other (metamorphic relation): a call that started before a
/// permission dialog opened must not end that dialog (S2 invariant I4), whichever
/// helper took the lock first. Payloads follow the documented hook input.
final class R26VerifyPermissionOrderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ steps: [(String, [String: Any], Double)]) throws -> SessionRecord? {
        var record: SessionRecord?
        for (name, extra, seconds) in steps {
            var payload: [String: Any] = ["session_id": "parent-session", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
            payload.merge(extra) { $1 }
            record = try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: record,
                                             now: start.addingTimeInterval(seconds), client: .terminal)
        }
        return record
    }

    /// Claude runs read-only calls concurrently: a Read and a WebFetch that needs
    /// approval start together; the WebFetch dialog opens while the Read still runs.
    func testAConcurrentCallsResultDoesNotEndTheOtherCallsDialogInEitherDeliveryOrder() throws {
        let prompt = ("UserPromptSubmit", [String: Any](), 0.0)
        let read = ("PreToolUse", ["tool_name": "Read", "tool_use_id": "toolu_read", "tool_input": ["file_path": "/f"]] as [String: Any], 1.000)
        let fetch = ("PreToolUse", ["tool_name": "WebFetch", "tool_use_id": "toolu_fetch", "tool_input": ["url": "https://example.com"]] as [String: Any], 1.001)
        let request = ("PermissionRequest", ["tool_name": "WebFetch", "tool_input": ["url": "https://example.com"], "permission_mode": "default"] as [String: Any], 1.2)
        let readDone = ("PostToolUse", ["tool_name": "Read", "tool_use_id": "toolu_read", "tool_input": ["file_path": "/f"]] as [String: Any], 1.5)

        let inOrder = try XCTUnwrap(record([prompt, read, fetch, request, readDone]))
        XCTAssertEqual(inOrder.session.phase, .permission, "Control: the Read started before the dialog")
        XCTAssertEqual(inOrder.approvals?.count, 1)

        // The WebFetch helper, started 1 ms later, takes the capture lock first.
        let swapped = try XCTUnwrap(record([prompt, fetch, read, request, readDone]))
        XCTExpectFailure("R26-V2-02: the Read's PreToolUse is older than the record and dropped whole, so its result counts as a call never seen to start and ends the open WebFetch dialog", strict: true) {
            XCTAssertEqual(swapped.session.phase, .permission, "The WebFetch dialog is still open")
            XCTAssertEqual(swapped.approvals?.count, 1)
        }
    }
}
