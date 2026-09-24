# Check scopes and remaining release gates

Use a result only for the source revision, environment and scenario it records. Historical release evidence in [verification.md](verification.md) remains historical; new automation does not rerun it implicitly.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| `passed` | The named command or assertion ran and succeeded within its documented scope. |
| `failed` | A command, assertion, required isolation probe or comparison failed. |
| `skipped` | An optional check was reached but intentionally omitted or unsupported; the reason is recorded. |
| `not-run` | No evidence was collected for this check, including later stages after a failure. |
| `running` | Intermediate state only; an interrupted running stage becomes failed when the runner exits normally through cleanup. |

Test skips do not become passes. XCTest reports assertion failures separately from test cases: when a failing log cannot establish passed-case counts, the report leaves that count unknown. A killed process or runner loss can leave an unfinished report; neither an unfinished manifest nor a missing artifact is a pass.

## What each command establishes

| Command | Evidence | Still not established |
| --- | --- | --- |
| `python3 -B -m unittest discover -s Tests/Scripts` | Behavior of migration/resource scripts, isolated check directories, result reporting, provenance and render orchestration using temporary fixtures. | Real Xcode builds where the test substitutes tool boundaries; actual GUI rendering unless explicitly reported separately. |
| `swift test --jobs 2 --filter …` | The selected Swift tests on this host; preserve their skipped count. | Unselected tests, enabled external clients, desktop widgets or signing. |
| `./scripts/check.sh` | Unit tests, isolated runtime fallback probe, unsigned universal Release build and resource/helper checks; source and product manifest. | Native render, live integration, installed widgets, supported OS/hardware matrix, signed release. |
| `python3 scripts/check-native-renders.py --run --require-render --output …` | Sandbox preflight, narrow synthetic native exports, expected image set/dimensions/hashes, source manifest. | Visual approval, complete settings/session flows, VoiceOver, WidgetKit compositor, external clients or installed-app state. |
| `python3 scripts/check-native-renders.py --run --require-render --suite legacy-values --output …` | Same isolation probes, preview composition/stop, four migrated legacy value-view methods and exact 12-image RU/DE matrix. | Settings/session flows or native window controls outside this value-view matrix. |
| `python3 scripts/check-native-renders.py --run --require-render --suite public-gallery --output …` | Same isolation probes, eleven English production layouts using preview dependencies and offscreen native windows; exact image set and source manifest. | Live accounts, interactive window flows, WidgetKit compositing or visual approval. |
| `python3 scripts/measure-performance.py --run --profile large --configuration release --samples 3 --output …` | Synthetic importer/history/session timings, CPU and cumulative RSS/I/O counters; exact workload and source manifest. | Installed-app responsiveness, comparative speedup, real archive distribution, battery consumption. |
| `python3 scripts/sample-process.py --executable … --pid … --scenario idle --output …` | Read-only resource counters for one explicitly identified process during an operator-supplied scenario. | Workload correctness, child-process cost, short unsampled peaks, energy use or authorization to start a scenario. |

The optional private WidgetKit descriptor probe can exit 77 on an unsupported ABI; this is `skipped`. The separate intentionally incompatible/fallback probe still has to pass. Experimental transparency remains off by default.

