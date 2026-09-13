# Verification and compatibility

The current public release is **Lunavect 0.1.1 (147)**. These records distinguish checks that ran from scenarios still requiring verification.

[Download and release notes](https://github.com/lovach/Lunavect/releases/tag/v0.1.1) · [GitHub Actions](https://github.com/lovach/Lunavect/actions)

## Release checks — September 13, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `b03e2181dd11d6d36b38808046fef11ad777be00`, tagged `v0.1.1`. Archive provenance confirmed the source was unchanged during the build. |
| Automated checks | [Release CI](https://github.com/lovach/Lunavect/actions/runs/34775844216): 569 Swift tests passed, 56 optional tests skipped; 75 Python tests passed, 2 skipped. Universal unsigned app, WidgetKit extension, helpers, resource checks and source provenance passed. |
| Distribution | Developer ID signature, Apple notarization ticket, unchanged App Group and arm64/x86_64 slices checked. |
| Public download | DMG, update ZIP, signed appcast and checksums downloaded anonymously from GitHub; bytes matched the packaged files. The app inside the downloaded DMG passed strict codesign, Gatekeeper and stapler validation. |
| Update signatures | Published ZIP and appcast signatures verified against the app's update public key. |
| Actual update | Sparkle installed 0.1.1 (147) from development build 145 on an ordinary quit. The installed executable matched the release. All 38 captured app preferences and shared widget preferences were unchanged; persisted data remained present. Activity files continued receiving live updates between captures. |
| Widget layout | Current layouts rendered with fictional data, including English, Russian and German states. Compact durations, expanded graph space and intermediate Y-axis labels were checked. Manual subscription dates were removed from widget faces. |
| Widget background | The owner confirmed adjustable glass on the development build on this Mac. The native material probe passed three archive cycles for three widget kinds, including disabled and incompatible-runtime fallbacks. This is not certification of every macOS version or accessibility setting. |
| Helper registration | After the update, a stale macOS helper registration failed to resolve its executable. Refreshing the app registration and repeating its existing startup maintenance restored helper 147; it started once and exited normally after becoming idle. System sleep remained enabled. A closed-lid cycle was not tested. |
| Existing downloads | The previous 0.1.0 release assets remain at their original URLs with unchanged digests. |

The DMG SHA-256 is `5fe1908dbe9455bb96692762d605432a6c255f7c1245d6a37adbf01a6df44d1f`. The updater uses the signed ZIP and appcast, not the DMG.

Test counts above belong to the release source, not subsequent documentation or screenshot-tool changes. An unsigned CI pass alone does not establish installed behavior or signing.

## Homebrew and installer

The cask points to the 0.1.1 DMG and its verified SHA-256. The branded Finder layout retains its application icon, Applications link and transfer arrow. [Installer layout](images/installer.jpg).

The earlier 0.1.0 (103) package passed an isolated Homebrew install and uninstall on September 12. That exercise preserved the existing application and validated the downloaded signature and notarization. A Homebrew upgrade between distinct versions is a separate scenario; the real Sparkle update above does not establish it.

## Public screenshots

The current gallery contains eleven native 2× images captured on September 13 from the production UI and a single fictional dataset: light/dark sessions, limits, statistics, menu-bar styles and four widget layouts. All eleven were visually inspected. The sandbox preflight, exact image set, dimensions and source-provenance checks passed.

Settings and session controls were rendered in offscreen AppKit windows with private preview dependencies. The images demonstrate layout, not interactive settings flows, external-client navigation, desktop WidgetKit placement or system glass compositing. Older screenshots, the retouched desktop capture and the unused movie have been removed. [Source and reproduction instructions](public-screenshots.md).

## Compatibility and remaining checks

The deployment minimum is macOS 14. Release checks were performed on macOS 26.5.2 with Apple silicon; the release source was built with Xcode 26.6 and Swift 6.3.3. A deployment target and universal binary slices express supported build targets, not proof of every runtime scenario.

| Area | Remaining limit |
| --- | --- |
| Other Macs | Intel hardware, macOS 14/15 and every supported OS revision have not been exercised. |
| First-time setup | Clean-Mac setup, different account plans and client versions, failed sign-in and retry need broader coverage. |
| Session lifecycle | More real-client coverage is needed for prolonged tasks, cancellation, sleep/wake, offline periods and returning to the exact original session. |
| Desktop widgets | Native layouts and the owner's glass setting were checked. Placement, editing and refresh of build 147 on the actual desktop are not yet fully verified. WidgetKit schedules refreshes. |
| Updates | Upgrade specifically from public build 103 to 147, disabled automatic updates and offline/retry paths remain open. The recorded successful Sparkle upgrade started from development build 145. |
| Accessibility | Full VoiceOver, keyboard navigation and widget appearance with increased contrast or reduced transparency need live verification. |
| Battery use | Short process samples and synthetic benchmarks do not establish prolonged idle energy consumption. |
| Experimental features | Optional glass and closed-lid Keep Awake are not guaranteed across Macs or future macOS releases. Glass is off by default. |

Missing or expired allowances are unavailable, never unlimited. Activity only counts observed or explicitly recovered intervals; gaps are not invented work.

The [engineering case study](case-study.md) preserves the historical synthetic performance workload and its source/toolchain manifest. [Check scopes](checks-and-release-gates.md) explains what each automated check establishes. Third-party resource provenance and unresolved permission status remain documented in [NOTICE](../NOTICE) and [IconSources.md](../Sources/Weekleft/Resources/IconSources.md).

## Reporting a problem

[Open an issue](https://github.com/lovach/Lunavect/issues/new/choose) with the app version, macOS version, Mac architecture and reproducible steps. Redact private session titles, paths and credentials from attachments.
