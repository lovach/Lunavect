# Verification and compatibility

## Local segmented Codex rollout recovery — September 21, 2026

A live ordinary Desktop task remained active while build 162 reported only catalog/unknown state. Its rollout filename contained a second UUID after the thread ID. The legacy suffix guard rejected that file, and filename discovery also missed the new form. The fix accepts the bounded optional segment suffix, discovers only the primary thread ID once, and requires a matching session metadata header for segmented activity files. Directory containment, symlink rejection, lifecycle timestamps, runtime writer checks and internal-agent filtering remain intact.

The new activity/discovery regressions failed before the fix and passed afterward. Focused activity, discovery, session, hidden-session and store-lifecycle checks passed 74 tests with two conditional skips. A rebuilt read-only live probe changed the same task from unknown/catalog to running/localEvent with a live writer. The signed Release app/widget archive and Developer ID export passed strict signatures, resources, App Group and helper-policy checks.

Local build 163 was installed and the native panel showed both ordinary working tasks, including the previously missing task with its recovered elapsed timer; the hidden count remained unchanged. Widget preferences were identical, and 38 of 40 existing app-default values were identical; only helper-build registration and the widget-registration stamp changed. This local build has not been published or notarized, and the full release check was not run. The public 0.1.5 release remains build 162.

The current public release is **Lunavect 0.1.5 (162)**. These records distinguish checks that ran from scenarios still requiring verification.

