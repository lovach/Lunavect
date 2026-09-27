# Full local audit — 2026-09-27

Release follow-through: these changes are included in **0.2.4**. See the [release verification record](../../verification.md) for publication, installation and current remaining limits; the evidence below describes the original local audit phases.

The initial expanded local audit found and fixed **seven defect groups** that the baseline tests did not catch. **Fourteen behavior tests** were added: ten covering the reproduced defects and their adjacent boundaries, one existing FIFO behavior, one independent interval oracle, and two real Unix-socket protocol tests. The application design, compatibility identifiers, data locations and telemetry decision are preserved.

The [navigation hardening](NAVIGATION.md) subsequently corrected both recorded transport risks and added nine behavior tests. The latest [expanded scenario pass](EXPANDED.md) reproduced and fixed **six further defect groups**, hardened descriptor reads and added **15 more tests**. Its final full check passes **736 Swift tests (59 skips), 110 Python tests (one SDK skip) and 16 Node tests**. A separate SDK run passes the skipped JetBrains lifecycle case; actual Terminal and VS Code navigation now have fresh inert-fixture evidence.

This is a bounded, evidence-led audit of this checkout, not a guarantee that every possible runtime scenario works. Signed-app Automation permissions, authenticated provider panels and the broader host matrix remain open. See [findings](FINDINGS.md), [scenario matrix](SCENARIOS.md), [initial file coverage](coverage.json), [initial verification](verification.json) and [latest verification metadata](expanded-verification.json).

## Source and repository

- Baseline: `1bba24c35674d9b7f6438c104c7811162991a02a`, main after telemetry removal.
- Audit branch: `codex/full-audit-2026-09-27`, isolated checkout. Changes are local; no new release, push, signed installation or updater cycle is implied.
- The owner's repository now lives in `Documents/Wet Dog inc/DONE/Lunavect`; the former path supplied in the task no longer exists. A distinct Developer checkout was not substituted.
- The untracked `Lunavect 2.xcodeproj` in the owner's checkout was preserved. Its project file is older and omits recent IDE integrations; audited scripts use the canonical project.
- 286 source/config/test/script/document files were initially inventoried. The coverage ledger distinguishes boundary review, focused inspection, automated checks and inventory-only documentation. It does not claim a line-by-line review of every test, resource or document. 281 implementation/test/config/resource files are fingerprinted separately from the audit narrative.

## Initial audit verification

| Check | Result |
| --- | --- |
| Baseline full check | 709 Swift passed, 59 skipped; 108 Python passed; 8 Node passed; unsigned Release app/widget built |
| Final full check | **723 Swift passed, 59 skipped, 0 failed** (782 total); **108 Python passed**; **8 Node passed** |
| Built AppIntent resources | 1 additional test passed against the built app/widget |
| Widget private-ABI safety probe and incompatible-descriptor fallback | Passed on macOS 26.6.2 |
| Release app/widget, hook helper and bundled product resources | Passed, unsigned build; source provenance passed |
| Pinned XcodeGen 2.46.0 parity | Canonical project and shared schemes match; checkout not mutated |
| Thread Sanitizer | 48 selected lifecycle/cache/persistence tests passed; no TSan warnings in that run |
| Native smoke / legacy / public gallery | 64 + 12 + 12 isolated PNGs; build, sandbox probes, output validation and provenance passed |
| Extra recovery and long-label fixtures | 18 PNGs; same strict sandbox; input-field rendering limit recorded below |
| New local socket fixtures | Seven IDEBridge tests passed, including two new actual-stream tests |
| Installed app, read-only | 0.2.3 (189); `codesign --verify --deep --strict` and `spctl --assess --type execute` passed |

The 59 skipped tests are listed individually in [skips.json](skips.json). Some were subsequently exercised by separate opt-in render/performance/resource commands; they are not silently subtracted from the original run. This audit ran local checks, not a new GitHub Actions job.

**Native review:** 106 images were generated and checked structurally. Representative images were actually inspected, including expired/mixed freshness, unknown compact German quotas, Russian chart gaps, narrow import details, controls, session panels, settings, partial recovery, long bilingual names and unknown selection. This was representative inspection, not owner approval or a claim that all 106 images were manually examined. The SwiftUI value renderer cannot draw the native Codex path text field; its placeholder is an explicit limitation. Other long-name views use AppKit at 1x; value fixtures use 2x. There was no exact image-baseline comparison.

## Additional scenario exploration

New tests deliberately combine events that isolated happy-path tests missed: clock rollover plus minute-rounded reset; executable changes plus late asynchronous completion; malformed JSON plus Foundation numeric bridging; clock rollback plus continuing helper heartbeat; notification publication plus stale source evidence; corrupt stored counts plus later updates; and oversized/replaced local state plus recovery.

