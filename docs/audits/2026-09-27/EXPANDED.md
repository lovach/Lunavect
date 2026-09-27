# Expanded fault and live-integration scenarios — 2026-09-27

This continuation deliberately explored scenarios outside the initial audit and the navigation pass. **Six further defect groups were reproduced and corrected**, plus one source-supported file-reader hardening. **Fifteen additional automated test cases** were added: four Swift, eight Node and three Python/SDK cases. Existing tests were reused for three explicitly enabled system/native checks, and a separate isolated VS Code extension host exercised actual terminal selection.

This is a bounded exploration of the current checkout. It does not certify every possible host, account, macOS version or hardware state. Earlier evidence remains intact in [REPORT.md](REPORT.md) and [NAVIGATION.md](NAVIGATION.md); the current results and source hashes are recorded separately in [expanded-verification.json](expanded-verification.json).

## Reproduced findings

| ID | Trigger and failure before correction | Correction and evidence |
| --- | --- | --- |
| F08 — local metadata cache, P2 | A settled file first failed to read; restoring its UNIX permissions did not invalidate cached `nil`. An in-place equal-size rewrite with restored modification time returned the previous value. A transient decode/read failure with unchanged metadata was cached indefinitely, including after clock rollback. | Identity now includes filesystem change time. Negative cache entries retry after 30 seconds, or after the clock moves behind the cached observation; positive entries retain normal identity-based reuse. Three new tests failed before their corrections and pass afterward. `cache-red-independent.log`, `cache-transient-red.log`, `filesystem-final.log`. The transient failure is injected; no real TCC setting was changed. |
| F09 — companion teardown, P2 | VS Code and JetBrains could finish writing a heartbeat after deactivation had deleted it, leaving a stale endpoint record. | VS Code serializes publications, waits for an in-flight publication before final cleanup and prevents a late startup from starting its timer. JetBrains's final publisher removes temporary/descriptor output after a racing disposal without blocking the IDE thread on that write. Tests cover VS Code startup and periodic publication, and the actual JetBrains class under its SDK with a deliberately blocked FIFO write. Both implementations had failing reproductions. |
| F10 — VS Code workspace boundary, P2 | A workspace opened at `/` rejected a project below it because the prefix comparison expected `//`. | Canonical path comparison uses relative path boundaries. Root, alias, descendant, similarly named sibling and parent cases are covered. The root case failed before correction. |
| F11 — companion payload validation, P3 | The VS Code path limit counted JavaScript code units instead of UTF-8 bytes, and accepted control characters rejected by the native protocol. | The companion enforces the 4,096-byte bound and rejects C0/C1 controls. Exact-byte boundary, multibyte overflow and control characters are covered. Trailing-line-terminator session IDs were also tested and already rejected correctly; they were not counted as a defect. |
| F12 — companion time budgets, P2 | Slowly arriving partial input repeatedly reset an inactivity timer and kept a connection alive beyond its intended budget. Focus-confirmation loops also used wall time, so rolling the clock backward could extend them. | A fixed per-connection timer replaces the sliding inactivity timeout. Focus confirmation uses monotonic time. A real socket with trickle traffic and a deterministic virtual-clock rollback fixture failed before correction and pass afterward. The Mac's actual clock was not changed. |
| F13 — cancelled requests focus late, P2 | A request cancelled while terminal discovery was pending still focused the terminal once its PID arrived. Provider activation/command discovery had the same unchecked async boundary. | Each connection now carries an abort signal through the focus handler. It is checked before dispatch and after async discovery/activation. Delayed terminal discovery failed before correction; terminal discovery, provider activation, command discovery and a real disconnected-socket callback now pass without a late focus/open command. Already dispatched editor actions cannot be recalled. |

**H01 — source-supported hardening, not a reproduced file-swap race:** the native descriptor reader previously checked the path, then opened it without nonblocking mode or validating the opened file's type/owner/permissions. A replacement between those steps could invalidate the assumptions. The reader now opens with `O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`, uses `fstat` and bounds the data. Its new test covers a real FIFO, directory, symlink, public permissions, malformed JSON, exact 16,384-byte input and oversize input. The FIFO returns promptly; the actual racing replacement was not induced.

## Scenarios that passed without a product correction

| Direction | What was actually exercised | Result / limit |
| --- | --- | --- |
| Interrupted migration | Synthetic `ENOSPC` on the second durable write; earlier completed copy; originals; retry | Originals stayed byte-identical, incomplete output was removed and retry completed the remaining files. No real volume was filled. |
| Concurrent migration writer | Another writer creates the destination between validation and exclusive creation | The foreign file survived; migration failed instead of overwriting it, and the next run reported the conflict. |
| Real Apple Terminal | Fresh inert native process plus detached child; recorded TTY; initially minimized fixture window; production `SessionNavigation.open` | Correct tab/window focused and unminimized. Only owned fixture processes/windows were cleaned up. This was the test host, not the signed shipping app. |
| Real VS Code companion | Private development profile and extension directory; separate inert Claude/Codex-named terminals; ambiguous ancestry; closed tab | Both exact terminals selected; the expected window was focused; ambiguity and closed targets rejected. No provider extension account was used. |
| Real VS Code through Lunavect | Fresh process origin → native descriptor discovery/validation → native `SessionNavigation.open` → URI callback → focus acknowledgment | Passed for both fixture providers in an isolated VS Code test host. This newly exercises the native app route, not only a direct socket client. |
| System sleep-setting read | `AwakeLeaseTests.testSystemSettingReadOnlyProbe` against the real `pmset -g` | Passed. No sleep setting, helper approval, power state or physical lid state was changed. |
| Process cleanup | Check recorded fixture PIDs after tests | Every recorded fixture process exited. Saved fixture PIDs are evidence only and must never be reused as future test targets. |

