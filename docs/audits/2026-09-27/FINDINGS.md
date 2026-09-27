# Findings — 2026-09-27

Baseline: `1bba24c35674d9b7f6438c104c7811162991a02a`. The initial seven confirmed defect groups, F01–F07, were fixed locally; all seven are P2. The navigation continuation corrected R01/R02. The expanded pass adds six reproduced groups, F08–F13, and source-supported hardening H01, recorded below and in [EXPANDED.md](EXPANDED.md). No claim of absence of other defects is made.

Private red/green logs are under the audit evidence directory, outside Git. Filenames below are relative to that directory. Tests use synthetic state, injected clocks/providers/helpers or private temporary files, not account credentials.

## F01 — Just-expired Claude limits moved into another day/year; DST ambiguity

- **Location:** `Sources/WeekleftCore/ClaudeUsageProbe.swift`, `ClaudeUsageText.resetDate`.
- **Trigger:** a minute-rounded reset just before midnight or New Year is read just afterwards; a clock-only reset falls in the repeated or missing local hour in Vienna.
- **Before:** previous day/year was not considered, plausible future dates took priority over just-expired dates, and nonexistent DST times could normalize to another time. The resulting quota could appear valid for another day or report the wrong reset.
- **Evidence:** failing assertions in `full-audit-regressions-red.log` and `full-audit-time-matrix-red.log`; `ClaudeUsageProbeTests.testJustElapsedResetSurvivesMidnightAndYearRollover` and `testClockOnlyResetHandlesRepeatedAndSkippedDaylightSavingHours`.
- **Correction:** consider adjacent dates/years; prioritize the two-minute just-elapsed interval; match local clocks strictly and consider both occurrences of a repeated hour.
- **Verification:** targeted regression suites and full check passed. A nonexistent spring-forward time remains unknown instead of being invented. Existing valid next-day/year cases continue to pass.
- **Limit:** real provider text remains an external format; synthetic parsing is not a new live account check.

## F02 — A late response survived changing the selected Codex executable

- **Location:** `Sources/Weekleft/AppStore.swift`, `codexPath.didSet` and refresh generation checks.
- **Trigger:** start a quota request, change the selected executable, optionally change it back, then deliver the original response.
- **Before:** the obsolete response was accepted into current state.
- **Evidence:** controlled continuation in `AppStoreLifecycleTests.testChangingCodexPathRejectsLateResponseEvenWhenChangedBack`; red/green logs `full-audit-regressions-{red,green}.log`.
- **Correction:** changing the path invalidates the provider generation even if the final path text equals the original.
- **Verification:** the late response is rejected; a subsequent request using the current resolver succeeds. Full suite and lifecycle tests under Thread Sanitizer passed.
- **Limit:** this fixes quota publication; it does not claim a new IDE/provider sign-in integration test.

## F03 — JSON booleans and malformed reset values masqueraded as numeric quotas

- **Location:** `Sources/WeekleftCore/Models.swift`, `UsageParser`.
- **Trigger:** JSON contains `true`/`false` where a number is expected, or a malformed non-null Codex reset.
- **Before:** Foundation's `NSNumber` bridging accepted booleans as numbers; malformed reset values could silently become an absent reset.
- **Evidence:** 11 failing assertions in `full-audit-parser-red.log`; `UsageParserTests.testJSONBooleansAndMalformedResetValuesCannotBecomeQuotas` uses actual JSON encode/decode bridging.
- **Correction:** reject CFBoolean and nonfinite values; validate numeric window duration and non-null reset. A missing/null Codex reset remains supported.
- **Verification:** invalid boolean/string/object/array inputs fail; valid zero usage and optional reset remain supported; targeted and full checks passed.

## F04 — Moving the wall clock backwards extended a timed Keep Awake lease