An independent oracle checks 100 generated sets of 25 intervals over 120 sampled seconds each: overlapping providers, known zero, recovered/live provenance, reverse input order and replaying the same events. It passed without requiring an activity-union change. Actual private Unix sockets check framing, two coalesced replies, sender framing, peer shutdown, invalid JSON/UTF-8, oversize replies and a stalled unterminated frame. No IDE or provider account participates in those tests.

## Architecture assessment

The current separation remains useful: `WeekleftCore` handles normalized values and adapters; MainActor stores coordinate state and generation guards; serialized persistence owns file writes; the WidgetKit extension consumes local shared state; a separately authenticated helper owns privileged sleep changes; IDE companions expose narrow local navigation endpoints. Existing dependency seams made controlled cancellation, late-result, I/O and helper tests possible without real accounts or machine power changes.

The audit exposed duplicated freshness decisions between quota presentation and notification generation; F05 now uses the same window rules. Shared readers likewise now use one descriptor-based bounded read. Path-change invalidation extends existing lifecycle generations rather than introducing another refresh subsystem. No large architectural rewrite was justified by the evidence.

Remaining concentration points are the large app/session stores, signed-app automation, and external/local provider formats that can change. MainActor automation and wall-clock transport budgeting were addressed in the [continuation](NAVIGATION.md). These require explicit contract/live checks; merely moving functions into more files would not resolve those risks.

The expanded pass also traced cancellation across the native/companion boundary and shutdown across asynchronous file publication. Both needed end-to-end lifetime handling, not another timeout at the caller. Local metadata caches now distinguish file change time and retry negative results, allowing recovery from transient read failures without abandoning positive caching. See F08–F13 and H01 in [EXPANDED.md](EXPANDED.md).

## Performance

Three optimized synthetic samples on this arm64 Mac, macOS 26.6.2, Swift 6.3.3:

| Workload | Median wall time |
| --- | ---: |
| Import 65,536 records from 256 files (~10 MB logical archive) | 0.581 s |
| Merge, summarize and serialize/decode history, 20 repetitions | 4.868 s |
| Arrange 5,000 sessions, 20 repetitions | 0.215 s |

Largest observed process high-water RSS: **119.41 MiB**. This is cumulative XCTest memory across preceding phases, not app idle memory or a per-phase allocation delta. Build time is excluded. Host load/filesystem caches were not controlled. No battery, UI responsiveness under every workload, or other-hardware conclusion follows from these numbers.

## Privacy and publication boundary

Source/configuration/dependency inspection found no app telemetry integration or automatic diagnostic upload. Session/activity metadata remains local. The GitHub statistics script is a maintainer tool and is not bundled in the product; Sparkle system profiling is disabled in configuration. Existing updater and official-client network behavior stays documented. This is a source/config audit, not packet capture of every dependency or a promise of zero network requests.

No provider credential store, token or keychain item was read. No real session transcript is in these reports or fixtures. The installed app was not replaced. Sign-in, helper approval, sleep settings, actual widget placement, publication and a complete signed update were not performed.

## Remaining validation before a release claim

1. Verify the new helper's Automation attribution, first consent, denial and revocation in the signed app. Correct Apple Terminal tab/window focus and unminimizing were freshly verified under the native test host; this does not prove the shipping app's permission identity.
2. Exercise authenticated provider panels separately from inert terminal fixtures and broaden supported JetBrains builds. Fresh VS Code native navigation, ambiguous targets and closed tabs passed; JetBrains's fresh SDK teardown test is not a rerun of its September 26 live terminal UI evidence.
3. Verify desktop WidgetKit placement/refresh through the intended update and restart cycle; test the signed distribution, helper lifecycle and required macOS/hardware targets.
4. Complete native input/VoiceOver, physical keyboard focus and broader language/contrast/scale checks. Optional screenshot tests that were not run remain listed as such.

An early extra-render attempt rejected incorrect 2x expectations for the AppKit 1x fixture; the wrapper now declares the actual mixed scale and the fresh run passes. An initial socket fixture blocked its own oversized writer; its sampled stack identified the test writer, and the fixture now uses a bounded nonblocking peer buffer. Neither issue was classified as a product failure.

For the initial audit, all application changes and the two final socket tests were followed by full checks. Its native/performance runs used that phase's production code; they do not certify subsequent navigation/cache/companion changes. Final audit prose is written after verification; implementation-file hashes are checked again to distinguish report edits from code changes.

The navigation continuation has its own fresh full-check and TSan evidence in [NAVIGATION.md](NAVIGATION.md) and [navigation-verification.json](navigation-verification.json). Initial render/performance results above were not rerun or relabelled.

The latest expanded pass is recorded in [EXPANDED.md](EXPANDED.md) and [expanded-verification.json](expanded-verification.json): final run `run.toF9OKm8`, 43 focused tests under TSan, fresh Terminal/VS Code tests, SDK-backed JetBrains teardown and 282 unchanged checked input hashes. Only audit documents changed after the final full check. Companion packages are rebuilt as 0.1.1 locally; installed application and companions remain unchanged.
