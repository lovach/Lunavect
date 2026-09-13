# Verification and compatibility

Lunavect 0.1.0 (103) is the first public release. This page separates recorded release checks from areas that still need testing.

[Download and release notes](https://github.com/lovach/Lunavect/releases/tag/v0.1.0) · [GitHub Actions](https://github.com/lovach/Lunavect/actions)

## Release checks recorded on September 12, 2026

| Area | Result |
| --- | --- |
| Clean source build | Universal Release app, WidgetKit extension and helpers built without a signing account. |
| Automated checks | 268 Swift tests: 238 passed, 30 opt-in checks skipped. Five Python migration tests passed. |
| GitHub CI | The [release commit's workflow](https://github.com/lovach/Lunavect/actions/runs/34684363308) passed. |
| Distribution | Developer ID signature, Apple notarization ticket, App Groups and arm64/x86_64 slices checked. |
| Public download | DMG, update ZIP, appcast and checksums downloaded from GitHub; SHA-256 matched. The app from the downloaded DMG passed codesign, Gatekeeper and stapler checks. |
| Update signatures | Downloaded ZIP signature matched the app's public key. A modified archive was rejected in the local verification check. |
| Existing installation | Settings, language, activity history, hidden sessions and connections survived replacement with the released app. Fresh events and quotas arrived. |
| Session panel | Opening the installed panel and its action menu checked. The installed app reported the current version. |

These are records of the 0.1.0 release checks, not a claim that every check is rerun for each documentation change.

## Branded installer, revision 2

The refreshed DMG contains the same signed and notarized app, version 0.1.0 (103). It does not announce an app update through Sparkle.

- The actual Finder window was inspected after opening and after ejecting/reopening the image: large app and Applications icons, a transfer arrow, and a cyan/amber background. [Installer screenshot](images/installer.jpg).
- Finder metadata, window dimensions, icon positions, the 1×/2× background and the `/Applications` link were checked. All app files and symlinks matched the notarized source; the selected app icon was unchanged.
- The DMG and `SHA256SUMS-installer-2.txt` were downloaded from GitHub without authentication. SHA-256 matched: `e23e4eb272b6aadbefdbc9cdcced23720d9cd82c421bd06871497d3a8df1baf2`. The downloaded image passed integrity, strict codesign, Gatekeeper, stapler and saved-layout checks.
- The original DMG, ZIP, appcast and checksum assets were preserved at their existing URLs and their server-side digests remained unchanged. This packaging check is not a new app-installation test or a desktop-widget test on another Mac.

## Homebrew installation

On September 12, 2026, the `Casks/lunavect.rb` package passed Homebrew style validation and installed the public 0.1.0 (103) DMG into an isolated Applications directory. Homebrew verified the declared SHA-256; the installed app passed strict codesign, Gatekeeper and stapler validation. Uninstall removed the isolated app. The existing development installation was preserved. The upgrade command correctly reported that 0.1.0 was already current; this does not test an upgrade between two different releases.

## Development checks on September 13, 2026

The integrated development source passed a new full local check on macOS 26.5.2 (Apple silicon): 568 Swift tests passed, 56 optional tests were skipped, and 77 Python tests passed. The universal unsigned Release app, widget and helpers, product resources, built intent metadata and source/build provenance checks passed. These results are separate from the published 0.1.0 release above.

The widget material probe checked three widget kinds across three archive cycles, reading each archive with the extension-local hooks disabled to represent the system host. It verified native material, the disabled path, an incompatible-runtime fallback and an unrelated descriptor remaining unchanged. This checks the current runtime contract; it does not establish visible desktop blur on every supported macOS version.

The revised widgets were exported as 51 native images across English, Russian and German. Representative summary, selected-day, single-provider and unavailable states were visually inspected, including the formerly truncated duration values. The combined overview reserves more space for the graph with compact quotas and a denser scale. The two limits-only layouts were retained, with manual subscription dates removed from widget faces. These images use fictional data.

Development build 141 passed local signature, resource, helper and App Group validation and was installed. All 38 captured app preferences, shared widget preferences and six persisted data files matched immediately before and after replacement. After launch, real Claude and Codex tasks appeared in the session panel. Regression checks establish that a Claude startup-only event remains absent even after a newer idle catalog poll, while actual work restores the row. The owner confirmed the desktop glass background works on this Mac; a reported return to black was the saved 0% transparency setting, and was subsequently confirmed as normal. This is not a cross-version or accessibility-mode certification. The final compact overview and removal of subscription dates passed native-render checks and were installed in development build 142, again preserving all 38 preferences and six persisted files. Detailed Y-axis checks cover readable hour increments, shared grid/label positions and minimum label spacing without extending the data range. Compact graphs always retain an intermediate Y-axis label, including below the old height threshold. A further native layout check reduced the header and duration block, giving the medium graph nearly twice its previous vertical plotting space; summary and selection states were inspected in English, Russian and German. This layout was installed in development build 145; all 38 app preferences, shared widget preferences and six persisted data files matched before and after replacement.

## What still needs testing

| Area | Current limit |
| --- | --- |
| Other Macs | The release was exercised on an Apple silicon Mac. Intel code is included, but Intel hardware and all supported macOS versions have not been verified. |
| First-time setup | Initial connection on a clean Mac, different account plans, client versions, failed sign-in and retry need broader coverage. |
| Session lifecycle | More real-client coverage is needed for long-running tasks, cancellation, sleep/wake, offline periods and returning to the exact original session. |
| Desktop widgets | Native layouts have been rendered and inspected. Placement and refresh of this release on the real desktop remain unverified. WidgetKit schedules refreshes. |
| Automatic updates | Installation between two distinct public versions, including offline/retry behavior, remains unverified. |
| Battery use | Short process samples do not establish battery consumption during prolonged idle use. |
| Experimental features | Optional widget transparency and closed-lid keep-awake behavior are not guaranteed across Macs or future macOS releases. Transparency is off by default. |

Missing or expired allowances are shown as unavailable, never interpreted as unlimited usage. Activity only counts observed or explicitly recovered intervals; gaps are not invented work.

## Public screenshots

The current README gallery was rendered and visually checked on September 12, 2026 using the opt-in native renderer. Its new overview, session and widget images have a transparent outer canvas and native 2× resolution. Light and dark session panels are exported separately; the full activity view includes the project breakdown. These are presentation checks with fictional data, not new live-client or desktop WidgetKit verification.

The README gallery includes a retouched macOS capture from a local development build. Private session names, paths and usage values were replaced with samples, a desktop shortcut was removed, and framing was adjusted. It is labeled as a development preview because menu-bar usage indicators are not in the 0.1.0 installer. This edited asset is not additional live-interface or WidgetKit verification.

The README uses native SwiftUI renders with fictional sessions, allowances and activity. The opt-in `ReleaseScreenshots.testRenderPublicScreenshots` renderer passed on September 12, 2026, and the resulting light/dark panels and widget layouts were visually inspected. The 18-second video renders native views in a separate media app with fictional state transitions. It does not establish live provider behavior, returning to an external session or desktop WidgetKit placement. Stills and video share one fixture: current-day work is retained, provider/project totals include overlapping sessions consistently, and unrelated session timers survive demo transitions. Regression checks cover these cases. See the [media source notes](../scripts/presentation/README.md).

## Source audit compatibility matrix

The source declares macOS 14 as its deployment minimum. The following records the September 12 source-audit environment separately from the historical 0.1.0 release checks above. A deployment target expresses intent, not proof of runtime behavior on every supported version.

| OS / architecture | Source build/test evidence | Runtime evidence and remaining limit |
| --- | --- | --- |
| macOS 26.5.2 / arm64 | Focused Swift fixtures, Python orchestration regressions, optimized synthetic archive/session measurements and 12 expanded legacy native renders passed locally with source manifests. The earlier integrated audit check recorded 401 Swift cases (356 passed, 45 opt-in skipped) and 45 Python passes. | Native value-view images were inspected. These counts belong to their recorded revision; the final combined source needs a new full check. The new synthetic measurements do not establish installed behavior or battery use. |
| macOS 14 / arm64 | Declared minimum; not run on this OS during the audit. | Clean setup, native layouts, client lifecycle and widget refresh remain not-run. |
| macOS 15 / arm64 | Not run on this OS during the audit. | Same runtime checks remain not-run. |
| Other supported macOS revisions / arm64 | Not run during the audit. | No cross-version certification inferred from the current SDK. |
| macOS 14+ / x86_64 | Universal slices were checked in the earlier unsigned build. | Intel hardware runtime tests remain not-run. Cross-compilation is not an Intel test. |
| GitHub macOS runner | Workflow configured for unsigned checks and optional synthetic render/performance jobs. | The new optional jobs have not been run remotely as part of this record. Historical release CI above is separate. |

The [case study](case-study.md) preserves exact synthetic workload numbers and its source/toolchain manifest. Longer idle/active/wake sampling, battery use, VoiceOver, desktop WidgetKit, another-Mac installation and distinct-version upgrades remain open where no actual result is recorded. The legacy exporters' new isolation guard is not a claim that whole-window Settings or session flows were rendered inside the strict sandbox.

## Reporting a problem

[Open an issue](https://github.com/lovach/Lunavect/issues/new/choose) with the app version, macOS version, Mac architecture and reproducible steps. Redact private session titles, paths and credentials from attachments.

For source and checks, see [development](development.md). Third-party resource provenance and permission status remain documented in [NOTICE](../NOTICE) and [IconSources.md](../Sources/Weekleft/Resources/IconSources.md).