[Download and release notes](https://github.com/lovach/Lunavect/releases/tag/v0.1.5) · [GitHub Actions](https://github.com/lovach/Lunavect/actions)

## 0.1.5 release checks — September 21, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `83ddad43fc79bd918ee76e6d18f4364d82144d6f`, tagged `v0.1.5`. Signed archive source provenance passed. |
| Automated checks | Local `scripts/check.sh`: 79 Python tests and 594 Swift tests passed; 55 conditional Swift skips; no failures. Built intent resources passed separately. Universal app/WidgetKit build, runtime probes, hooks, resources and provenance passed. XcodeGen 2.46.0 parity and [release CI](https://github.com/lovach/Lunavect/actions/runs/35543896261) passed. |
| Distribution | Developer ID signed and Apple notarized, build 162. Anonymous DMG, ZIP, appcast and checksum downloads matched the packaged bytes. The downloaded DMG app passed strict codesign, Gatekeeper, stapler, resource, App Group and helper-policy checks. Public ZIP/feed signatures match the app's update key; the latest feed points to this build. |
| Compatibility | Existing signing identity, bundle IDs, App Group, update key and preference defaults are unchanged. Older public release assets retain their original identities, digests and URLs. |
| Remaining scope | A complete Sparkle installation cycle for this release, desktop widget scheduling on other Macs and the separately reported empty waiting indication remain unverified. The local regressions and installed development-build observations below cover the identified causes. |

The 0.1.5 DMG SHA-256 is `30c7ef3277639303563ae08ed13da4be3d754f6c289cb34f7c08740f22ca66b5`.

## 0.1.5 regression coverage

Two session-lifecycle regressions reproduce an expired waiting count while local event reads fail or remain pending. Internal-agent fixtures reproduce a Codex worker being treated as a current waiting session, including after fresh hook events. Classification uses explicit parent/source metadata and preserves ordinary tasks, independent chats and older saved records. Positive origin survives temporary catalog gaps. Source databases and provider archives are not modified.

Six widget registration tests cover version/path changes, transient and persistent failures, cancellation, excluded bundles and signalling only a synthetic extension at the exact matching executable path. Local installed builds confirmed startup recovery, retention of widget preferences and removal of a known internal worker while real tasks remained. An actual Sparkle download/install cycle and the separately reported empty waiting indication were not independently reproduced.

## 0.1.4 release checks — September 14, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `d832c57259861f327add2213c614dfd7bd5bbd7e`, tagged `v0.1.4`. Archive source provenance passed. |
| Automated checks | Local `scripts/check.sh` passed: 79 Python tests; 638 Swift tests with 55 conditional skips and no failures; universal Release app, WidgetKit, hook, product resources, intent metadata and provenance checks. [Release CI](https://github.com/lovach/Lunavect/actions/runs/34837714173) passed. |
| Focused behavior | 48 focused checks, 2 conditional skips and no failures. Delayed timer callbacks retain each visible dot step, phrase changes follow two displayed cycles, and reserved dot width stays fixed. Added confirmation phrasing and inline-filename cases preserve quoted/code-example exclusions. |
| Native interface | Menu-bar artwork, the update notice and dot states in all three styles were rendered and visually inspected. Development build 156 launched with current sessions; user preferences and shared widget settings were retained. Only the helper registration build record changed. |
| Distribution | Developer ID signed and Apple notarized, build 157. Anonymous downloads of the DMG, ZIP, appcast and checksums matched the packaged bytes. The downloaded app passed strict codesign, Gatekeeper, stapler, product-resource and helper-policy checks. ZIP and feed signatures passed, and the latest appcast matches this release. |
| Remaining scope | Existing Claude replies are not reprocessed; unfamiliar request wording can still be missed. Automatic installation of this exact release and prolonged animation behavior under real system load have not been verified live. |

The 0.1.4 DMG SHA-256 is `c5d4d6a7362c6926e412de5129f046f8cc59c828731fb20b0d5687d3e4bc6bfe`. Previous release downloads retain their original URLs.

## 0.1.3 release checks — September 14, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `a7c051b331cf1efcb751e2c5c8d2fff8ecf767ec`, tagged `v0.1.3`. Source provenance remained unchanged throughout the signed archive. |
| Automated checks | Local `scripts/check.sh` passed: 79 Python tests; 637 Swift tests with 55 conditional skips and no failures; universal Release build with WidgetKit, hook, resource, intent metadata and provenance checks. [Release CI](https://github.com/lovach/Lunavect/actions/runs/34829559280) passed. |
| Covered behavior | Widget timestamp refresh and stale recovery; resumed Claude work superseding old waiting questions; compaction lifecycle; bounded count badges, idle artwork and two-cycle phrases across all three menu-bar styles. |
| Native gallery | Twelve native images rendered with fictional data under the existing isolation policy and were visually inspected. The new settings image exposes icon choices directly. A fresh Finder capture shows the actual mounted 0.1.3 DMG; its layout is unchanged. |
| Distribution | Developer ID signed and Apple notarized, build 154. Public DMG, ZIP, appcast and checksum files were downloaded anonymously and matched the packaged bytes. The downloaded DMG app passed strict codesign, Gatekeeper, stapler, product-resource and helper-policy checks; ZIP and feed signatures verified. The latest appcast matches this release. |
| Compatibility | Bundle IDs, App Group, data paths and update key are unchanged. Saved appearance preferences retain their decoding behavior. |
| Actual update | Automatic installation of this exact release and its desktop widget refresh have not been verified live. Earlier update evidence below is separate. |

The 0.1.3 DMG SHA-256 is `269b42b0e1840789417f61a97100fe4c29193c70a8b20cb2ba46236c2f855575`. Previous release downloads remain available at their original URLs.

## 0.1.2 release checks — September 13, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `5395a84312242c9afbfd62dbcd358e57dec1d0cd`, tagged `v0.1.2`. Source provenance stayed unchanged through the archive. |
| Automated checks | [Release CI](https://github.com/lovach/Lunavect/actions/runs/34784740200): 572 Swift tests passed, 55 optional tests skipped; 77 Python tests passed, 2 skipped. Universal unsigned app, WidgetKit extension, helpers, product resources and source provenance passed; the built intent metadata check also passed. |
| Focused behavior | 42 focused checks passed, one opt-in check skipped. Coverage includes explicit closing questions, normal responses, quoted/code examples, idle polls, resumed work, terminal states, expiry and the waiting count. |
| Native view | Russian and English session views rendered under the existing sandbox policy and were visually inspected. A recognized question was orange and counted as waiting; the completed answer was green. Forbidden-access probes and unchanged sentinel checks passed. |
| Distribution | Developer ID signed, Apple notarized, build 149. Public DMG, ZIP, appcast and checksums were downloaded anonymously and matched their packaged bytes. The downloaded DMG's app passed codesign, Gatekeeper and stapler checks; the ZIP and feed signatures verified. |
| Compatibility | The optional inference flag preserves decoding of existing session records. Signing identity, bundle IDs, shared data paths and update key are unchanged. Recognition covers selected Russian, English and German phrasing and can miss unfamiliar wording. |
| Actual update | An installed automatic upgrade to this exact release has not yet been verified. The previous successful Sparkle update below is separate evidence. |

The 0.1.2 DMG SHA-256 is `b7ce7431159941525424192a146bdd24ce9a09237093123899c038d4e2e6bffe`. Existing 0.1.0 and 0.1.1 release assets retain their original digests and URLs.

## 0.1.1 release checks — September 13, 2026

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

The 0.1.1 DMG SHA-256 is `5fe1908dbe9455bb96692762d605432a6c255f7c1245d6a37adbf01a6df44d1f`. The updater uses the signed ZIP and appcast, not the DMG.

Test counts above belong to the release source, not subsequent documentation or screenshot-tool changes. An unsigned CI pass alone does not establish installed behavior or signing.

## Homebrew and installer

The cask points to the 0.1.5 DMG and its verified SHA-256. The branded Finder layout retains its application icon, Applications link and transfer arrow. [Installer layout](images/installer.jpg).

The earlier 0.1.0 (103) package passed an isolated Homebrew install and uninstall on September 12. That exercise preserved the existing application and validated the downloaded signature and notarization. A Homebrew upgrade between distinct versions is a separate scenario; the real Sparkle update above does not establish it.

## Public screenshots

The current gallery contains twelve native 2× images captured on September 14 from the production UI and a single fictional dataset: light/dark sessions, limits, statistics, menu-bar styles, appearance settings and four widget layouts. All twelve were visually inspected. The sandbox preflight, exact image set, dimensions and source-provenance checks passed.

Settings and session controls were rendered in offscreen AppKit windows with private preview dependencies. The images demonstrate layout, not interactive settings flows, external-client navigation, desktop WidgetKit placement or system glass compositing. Older screenshots, the retouched desktop capture and the unused movie have been removed. [Source and reproduction instructions](public-screenshots.md).

## Compatibility and remaining checks

The deployment minimum is macOS 14. Release checks were performed on macOS 26.5.2 with Apple silicon; the release source was built with Xcode 26.6 and Swift 6.3.3. A deployment target and universal binary slices express supported build targets, not proof of every runtime scenario.

| Area | Remaining limit |
| --- | --- |
| Other Macs | Intel hardware, macOS 14/15 and every supported OS revision have not been exercised. |
| First-time setup | Clean-Mac setup, different account plans and client versions, failed sign-in and retry need broader coverage. |
| Session lifecycle | More real-client coverage is needed for prolonged tasks, cancellation, sleep/wake, offline periods and returning to the exact original session. |
| Desktop widgets | Native layouts and the owner's glass setting were checked. Startup registration recovery was observed on a local development build; placement, editing and refresh of public build 162 on the actual desktop are not yet fully verified. WidgetKit schedules refreshes. |
| Updates | Upgrade from public 0.1.4 (157) to 0.1.5 (162), older 0.1.0 profiles, disabled automatic updates and offline/retry paths remain open. The recorded successful Sparkle upgrade started from development build 145. |
| Accessibility | Full VoiceOver, keyboard navigation and widget appearance with increased contrast or reduced transparency need live verification. |
| Battery use | Short process samples and synthetic benchmarks do not establish prolonged idle energy consumption. |
| Experimental features | Optional glass and closed-lid Keep Awake are not guaranteed across Macs or future macOS releases. Glass is off by default. |

Missing or expired allowances are unavailable, never unlimited. Activity only counts observed or explicitly recovered intervals; gaps are not invented work.

[Check scopes](checks-and-release-gates.md) explains what each automated check establishes. Third-party resource provenance and unresolved permission status remain documented in [NOTICE](../NOTICE) and [IconSources.md](../Sources/Weekleft/Resources/IconSources.md).

## Reporting a problem

[Open an issue](https://github.com/lovach/Lunavect/issues/new/choose) with the app version, macOS version, Mac architecture and reproducible steps. Redact private session titles, paths and credentials from attachments.
