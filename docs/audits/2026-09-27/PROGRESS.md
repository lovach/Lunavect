# Full audit — 2026-09-27

Baseline: `1bba24c35674d9b7f6438c104c7811162991a02a`. Branch: `codex/full-audit-2026-09-27`.

- [x] Verify the physical checkout, branch/worktrees; preserve unrelated local project duplicate.
- [x] Inventory source, tests, configuration, scripts and documentation; record review depth per file.
- [x] Run fresh baseline and retain all skips.
- [x] Review data flow, lifecycle/concurrency, quotas, sessions/IDE, persistence, widgets, privileged helper, privacy and delivery boundaries.
- [x] Reproduce seven defect groups, make bounded corrections, add 14 behavior tests.
- [x] Run independent interval oracle and real private Unix-socket edge cases.
- [x] Run full final checks, pinned project parity, 48 tests under Thread Sanitizer.
- [x] Generate 106 sandboxed native PNGs; inspect representative states and record the unsupported-control limitation.
- [x] Measure three optimized large synthetic workloads.
- [x] Assess the existing installed app signature read-only; keep installed 0.2.3 unchanged.
- [x] Record findings, scenario matrix, per-file coverage, skips and verification metadata; recheck implementation hashes.

Completed scope: local source audit and available isolated checks. The remaining live, hardware, accessibility and signed-update matrix is explicitly unverified, not silently passed. See [REPORT.md](REPORT.md), [FINDINGS.md](FINDINGS.md) and [SCENARIOS.md](SCENARIOS.md).

Private raw evidence is outside Git. No provider credentials, real session content, tokens, signing keys or personal settings are included.

## Navigation continuation

- [x] Replace MainActor Terminal automation with an owned, cancellable helper and shared ten-second budget.
- [x] Make IDE socket budgets monotonic, validate setup, propagate cancellation and close connections safely.
- [x] Keep cancelled panel requests silent and release pending rows; prevent resumed client launches after cancellation.
- [x] Add nine behavior tests covering real inert scripts/processes, sockets and panel state.
- [x] Complete fresh full check: 732 Swift passed, 59 skipped; 108 Python and 8 Node passed; unsigned app/widget and provenance passed.
- [x] Complete focused TSan run: 49 passed, 3 live-integration skips, no TSan reports.
- [x] Preserve initial audit evidence and record the follow-up separately in [NAVIGATION.md](NAVIGATION.md).
- [ ] Signed-app Terminal/iTerm2 permissions and actual focus; new live editor/version matrix (not performed in this local continuation).

## Expanded fault and live-integration pass

- [x] Probe filesystem recovery, migration failures/races, clock rollback, socket trickle traffic, asynchronous teardown and cancellation across the companion boundary.
- [x] Reproduce and fix six further groups, F08–F13; add source-supported opened-descriptor hardening H01.
- [x] Add 15 behavior tests: four Swift, eight Node and three Python/SDK cases; retain before/after failure evidence.
- [x] Verify real Apple Terminal navigation and unminimizing with fresh owned inert processes.
- [x] Verify actual VS Code terminal/window selection, ambiguous and closed targets, and the native Lunavect route for both inert fixture providers; repeat after the final cancellation change.
- [x] Verify the actual JetBrains class's shutdown race using its SDK; keep live UI/version coverage explicitly separate.
- [x] Run the real read-only system sleep-setting probe; leave settings unchanged.
- [x] Rebuild both local companion installers as 0.1.1 and verify packaged source hashes.
- [x] Final full check `run.toF9OKm8`: 736 Swift passed / 59 skipped; 110 Python passed / one SDK skip; 16 Node passed; built intent test, unsigned universal app/widget/helpers and provenance passed.
- [x] Final scoped TSan run: 43 passed, zero skipped, no TSan reports; later edits did not change the instrumented Swift implementation.
- [x] Check fixture cleanup and all 282 recorded implementation/test/config/resource hashes; preserve earlier verification snapshots.
- [ ] Signed-app permissions, authenticated provider panels, live JetBrains UI/version matrix, real update/widgets, accessibility and hardware matrix remain outside this completed local pass.

Evidence and exact boundaries: [EXPANDED.md](EXPANDED.md), [expanded-verification.json](expanded-verification.json).