These are new live observations for Terminal and VS Code. Real JetBrains terminal UI was not rerun: its fresh result is an SDK-backed lifecycle fixture. The earlier release's live JetBrains result remains historical.

## Final verification

| Check | Result / scope |
| --- | --- |
| Final full check | `run.toF9OKm8`: **736 Swift passed, 59 skipped, 0 failed** (795 total); **110 Python passed, 1 skipped, 0 failed** (111 total); **16 Node passed**, none skipped |
| Extra SDK-backed Python case | JetBrains heartbeat shutdown fixture passed with the actual IntelliJ SDK; package/source verification also passed (two tests). The SDK case remains an explicit skip in the normal full run. |
| Built AppIntent resources | One additional test passed against the built app/widget |
| Build / resources / provenance | Universal unsigned Release app/widget/helpers, widget fallback and private-ABI probes, bundled resources and source/index integrity passed |
| Thread Sanitizer | 43 selected IDE transport/cache/session-lifecycle tests passed, zero skips, no TSan reports. Swift implementation did not change afterward. |
| Live system/native checks | Apple Terminal navigation, VS Code native navigation for both inert fixture providers, and read-only `pmset -g`: three explicitly enabled tests passed separately |
| Actual VS Code extension host | Exact active terminal/window, ambiguous target and closed target checks passed; repeated after the final cancellation correction |
| Host / toolchain | Apple silicon, macOS 26.6.2, Xcode 26.6, Swift 6.3.3; other hosts remain outside this run |

The companion installers were rebuilt from the current sources as **0.1.1**. Package/source hashes, included scripts and Java classes are checked; the main app version was not advanced and the installed companions were not replaced. The development VS Code host loaded the current source directly.

Full checks passed before the transient-cache and delayed-cancellation fixtures exposed additional cases. The cache correction was followed by fresh TSan and full-check runs; the final companion cancellation correction was followed by another full check and another live native VS Code run. The final source/index were frozen during those runs. Only audit documents were edited afterward, and all 282 recorded implementation/test/config/resource hashes were rechecked.

## Reproduction and evidence

- `swift test --jobs 2 --filter 'LocalFileCacheTests|IDEBridgeTests|SessionStoreLifecycleTests'`
- `node --test integrations/vscode/protocol.test.js integrations/vscode/routing.test.js`
- `python3 -B -m unittest discover -s Tests/Scripts`
- With the verified IntelliJ IDEA 2026.2 SDK: `PYTHONPATH=Tests/Scripts LUNAVECT_JETBRAINS_SDK='/path/IntelliJ IDEA.app' python3 -B -m unittest test_ide_connectors`
- Read-only system probe: `LUNAVECT_TEST_AWAKE=1 swift test --jobs 2 --filter AwakeLeaseTests.testSystemSettingReadOnlyProbe`

Native navigation uses the existing explicit fixture tests and newly created private processes. Historical JSON files contain expired PIDs and are not reusable navigation inputs. Private raw evidence and fixture launchers are in the local `expanded-audit-evidence` directory; no real session transcript, credential, token or account output is included in the committed report.

One initial Terminal run recorded the front window created during application startup instead of the window containing the new fixture TTY. The harness was corrected to find its own window by exact TTY, and the fresh run passed. The slow-peer harness was also corrected to count the expected `EPIPE`/reset on a timed-out connection as closure. These were fixture issues, not additional product defects.

## Explicitly still unverified

- The new helper's Automation attribution, first consent, denial and revocation in the intended signed Lunavect build; live iTerm2 focus.
- Authenticated Claude/Codex provider panels, remote workspaces, the reporter's Mac, the current full JetBrains UI matrix and other editor versions/products.
- Signed install/update/rollback across released versions; helper approval/revocation; reboot/crash/power-loss and physical lid, battery or thermal behavior.
- Desktop WidgetKit placement and refresh across that signed update. Passing the widget build and ABI probes does not establish placement.
- Complete VoiceOver and physical keyboard interaction, all native-control rendering, languages, contrast settings and hardware/macOS combinations.
- Whole-product random fuzzing or exhaustive thread schedules. The fault fixtures are deterministic, scoped tests.

The normal full-run skips remain explicit even when a particular test was also exercised by a separate opt-in command. No skipped test was silently converted to a normal-suite pass.
