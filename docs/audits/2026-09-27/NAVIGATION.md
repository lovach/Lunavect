# Navigation hardening — audit continuation, 2026-09-27

The two remaining transport risks, R01 and R02, are corrected in local code. Nine additional behavior tests pass. This follows initial audit commit `e94078be3b858cd1c02194f2e6376cc8ea520b21`; it is not a published update or a signed-app acceptance result.

## Terminal / iTerm2: responsive, bounded automation

Previously, `SessionNavigation.focusTerminal` executed AppleScript synchronously on MainActor. A slow Terminal could hold the app's interface while it processed several Apple events. Per-event timeouts did not bound the entire search.

`TerminalLocation.focus` now runs the validated script in an owned `/usr/bin/osascript` process through the existing cancellable process runner. Both candidate terminal apps share one ten-second automation budget, followed by at most the runner's bounded cleanup period. Cancellation stops only the owned helper, including a child that ignores TERM. The selected terminal and its client process are never terminated. Nonblocking pipe setup is checked before launching the helper.

Apple documents `NSAppleScript` as main-thread-only in its [Thread Safety Summary](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html); moving the same object into a detached task would not meet that constraint. The subprocess avoids executing it inside the app's UI thread.

Numeric AppleScript errors preserve the existing permission-denied and timeout recovery messages independently of system language. Invalid helper output fails closed. Already-cancelled requests never launch the helper; cancelled navigation does not resume a client, publish success, reopen the panel with an error, or leave the row pending.

## VS Code / JetBrains: cancellable local transport

`IDEBridge.Connection` now uses monotonic uptime for its budget. System-clock changes cannot extend a pending socket request. Descriptor heartbeat timestamps remain wall-clock dates because they are exchanged across processes; their existing validation is unchanged.

Socket setup validates nonblocking mode and SIGPIPE protection. Read/write waits check cancellation in short polling slices, distinguish peer closure from timeout, and preserve a final complete frame sent before closure. Buffered replies are still rejected after the request deadline. The async exchange forwards cancellation into detached workers and closes its descriptor only after the worker finishes. Cancellation during the editor callback is retained as cancellation instead of becoming a connection failure.

## Fresh verification

| Check | Result |
| --- | --- |
| Focused navigation/process/panel suites | 56 passed, 3 explicit live-integration skips, no failures |
| Full `scripts/check.sh`, `run.Jwlb3wfU` | **732 Swift passed, 59 skipped, 0 failed**; **108 Python** and **8 Node** passed |
| Unsigned Release build | Universal app, widget and helpers built; hook and product resources passed |
| Built AppIntent metadata | 1 additional test passed |
| Widget compatibility probes | Passed on this host |
| Build provenance | Source and index remained unchanged throughout the full check |
| Thread Sanitizer, navigation/process/panel suites | **49 passed, 3 live-integration skips**, no failures or TSan reports |
| Temporary build cleanup | Owned registration retired; installed host reasserted; installed binary not replaced |

The new fixtures exercise real `osascript` execution of inert scripts, numeric errors, malformed results, a TERM-ignoring child, main-actor responsiveness during a stalled helper, real private Unix sockets, filled send buffers, cancelled reads/writes, peer EOF, final-frame delivery, expired buffered responses and cancellation before/after an editor callback. They make no model requests and open no real user sessions. The actual system clock was not changed.

The full check covers the final executable code. After it completed, one obsolete test comment was corrected and the audit documents were updated; no executable statement or build configuration changed. [Machine-readable evidence](navigation-verification.json) preserves checked/current hashes and this distinction. The initial [verification.json](verification.json), renders and performance measurements remain evidence for the initial audit source, not new measurements of this continuation.

## Remaining live boundary

The helper's macOS Automation attribution, first-time permission prompt, denied/revoked permissions and actual tab focus still need verification from the intended signed Lunavect build in Terminal and iTerm2. No signed app was installed during this continuation. Stopping a helper cannot undo an Apple event already delivered to the terminal.

Real VS Code / JetBrains windows, authenticated provider panels and supported-version combinations were not newly exercised. The socket deadline bounds transport waits and rejects late replies; it cannot recall a native editor activation already dispatched or force an asynchronous system launch callback to finish. The original audit's widget placement, accessibility, hardware and signed-update boundaries remain open.