- **Location:** `Sources/AwakeService/AwakeLease.swift`, lease begin/validate/restore.
- **Trigger:** a 15-minute lease continues receiving heartbeats while the wall clock moves backwards by one hour.
- **Before:** wall time alone controlled the requested duration; the helper could remain active beyond the chosen period.
- **Evidence:** four failing assertions in `full-audit-awake-red.log`; `AwakeLeaseTests.testClockRollbackCannotExtendTimedLeaseWhileHeartbeatsContinue`.
- **Correction:** add a monotonic duration deadline alongside heartbeat and existing wall-time expiry; clear it on restoration.
- **Verification:** timed lease expires at 900 monotonic seconds; the following untimed lease works normally. Targeted and full checks passed using a fake sleep-setting service. No real power setting was changed.

## F05 — Limit notifications trusted data that the quota display rejected

- **Location:** `Sources/WeekleftCore/LimitAlerts.swift`, `Sources/Weekleft/AppFeatures.swift`.
- **Trigger:** unverified status-line snapshot, future observation, implausible reset, stale per-model quota, or a provider that is no longer enabled.
- **Before:** the notification path used a separate, weaker freshness check and could warn or promise a reset from unsupported data.
- **Evidence:** nine failing assertions in `full-audit-alerts-red.log`; `LimitAlertTrackerTests.testWarningUsesTheSamePerWindowFreshnessAsTheDisplayedQuota` and `FailureNoticeTests.testLimitFailureDoesNotPromiseAResetFromUnverifiedOrStaleModelData`.
- **Correction:** share per-window freshness rules with the display, check model observations and filter disconnected providers. An expired five-hour window does not suppress a valid weekly warning.
- **Verification:** targeted and full checks passed; no real notifications were emitted by these fixtures.

## F06 — Corrupt background counts reached the session badge

- **Location:** `Sources/WeekleftCore/Sessions.swift`, `BackgroundWork`.
- **Trigger:** a stored record contains negative counts or counts whose sum overflows `Int`; an accepted maximum count later receives another hook increment.
- **Before:** invalid stored values decoded successfully; unchecked addition could overflow in badge aggregation.
- **Evidence:** two invalid-decode assertions failed in `full-audit-background-red.log`; `ClaudeBackgroundWorkTests.testCorruptBackgroundCountsCannotReachTheSessionBadge`. A live app crash was not induced; unchecked arithmetic was confirmed from source.
- **Correction:** validate nonnegative, nonoverflowing decoded totals and use saturating addition for subsequent aggregation. Codable keys remain compatible.
- **Verification:** corrupt records are rejected, valid records round-trip, and maximum-boundary increments do not trap. Targeted and full checks passed.

## F07 — Shared state readers did not consistently bound the actual read

- **Location:** `Sources/WeekleftCore/Storage.swift`, `ActivityHistory.swift`, `ActivityDetails.swift`.
- **Trigger:** a valid history JSON padded beyond 32 MB; oversized snapshot; replacement/growth between a path size check and the actual read.
- **Before:** history and snapshot used unbounded `Data(contentsOf:)`; details checked path metadata before an unbounded read. The >32 MB history fixture was accepted.
- **Evidence:** `full-audit-storage-size-red.log`; `DataStorageGuaranteeTests.testOversizedSharedHistoryIsRejectedWithoutDiscardingTheFile`. The file-replacement race is source-supported, not deterministically reproduced.
- **Correction:** one descriptor-based regular-file reader bounds both size and bytes read. Snapshot cap is 1 MiB; history/details cap is 32,000,000 bytes. Existing migration symlinks are resolved; replacement symlinks and special files fail. I/O/oversize failures preserve original bytes rather than treating them as recoverable JSON corruption.
- **Verification:** 27 targeted tests and full check passed, including migration symlinks, exclusive size boundary, original-file preservation and FIFO rejection. FIFO rejection already passed before the change; it is added coverage, not a newly discovered hang.

## Expanded findings

