# Developing Lunavect

Lunavect is a native macOS app for Claude Code and Codex sessions, usage limits and activity, with a WidgetKit extension. It requires macOS 14 or later.

See [Contributing](../CONTRIBUTING.md) for proposing changes and submitting a pull request.

## Requirements

- A full Xcode installation, selected with `xcode-select`.
- A compatible Swift toolchain. The release source was checked with Xcode 26.6 and Swift 6.3.3.
- XcodeGen is optional for regenerating the project. CI builds the committed Xcode project.
- Node.js is only needed to re-export the app icon; exported resources are included.

## Source map

| Path | Purpose |
| --- | --- |
| `Sources/Weekleft/` | SwiftUI interface, session panel, settings and shared widget views |
| `Sources/WeekleftCore/` | Local client integrations, session lifecycle, usage and activity data |
| `Sources/LunavectHook/` | Lightweight local event helper |
| `Sources/AwakeService/`, `Sources/LunavectAwakeHelper/` | Optional keep-awake service |
| `Widget/` | WidgetKit extension |
| `Tests/` | Core, UI, helper, migration and widget compatibility checks |
| `Config/` | Build, signing and update configuration |
| `design/selected/` | Selected icon source, export and build metadata |
| `scripts/` | Build, verification and distribution tools |

Public branding is Lunavect. Compatibility-facing targets and identifiers retain Weekleft names. Keep `project.yml` and `Weekleft.xcodeproj` in sync when changing targets or build structure. Changing bundle IDs, App Groups or data paths requires a migration.

`design/selected/selection.json` identifies the approved artwork. App and widget
declare `LunavectTide.icns` through `CFBundleIconFile`; packaging reads that key
instead of assuming an icon filename. Build, distribution and installation checks
compare their icons, translations, version numbers and App Group. A per-bundle allowlist checks provider PDFs, animation/sound formats and intent localizations; app-only artwork/animations/audio are excluded from the widget. Source checks hash every packaged source resource, including interface marks.
New builds also compare those resources against the current source. These checks cannot certify
that macOS has refreshed every cached gallery icon.

## Temporary build registration cleanup

Remove temporary app/extension registrations before the final installed-host registration. Unregistering a copy with the same bundle identifier, or restarting the extension, can leave desktop widgets showing placeholders even while timeline generation succeeds. `distribute.sh` restores the validated installed host and embedded extension after cleanup. `install.sh` also retires the previous installed copy (`pluginkit -r`, `lsregister -u`) before registering the new host last. The installed app re-confirms its own registration 5 and 30 seconds after every launch without restarting the extension, so relaunching Lunavect repairs a lost lookup. For manual export/install work, finish all temporary-copy cleanup before launching the installed app. If further cleanup is necessary, re-register the installed host with `lsregister -f` and then its embedded extension with `pluginkit -a`. A successful extension timeline alone is not proof of desktop rendering: verify the existing widgets, and distinguish renderer `LIVE` from placeholder or bundle-lookup failures. Do not clear widget placement/preferences or restart global widget services as a routine cleanup step.

## Build and test

From the repository root:

```sh
./scripts/check.sh
```

This runs Swift and Python tests, widget background compatibility checks, and a universal Release build of the app, helpers and widget without a signing account. Every invocation creates its own temporary Xcode directory, including simultaneous runs from the same checkout. `WEEKLEFT_CHECK_DERIVED_DATA` selects a **parent directory**; it is no longer an exact DerivedData path to reuse. The check removes only its newly created child after success or failure. It neither inspects nor unregisters installed apps.

Results persist in a new directory under `build/check-results/`; `WEEKLEFT_CHECK_RESULTS` can select another parent. Each run contains `check-results.json`, `check-summary.md` and `build-manifest.json`. Local stage logs help diagnose failures; they are not uploaded as CI artifacts. Do not edit or stage source files during a check: provenance compares the source content and Git index before and after the build, and fails if either changed. Existing stable uncommitted changes are recorded as dirty.

For focused changes, run the relevant suite:

```sh
swift test --jobs 2 --filter SessionDragSnapshotTests
python3 -B -m unittest discover -s Tests/Scripts
```

`check.sh` strips inherited `LUNAVECT_*` variables from its child commands so a reused shell cannot accidentally enable native exporters, local-history reads, session navigation or live integrations. Direct `swift test` commands still honor their opt-in variables. XCTest skips are counted separately; a successful unsigned build does not prove live client integration or desktop WidgetKit behavior. See [check scopes and release gates](checks-and-release-gates.md) and [recorded verification](verification.md).

