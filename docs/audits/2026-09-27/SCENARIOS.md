# Scenario matrix — 2026-09-27

“New” means added or deliberately exercised outside the normal baseline in this audit. “Existing” means a pre-existing automated check actually rerun here. Test/fixture success is scoped to the stated boundary, not full product acceptance.

| Area / scenario | Evidence | Result / boundary |
| --- | --- | --- |
| New: reset just across midnight/New Year | ClaudeUsageProbeTests | Reproduced, F01 fixed |
| New: repeated and missing DST hour | ClaudeUsageProbeTests, Vienna 2026 transitions | Reproduced, F01 fixed |
| Existing: leap day, 23/25-hour activity days, week/month edges | ActivityCalendarBoundaryTests, SubscriptionCalendarTests | Passed |
| New: change Codex executable while old request is pending, then change back | AppStoreLifecycleTests | Reproduced, F02 fixed |
| Existing: cancel before request; stop/restart; disconnect during request | AppStoreLifecycleTests, DataLifecycleRegressionTests, SessionStoreLifecycleTests | Passed; selected lifecycle suites also ran under TSan |
| New: boolean quota, fractional duration, malformed reset, valid zero and null reset | UsageParserTests | Reproduced, F03 fixed |
| Existing: stale/unknown/expired, offline retention, single provider | DataFreshnessTests, OfflineRowTests, SingleProviderTests | Passed; native quota fixtures separately inspected |
| New: Keep Awake rollback with continuing heartbeat, then untimed lease | AwakeLeaseTests | Reproduced, F04 fixed; fake power service |
| Existing: helper loss, restore failure, timeout, safety-policy changes | AwakeLeaseTests, KeepAwakeTests, AwakeMaintenanceTests | Passed at protocol/state-machine level |
| New: notification freshness versus UI; stale model; disabled provider | LimitAlertTrackerTests, FailureNoticeTests | Reproduced, F05 fixed |
| Existing: delayed/repeated/background completion and attention notices | SessionContractTests, SessionConvenienceTests, LimitNoticeTests | Passed; no new live Notification Center acceptance |
| New: negative/overflowing background counts and later increment | ClaudeBackgroundWorkTests | Reproduced, F06 fixed |
| New: over-limit shared history/snapshot and exact read boundary | DataStorageGuaranteeTests | Reproduced, F07 fixed; original bytes preserved |
| New: FIFO shared file and valid migration symlink | DataStorageGuaranteeTests | Passed; FIFO already handled by baseline |
| Existing: corrupt JSON salvage; readonly directory; failed replacement; duplicate providers | DataStorageGuaranteeTests, ReleaseRecoveryTests, SessionConvenienceTests | Passed |
| Existing: process dies during temporary write; prune only owned files | DataStorageGuaranteeTests, release/install script tests | Passed in fixtures; no actual power-loss experiment |
| New: interval union against independent per-second oracle | ActivityProvenanceTests | 100 sets x 25 intervals; 12,000 sampled seconds; order/retry invariants passed |
| Existing: live/recovered provenance; unknown versus known zero; future/invalid records | ActivityProvenanceTests, ActivityTests, ActivityImportTests | Passed |
| Existing: huge/truncated archive, partial records, cancellation and retry | ActivityImportTests, CodexActivityCancellationTests | Passed; synthetic only |
| New: large optimized workload, three measured samples | SyntheticPerformanceTests via measure-performance.py | 65,536 records / 256 files, 5,000 sessions; passed |
| Existing: rewritten/truncated/regrown log and metadata-cache invalidation | CodexActivityTests, LocalFileCacheTests | Passed |
| Existing: bounded/cyclic pagination; late errors retain earlier pages; priority IDs | CodexSessionPaginationTests, CodexSessionDiscoveryTests | Passed using scripted transports |
| Existing: subagents/internal memory work excluded; old hooks do not revive tasks | SessionTests, SessionStoreLifecycleTests, SessionContractTests | Passed |
| Existing: hidden/pinned/order persistence; failed save; undo; restart | HiddenSessionRestartTests, HiddenSessionUndoTests, SessionOrganizationTests | Passed |
| Existing: PID reuse, old terminal versus current IDE origin, detached hooks | IDESessionLocationTests, TerminalLocationTests | Passed; origin and identity logic |
| Existing: no guessed fallback client, no second agent from a live terminal row | SessionNavigationIntegrationTests non-opt-in cases | Passed; actual focus methods replaced in these cases |
| Existing: companion callback allowlist, stale descriptor, hostile paths, bounded IDs | IDEBridgeTests; Node protocol/routing tests | Passed |
| New: actual Unix stream, two replies in one stream, outgoing framing, peer exit | IDEBridgeTests real socket fixtures | Passed without opening editors or accessing accounts |
| New: malformed JSON, absent status, invalid UTF-8, oversized frame with/without newline, unfinished response | IDEBridgeTests real socket fixtures | Passed; unfinished response times out |
| Existing: menu geometry, reorder/swipe/click boundaries, focus recovery | SessionGeometryTests, SessionsUXTests, UXRegressionTests | Automated cases passed; native-host omissions stay explicit |
| New: native stale/unknown/current quota layouts, RU/DE, light/dark | isolated smoke suite | 64 PNGs; representative visual inspection |
| New: native legacy values/import report/icons and public layouts | legacy-values and public-gallery suites | 24 PNGs; representative inspection |
| New: partial connect/disconnect, unreadable settings, absent old HUD backup | render-extra.py | 10 recovery PNGs; input-control renderer limitation recorded |
| New: unknown chart selection and very long bilingual project/session labels | render-extra.py | 8 AppKit PNGs; wrapping, truncation and unknown readout inspected |
| Existing: language placeholders and built AppIntent resources | LocalizationTests; built intent resource check | Passed; not a complete visual audit of all six languages |
| Existing: widget unsupported private ABI fallback and other-widget isolation | WidgetBackgroundTests Objective-C probe | Passed on this macOS; not future-OS assurance |
| Existing: install transaction rollback, identity, monotonic release version, signing policy, migration conflicts | Tests/Scripts suite | Passed using fixtures; no new install/update |
| New: source/generated project parity and installed app signature assessment | check-project-parity.py; codesign/spctl read-only | Passed; installed 0.2.3 (189) remains unchanged |
| New: network/telemetry/dependency and companion source inspection | app/IDE sources, Package.swift, plist, privacy docs | No app telemetry integration found; updater/provider traffic remains documented |
| New: concurrency instrumented run | TSan: lifecycle, persistence, LocalFileCache | 48 tests passed; no TSan warnings in this run, not exhaustive interleavings |

## Explicitly unverified live scenarios

- A newly authenticated account in every Claude/Codex host, provider extension panel and remote workspace.
- Actual focus in all VS Code/JetBrains versions, denied/revoked Automation permissions, hundreds of native Terminal tabs, and a hung Terminal target.
- Fresh install, signed update from each older version, helper approval/revocation, reboot, crash/power loss during installation, and real closed-lid battery/thermal transitions.
- Desktop widget placement through host crashes/reboots; not inferred from isolated cards or ABI probes.
- VoiceOver, physical keyboard focus where this XCTest host exposes no key window, all language/contrast/scale combinations, and battery/energy measurements.
- Randomized process scheduling/fuzzing of all parsers. The seeded interval oracle is deterministic bounded exploration, not a whole-app fuzzer.

The normal Swift run's 59 skips are retained verbatim in `skips.json`; `verification.json` records the opt-in cases exercised separately. No skip was relabelled as a pass merely because the suite was green.
