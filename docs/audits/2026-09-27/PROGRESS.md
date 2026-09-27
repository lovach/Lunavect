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