GitHub Actions verifies XcodeGen 2.46.0 project/scheme parity in a temporary copy, then runs `scripts/check.sh` on pushes to `main`, pull requests and manual dispatch, with read-only repository access and no signing secrets. Its summary and artifacts preserve passed, skipped, failed and not-run stages, even if a later stage fails. It selects `macos-26` and `/Applications/Xcode_26.6.app`, with a checksum-pinned XcodeGen download. Only superseded pull-request runs are cancelled; each main push has its own concurrency group. These pins require deliberate updates when GitHub retires a toolchain. The hosted image itself can still change. It runs on one macOS runner; this is not a supported-OS or Intel-hardware certification.

## Isolated native render checks

The small routine render matrix uses production limits cards and the activity detail chart with fictional values, a fixed clock and RU/DE in light/dark appearance. It includes current, unavailable and stale limits, plus the selected activity contour with gaps and an incomplete current hour. It does not construct application/session stores or open visible windows.

```sh
# Writes a not-run report without building or rendering.
python3 scripts/check-native-renders.py --output build/render-plan

# Fails if sandbox isolation cannot be established or rendering cannot complete.
python3 scripts/check-native-renders.py --run --require-render --output build/render-check
```

Use a new output directory for every run. The launcher builds only test products with two Swift jobs, proves its sandbox with synthetic file/process/network/preferences probes, then runs only the explicitly allowlisted methods for the selected suite. The default `smoke` suite runs `NativeRenderSmokeTests`. It never falls back to an unsandboxed renderer. Language is supplied through the existing Debug preview environment instead of writing shared defaults. Open `gallery.html` and inspect every image; `render-report.json` records file hashes, dimensions and the remaining visual-review scope. Image export success alone is not approval of the layout.

Pass `--baseline /path/to/previous/render-output` to compare with a reviewed run. Keep macOS, Xcode, architecture and fixture settings aligned when assessing differences: platform font/raster changes can also change images. A comparison is review evidence, not permission to replace a baseline automatically. In GitHub Actions, select the optional `native_render` input on manual dispatch. The separate job uploads only the synthetic PNGs, gallery, structured report, summary and source manifest; it does not publish a release or README assets.

The additional `legacy-values` suite runs four migrated value-view exporters and an isolated preview-composition check in separate RU/DE processes:

```sh
python3 scripts/check-native-renders.py --run --require-render \
  --suite legacy-values --output build/render-legacy-values
```

Its 12 images cover stale/fresh allowances, import reports at 340/580 points, light/dark contour gaps and the control icon alphabet. The icon captions are internal glyph names and intentionally identical across languages. Every selected XCTest invocation must report exactly one passed test with no skips, in addition to the exact image set. A successful empty filter cannot satisfy the check. Preview composition uses `AppEnvironment.preview`, private defaults and temporary files; its construction and stop are checked inside the same sandbox.

The reviewed `public-gallery` suite captures eleven current production layouts in English, using a single fictional dataset and offscreen AppKit windows at native 2× resolution:

```sh
python3 scripts/check-native-renders.py --run --require-render \
  --suite public-gallery --output build/public-gallery
```

Its settings, sessions and native menu-bar controls use injected preview dependencies under the same sandbox; no windows are shown. See [gallery reproduction](public-screenshots.md) for the image set and capture-time fixture.

Other legacy exporters require sandbox proof and process-only language before evaluating views. Their guard alone does not permit a new method: only the methods selected by the launcher are allowlisted. Other Settings, onboarding and session-window exporters remain excluded. Do not set proof variables by hand or remove the guard. Shared preferences, client processes and network access remain denied.

## Synthetic performance measurements

```sh
# Report the unperformed check without building.
python3 scripts/measure-performance.py --output build/performance-plan

# Optimized production-code workload, three independent XCTest processes.
python3 scripts/measure-performance.py --run --profile large \
  --configuration release --samples 3 --output build/performance-large
```

The runner creates only synthetic JSONL archives in a private temporary directory. It calls the production archive importer, history merge/serialization/summary and session arrangement directly. No default history directories, application stores or client accounts are used. `large` means 256 files × 256 timing records, 5,000 sessions and 20 repeated history/arrangement operations. `quick` uses 16 × 32 records, 250 sessions and four repetitions. Fixture generation is a separate measured phase; builds and XCTest startup are outside the phase timers. Release test products explicitly enable testability and use two Swift jobs.

`performance-report.json` contains exact workload sizes, per-sample wall/CPU time, OS I/O block counters and process high-water RSS; `summary.md` shows medians/ranges. RSS includes earlier phases and XCTest, so it is not a phase allocation delta. Cached I/O can report zero blocks. The source manifest covers the measurement report; `run-summary.json` separately combines measurement and provenance status without changing the already-hashed report. A failed provenance result makes the command fail even if the workload completed. Use a new output directory and keep source/index fixed while it runs. Local logs are excluded from the optional `synthetic_performance` GitHub Actions artifacts. This job has been configured; a local run does not prove the remote runner has passed.

