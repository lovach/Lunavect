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

The opening README image is a retouched macOS capture from a local development build. Private session names, paths and usage values were replaced with samples, a desktop shortcut was removed, and framing was adjusted. It is labeled as a development preview because menu-bar usage indicators are not in the 0.1.0 installer. This edited asset is not additional live-interface or WidgetKit verification.

The README uses native SwiftUI renders with fictional sessions, allowances and activity. The opt-in `ReleaseScreenshots.testRenderPublicScreenshots` renderer passed on September 12, 2026, and the resulting light/dark panels and widget layouts were visually inspected. The 18-second video renders native views in a separate media app with fictional state transitions. It does not establish live provider behavior, returning to an external session or desktop WidgetKit placement. Stills and video share one fixture: current-day work is retained, provider/project totals include overlapping sessions consistently, and unrelated session timers survive demo transitions. Regression checks cover these cases. See the [media source notes](../scripts/presentation/README.md).

## Reporting a problem

[Open an issue](https://github.com/lovach/Lunavect/issues/new/choose) with the app version, macOS version, Mac architecture and reproducible steps. Redact private session titles, paths and credentials from attachments.

For source and checks, see [development](development.md). Third-party resource provenance and permission status remain documented in [NOTICE](../NOTICE) and [IconSources.md](../Sources/Weekleft/Resources/IconSources.md).