The check runner creates a unique child below `WEEKLEFT_CHECK_DERIVED_DATA` (or its temporary default parent), even when two checkouts pass the same parent. Cleanup removes that child only. Persistent reports also have unique children. Raw local logs may include source paths and should be reviewed before sharing; CI uploads only an explicit allowlist of reports, manifests and synthetic images. Current [artifact action options](https://github.com/actions/upload-artifact#usage) are pinned by commit in the workflow.

## Native comparison review

The current 64-image smoke matrix covers RU and DE, light and dark, current limits, unavailable limits, stale Claude with expired five-hour allowance next to fresh Codex, and the application's selected activity chart with a gap and a partial current hour. The fixture uses fixed dates and in-memory values. It deliberately does not exercise a whole SettingsView or sessions store.

Open the gallery at full size. Check long labels, clipped text, provider/state distinctions, unknown versus zero, stale/expired treatment and the activity contour. Record the reviewed source commit, manifest and platform before accepting a reference run. With `--baseline`, inspect each changed pair and explain whether it is an intended layout change, a defect or platform rendering variation. Do not replace reviewed references merely to make a comparison pass. There is no approved cross-platform pixel baseline committed in this foundation.

The additional `legacy-values` matrix covers import reports at two widths, stale/fresh allowances, contour gaps and the icon alphabet (12 PNGs). It also constructs/stops the injected preview composition under the same deny-default sandbox. Each invocation must execute exactly one test without skips. The separate `public-gallery` suite now covers eleven reviewed offscreen settings, sessions, menu-bar and widget layouts. Other migrated legacy tests remain excluded; an isolation guard by itself does not allowlist their rendering.

The launcher is fail-closed: isolation must be proven before any native export. An unavailable sandbox capability is not a reason to run the renderer with normal user access. The opt-in CI job requires rendering, so a skipped render cannot produce a green render gate. The default build job leaves native render and performance explicitly not-run. Manual dispatch can run the smoke and legacy-value suites independently; the public gallery uses the local command above. It can also run a separate synthetic performance job. There are no timing pass/fail budgets yet: comparable baseline evidence is needed before setting a regression threshold.

## Build provenance

The normal unsigned check writes its manifest automatically. To describe a future distribution, choose an empty output location outside the source checkout or under an ignored build directory, then record the source **before** building:

```sh
python3 scripts/build-manifest.py begin \
  --source-root "$PWD" \
  --output /path/to/release-evidence/build-manifest.json \
  --kind distribution --require-clean

# Run the separately authorized build, signing, notarization and packaging steps.

python3 scripts/build-manifest.py finalize \
  --source-root "$PWD" \
  --manifest /path/to/release-evidence/build-manifest.json \
  --app /path/to/export/Lunavect.app \
  --artifact installer=/path/to/Lunavect.dmg \
  --artifact update=/path/to/Lunavect.zip \
  --artifact appcast=/path/to/appcast.xml
```

Replace these paths with the exact reviewed output paths. This command records evidence; it neither signs nor uploads. `build-manifest.py verify --manifest … --app … [--kind … --version … --build …]` accepts only a `complete` manifest whose recorded app hash still matches; `distribute.sh submit` and `export` run it on the archived app. A missing artifact fails. The finalizer reads version/build from the actual app Info.plist, hashes files with SHA-256 and records directory entries using the aggregate hash method named in the manifest. Symlinks are hashed without reading their targets. The manifest cannot be contained in a directory it hashes, since that would create an invalid self-reference.

The source record contains commit, dirty flag, content/index/status fingerprints and a file count; it does not publish source filenames, diffs, Git remote URLs, environment values, account data or raw toolchain diagnostics. Ignored files, including local signing configuration and credentials, are excluded. Do not explicitly select private files as artifacts. Signing/notarization settings, environment and dependency caches are outside this fingerprint's scope.

Source and Git index are observed at begin/finalize; either changing causes a failing `source-changed` result with both observations retained. The tool does not lock or copy the source and cannot detect edits reverted between the checkpoints. Keep a fixed checkout during a release. Stable dirty checkouts are supported for development and clearly labeled; `--require-clean` rejects them for the procedure above; `--kind distribution` enforces that requirement even when the flag is omitted. Archive and package-update also require an explicitly supplied published appcast and strictly higher build and marketing versions; archive requires full Git history and rejects an existing local version tag before Xcode starts. Refresh tags and the appcast first, because these offline gates cannot establish the freshness of the operator-supplied baseline. Hashes identify observed outputs and do not promise reproducible bytes across rebuilds, toolchains or signing runs.

## Remaining release gates

These are open requirements for the next distribution, not conclusions inferred from an unsigned CI pass:

| Gate | Required evidence |
| --- | --- |
| Fixed source and media | Clean reviewed commit, exact product version/build, completed app/package manifests, reviewed screenshots tied to their own source revision. |
| Third-party animation rights | Resolve permission or an applicable license for the exact Clawd and Codex companion animation assets, or use independently created replacements approved by the owner. [NOTICE](https://github.com/lovach/Lunavect/blob/main/NOTICE) and [IconSources.md](https://github.com/lovach/Lunavect/blob/main/Sources/Weekleft/Resources/IconSources.md) currently say permission has not been established. Provenance is not permission; this is an unresolved documented question, not a legal finding. Existing assets are retained. |
| Distribution chain | Developer ID signature, notarization/stapling, App Groups and exact packaged hashes checked; anonymous download of those files validated. The manifest alone proves none of these. |
| Install and upgrade | Clean install on another Mac, upgrade between two distinct public versions preserving preferences/history/connections, retry/offline and removal behavior. Reinstalling the same version does not prove upgrade. |
| Supported macOS/hardware | Actual tests on supported OS versions and Intel hardware as applicable. Universal binary slices and one current CI runner do not establish runtime compatibility. |
| Real clients and permissions | Authorized first setup, partial failure/retry, running/waiting/ready/cancelled states, exact session destination, truthful missing/stale limits, sleep/wake and offline recovery. Synthetic renders do not access accounts or grant permissions. |
| Desktop WidgetKit and accessibility | Actual widget placement/editing/refresh, current icon/gallery state, relevant VoiceOver and keyboard flows. Native card exports do not run the WidgetKit host. |
| Experimental features and load | Keep standard widget background as the supported fallback; separately record supported transparency behavior, closed-lid conditions and sustained idle/active/wake measurements where claimed. |

A release record must state which of these scenarios actually ran. The current evidence and remaining limits are in [verification](verification.md).