For comparisons, keep profile, configuration, toolchain, host, power state and background load comparable, retain all samples, and repeat the same protocol before and after a change. Keep run reports outside the source tree; publish conclusions only with their measurement scope.

## Read-only installed-process sampling

The separate sampler requires an operator-supplied executable path **and** PID; it never discovers an app by name or starts a workload:

```sh
python3 scripts/sample-process.py \
  --executable /absolute/path/to/Lunavect.app/Contents/MacOS/Weekleft \
  --pid 12345 --scenario idle --duration 30 --interval 1 \
  --output /path/to/new-idle-sample.json
```

Replace both identity values with the exact authorized running process. The C helper verifies the executable before and after every `libproc` read; the report rejects PID reuse, counter resets and incomplete intervals. It collects cumulative CPU, disk-byte and wakeup counters, sampled RSS and physical footprint. The JSON records the executable basename/hash and process identity, without arguments, open files, memory contents or account data. Child helpers are not aggregated; brief memory peaks can be missed. A short sample does not establish battery life.

Process reports use schema 2: `libproc` CPU counters are Mach absolute ticks, converted to nanoseconds with the host's recorded `mach_timebase_info` numerator/denominator and checked wide arithmetic. Schema 1 incorrectly labeled raw ticks as nanoseconds and its CPU results must not be used without conversion from the original host timebase. On a 125/3 host the old CPU figure was understated by 41.67 times. The native regression compares a private CPU workload against `getrusage`, including non-unit timebase and overflow boundaries.

Run idle with the panel closed, active with a recorded active/waiting count and panel state, and wake only after an operator-controlled sleep/wake. Use a disposable synthetic profile for large-archive testing. Record the app build, workload count, power state, interval and any mismatch between upstream tasks and visible sessions alongside the report. The tool does not change permissions, install an app, invoke sleep or modify source histories. If a process exits, exact identity fails or counters are unavailable, it writes a failed result rather than silently substituting another process.

## Signed local development

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your own signing team. The local file is ignored by Git.

```sh
./scripts/build.sh
./scripts/install.sh
```

The default configuration is Release. `WEEKLEFT_SIGNING_CONFIG=/absolute/path/to/config.xcconfig ./scripts/build.sh` explicitly selects a reviewed signing configuration for a local candidate. Local candidates may have stable uncommitted changes; use `unsigned-check` or `unspecified` provenance, because `distribution` always requires a clean source tree. The local build number considers both `~/Applications` and `/Applications`, plus previous products. Use `WEEKLEFT_BUILD_CONFIGURATION=Debug` explicitly for debugging. Build products live outside the project. The install script targets `~/Applications/Lunavect.app`, so review it before running if you have an existing installation.

Public distribution uses Developer ID signing and notarization, described in [update packaging](updates.md). For a fork, use your own signing identity, update feed and update key.

## Working on integrations

Lunavect reads data from the official local clients. Authentication remains with those clients. Preserve existing connection choices, third-party event handlers and the meaning of unavailable or stale data.

- [Connections](connections.md): setup, local changes, diagnostics and removal.
- [Sessions](sessions.md): states, event sources and session actions.
- [Activity](activity.md): observed and recovered work, gaps and local storage.
- [Localization](localization.md): interface languages and translation catalog.
- [Updates](updates.md): signed downloads, packaging and release checks.

Diagnostic output from `--session-probe` contains session titles and project paths. Keep it private. Never commit account snapshots, personal histories, credentials, signing material or local development instructions.

## README screenshots

Use the reviewed `public-gallery` suite above and follow the [screenshot instructions](public-screenshots.md). Inspect every native image and retain its source manifest before replacing README assets. These exports document the interface and do not prove desktop widget placement or live account behavior.

## Releases

Publish the DMG, signed update ZIP, signed appcast and checksums together after the [release gates](checks-and-release-gates.md#remaining-release-gates) are satisfied. Verify the files downloaded from GitHub, then update the README's direct DMG links to that exact release. See [distribution commands](updates.md) and [the recorded compatibility matrix](verification.md).

`scripts/build-manifest.py` records commit/dirty state, source content/index fingerprints, parsed toolchain versions, actual app version/build and SHA-256 artifact hashes. `check.sh` records it automatically before deleting its unsigned product. For a future distribution, use `begin --kind distribution --require-clean` before building and `finalize` on the exact app and packaged files; see the [manifest commands and limits](checks-and-release-gates.md#build-provenance). This does not change the signing workflow or establish byte-for-byte reproducibility.

Original code is [MIT licensed](../LICENSE). Keep third-party attribution and permission status in [NOTICE](../NOTICE) and the resource provenance document.