| ID / priority | Location / reproduced failure | Status and evidence |
| --- | --- | --- |
| F08 / P2 | `LocalFileCache.swift`: recovered permissions, equal-size rewrite with restored mtime, or transient failure could leave stale cached data or `nil` | Fixed with change-time identity and bounded negative caching; three before/after regressions |
| F09 / P2 | VS Code `extension.js` and JetBrains `BridgeService.java`: heartbeat publication could outlive teardown and recreate a stale descriptor | Fixed; startup/periodic VS Code races and actual SDK-backed JetBrains blocked-write race reproduced and checked |
| F10 / P2 | VS Code `routing.js`: workspace `/` rejected a descendant project | Fixed; root, alias, descendant, sibling and parent boundary cases checked |
| F11 / P3 | VS Code `routing.js`: path length used code units, accepting over-budget UTF-8 and native-rejected controls | Fixed; byte-exact boundary, multibyte overflow and controls checked |
| F12 / P2 | VS Code transport/routing: trickle input extended the socket lifetime; wall-clock rollback extended focus confirmation | Fixed with absolute connection timer and monotonic focus budget; real socket and controlled-clock tests |
| F13 / P2 | VS Code routing: cancellation during asynchronous terminal discovery could still cause late focus | Fixed with connection abort propagation and checks after async discovery/activation; terminal, provider and disconnected-socket cases checked |
| H01 / hardening | `IDEBridge.swift`: path validation could become stale before opening a replaced file | Opened-file validation and nonblocking bounded read added; FIFO/type/permissions/size cases pass. The actual replacement race was not induced. |

Reproduction logs, consequences, limits and fixes are detailed in [EXPANDED.md](EXPANDED.md); current counts and source hashes are in [expanded-verification.json](expanded-verification.json). These are local, unreleased changes.

## Open engineering risks and audit limits

These were the initial residual risks. R01 and R02 were subsequently addressed as recorded below; their live verification boundaries remain explicit:

- **R01, P2, corrected in code; signed-app verification pending:** synchronous MainActor AppleScript execution was replaced with an owned cancellable helper and one overall automation budget. Real inert scripts, a stalled TERM-ignoring helper, main-actor responsiveness, numeric errors and cancellation cleanup passed. Actual signed-app Automation attribution and tab focus remain unverified. See [continuation evidence](NAVIGATION.md).
- **R02, P3, corrected and locally verified:** the IDE socket budget now uses monotonic uptime; nonblocking setup and SIGPIPE protection are checked. Cancellation propagates to reads/writes and closes the connection after the worker ends. Real socket fixtures cover full send buffers, silent peers, final-frame/EOF behavior, expired buffered replies and cancellation around the editor callback. The system clock was not changed; a controlled monotonic clock verifies budget expiration. See [continuation evidence](NAVIGATION.md).
- **R03, local repository hygiene:** the owner's main checkout contains untracked `Lunavect 2.xcodeproj`; its project file lacks newer IDE source/resource references. Canonical `Lunavect.xcodeproj` matches pinned XcodeGen and builds. The extra project was preserved, not deleted, and is not used by audited scripts.
- **R04, verification boundary:** fresh Terminal and VS Code fixture focus now passed, including production native navigation. Authenticated Claude/Codex provider panels, remote editors, the current full JetBrains UI/version/product matrix, VoiceOver interaction, physical lid/battery/thermal behavior, desktop WidgetKit placement and a signed update cycle remain unverified. JetBrains's new SDK lifecycle check and earlier live UI evidence are distinct.
- **R05, test-render boundary:** the extra fixture's SwiftUI ImageRenderer substitutes a yellow unsupported-view marker for the native Codex path text field. Its explanatory message was inspected; this is not proof of the actual input control's appearance. AppKit renders of long-name activity views are 1x on this host; value-view fixtures are 2x.
- **R06, maintenance:** Release SwiftPM emits existing unused-`fcntl` and test-local MainActor warnings. The build succeeds, but warnings are not counted as zero-warning validation. No arbitrary warning suppression was added.
