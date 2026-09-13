# Measuring local session tracking in Lunavect

Lunavect presents sessions, recovered work intervals and expiring usage allowances from local Claude Code and Codex clients. Observations can be incomplete, delayed or unavailable. The interface must retain real active/waiting states, distinguish unknown values from zero and let users inspect recovered activity without inventing missing work.

The September 12, 2026 infrastructure work made these contracts easier to check: a repeatable production-code workload imported 65,536 synthetic records in a median 0.573 seconds, an isolated RU/DE render matrix produced 12 inspected images, and a separate read-only sampler made process cost measurable during operator-recorded scenarios. The measurements below form an initial baseline; the next comparison can repeat the same inputs and preserve source/toolchain evidence.

## Synthetic workload and results

The optimized `large` workload generated 256 JSONL files containing 65,536 fictional task-completion records, totaling 10,015,898 logical bytes. The production importer recovered all 65,536 intervals without reporting a truncated import. History retained 50,000 intervals according to its existing bound; the encoded history was 3,350,087 bytes. The test separately arranged 5,000 fictional sessions with 20 pinned entries. History encode/decode/summary and arrangement each repeated 20 times per sample.

Three fresh XCTest processes ran on arm64 macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3. Build and XCTest startup were outside phase timers. Each process generated its own archive; filesystem caches and background host load were not controlled.

| Phase | Wall median | Wall min–max | CPU median | Maximum cumulative process RSS |
| --- | ---: | ---: | ---: | ---: |
| Generate synthetic archive | 0.246799 s | 0.246428–0.267763 s | 0.241231 s | 312.95 MiB |
| Import archive once | 0.572868 s | 0.561263–0.583866 s | 0.572281 s | 370.19 MiB |
| Merge, then 20 history round trips and summaries | 4.089583 s | 4.059419–4.092478 s | 4.081947 s | 430.61 MiB |
| Arrange 5,000 sessions 20 times | 0.131989 s | 0.128631–0.133457 s | 0.131983 s | 433.41 MiB |

RSS is the maximum process high-water mark observed across the three samples at each phase end. It includes XCTest, loaded libraries, fixture creation and earlier phases; it cannot be subtracted to claim the memory cost of a single operation. All recorded OS I/O block deltas were zero. Fresh files still contain the logical bytes listed above: cached counters are not evidence of zero disk cost.

The [complete samples](measurements/2026-09-12-synthetic-baseline/performance-report.json), [source/toolchain manifest](measurements/2026-09-12-synthetic-baseline/build-manifest.json) and [run status](measurements/2026-09-12-synthetic-baseline/run-summary.json) are retained as synthetic, non-account evidence. The measurement report SHA-256 is `57971ae186b44c76c84d6b2d0389e0dddddbbab42d686058ee91d9b3c0df30ca`. Source was based on `6c3ec8ba98948dcbf2f5de96b4af6f9d5697f518` with stable, recorded uncommitted benchmark changes, content fingerprint `875251e2e8929b7d098d2d9bfd7c7f3c9f85ce6afdddbf5a63b54fc6a7c3ac1f`. Both source checkpoints matched. It is not a measurement of the subsequently integrated application or the public 0.1.0 binary.

These measurements make a concrete comparison possible after implementation changes. They do not establish a speedup, regression budget, worst-case real archive cost, main-thread responsiveness or prolonged energy use. [Repeat the same protocol](development.md#synthetic-performance-measurements) on the compared revisions and keep the environment and workload aligned before drawing those conclusions.

## Isolating visual evidence

Legacy store-based exporters now obtain their dependencies from `AppEnvironment.preview`, with owned defaults, temporary storage and inert external services. This keeps fixture construction independent of real histories, preferences, client services and notification machinery. Language is supplied to a Debug process instead of mutating `L10n.defaults`. A guard requires proven sandbox execution before view evaluation.

The expanded `legacy-values` suite generated 12 native 2× PNGs in RU/DE: stale/fresh allowances, import reports at two widths, the selected contour in light/dark and the control glyph alphabet. All 12 were visually inspected for clipping and missing content on this host. A repeated run had identical PNG hashes. Preview environment construction and stop also passed inside the same sandbox. Nine synthetic probes verified denied file/preference access and writes, child processes, network and preferences-daemon access. This proves the declared fixture scope on this host, not every dependency reachable from the whole application.

Whole Settings, release screenshots, onboarding and session-window exporters remain guarded and excluded from the launcher. Their migration compiles, but native window/control rendering needs its own isolated evidence. No public screenshot or approved Tide artwork was replaced by this work. The [render protocol](checks-and-release-gates.md#native-comparison-review) keeps visual approval separate from file export success.

## What requires the installed app or another Mac

The process sampler records CPU, sampled RSS/footprint, OS disk bytes and wakeups for an explicit executable/PID. It rechecks identity for every sample and rejects reuse or incomplete intervals. It does not start tasks, change settings, collect arguments or combine helper-process cost. An operator must separately record the build, panel state, upstream task count and whether the displayed sessions match it.

No installed-app measurement is used as a comparative result in this baseline. A useful next set consists of comparable idle/panel-closed, active/panel-open, sleep/wake and synthetic large-archive intervals on the final integrated build. Sustained battery measurement, real WidgetKit placement/refresh, VoiceOver and clean installation on another Mac remain separate checks. Intel binary slices are build evidence, not Intel hardware validation. The [compatibility matrix](verification.md#source-audit-compatibility-matrix) records those gaps explicitly.

The same distinction applies to distribution and artwork: a source manifest identifies inputs and outputs, but cannot grant third-party animation rights or replace signing, notarization and clean-install verification. Those requirements remain in the [release gates](checks-and-release-gates.md#remaining-release-gates).
