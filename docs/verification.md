# Verification and compatibility

The current public release is **Lunavect 0.1.9 (181)**. These records distinguish completed checks from unverified scenarios.

[Download and release notes](https://github.com/lovach/Lunavect/releases/tag/v0.1.9)

## 0.1.9 release checks — September 23, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `1979255872af7fcc51a2060a8898a81f5f16b421`, tagged `v0.1.9` (PR #20); archive provenance passed. A later test-only commit in the same PR waits for the session panel's rows to settle before measuring. |
| Automated checks | Full local check: 84 Python and 617 Swift tests passed (55 conditional skips), universal build, widget probes, resources and provenance. [Source CI](https://github.com/lovach/Lunavect/actions/runs/35838882201) passed. |
| Distribution | Developer ID signed and Apple notarized, build 181. Anonymous DMG, ZIP, appcast and checksum downloads matched the packaged bytes. The downloaded DMG app passed strict codesign, Gatekeeper and stapler checks. The ZIP signature verifies with the public key embedded in the app, and a modified copy is rejected; the latest feed points to 181. |
| Installed build | The app from the release DMG was installed over 0.1.8 with `install.sh` after stale copies left by the archive and check builds were unregistered. Both desktop widgets stayed `LIVE` from launch through the 10-minute confirmation and later timeline updates, with no placeholders or lookup failures. |
| Remaining scope | A complete Sparkle installation cycle and other macOS versions remain unverified. |

The 0.1.9 DMG SHA-256 is `b7082dc27c507f17422489c961c63aae18df945cb13c7eac15eac481a69244fc`.

## Codex memory agent — September 23, 2026

After Codex began consolidating memories on the test Mac, Connections reported **Session catalog is incomplete** for Codex while its limits stayed fresh. The catalog itself was complete: `thread/list` returned 94 threads on one page in under 0.1 s. One hook-reported session working in `~/.codex/memories` with `apply_patch` had no rollout, no state-database row and no title, and `thread/read` answered `thread not loaded`. Lunavect kept it as an active session and asked the app-server for it on every poll, which marked the catalog incomplete. Codex sessions in `CODEX_HOME/memories` are now internal agents. The new classification test fails without the change (the agent appears as a current session) and passes with it; a store test confirms that internal agents are never read back as known active sessions.

## 0.1.8 release checks — September 23, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `87b969908aa3e1d298b9aaae1dc14d26a043bbde`, tagged `v0.1.8` (PR #17); archive provenance passed. |
| Automated checks | The eight `WidgetRegistrationTests` passed locally, including the four-step schedule. The full check passed in [source CI](https://github.com/lovach/Lunavect/actions/runs/35808834786). |
| Distribution | Developer ID signed and Apple notarized, build 180. Anonymous DMG, ZIP, appcast and checksum downloads matched the packaged bytes. The downloaded DMG app passed strict codesign, Gatekeeper and stapler checks. The ZIP signature verifies with the public key embedded in the app, and a modified copy is rejected; the latest feed points to 180. |
| Compatibility | Signing identity, bundle IDs, App Group, update key and preference defaults are unchanged. All 20 assets of releases 0.1.3–0.1.7 still match their packaged SHA-256 digests at their original URLs. |
| Installed build | The app from the release DMG was installed over 0.1.7 with `install.sh` and launched. The first-launch repair produced about eight seconds of placeholders; the 5-second confirmation restored `LIVE`. Two registration changes followed: unregistering a copy left registered by the archive step (33 seconds after launch) and removing an older 0.1.3 copy from `/Applications` (after 4.5 minutes). Both widgets stayed `LIVE` through these changes and the 30-second, 2-minute and 10-minute confirmations, with no further lookup failures. |
| Remaining scope | A complete Sparkle installation cycle for this release and other macOS versions remain unverified. |

The 0.1.8 DMG SHA-256 is `0a1e3c0a5813e0f800994b9c368d75b12e96b7fe18b8ead78827336e91434a24`.

## 0.1.7 release checks — September 23, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `e3e65df894822baf335f3177a92b0014272c173c`, tagged `v0.1.7` (PR #15); archive provenance passed. |
| Automated checks | Full local check: 84 Python passed; 615 Swift passed, 55 conditional skips (670 total); built intent resources passed separately. Universal app/widget build, compatibility probes, resources, hooks and provenance passed. XcodeGen 2.46.0 parity and [source CI](https://github.com/lovach/Lunavect/actions/runs/35805439473) passed. |
| Distribution | Developer ID signed and Apple notarized, build 179. Anonymous DMG, ZIP, appcast and checksum downloads matched the packaged bytes. The downloaded DMG app passed strict codesign, Gatekeeper and stapler checks. The ZIP signature verifies with the public key embedded in the app, and a modified copy is rejected; the latest feed points to 179. |
| Compatibility | Signing identity, bundle IDs, App Group, update key and preference defaults are unchanged. Older public release assets retain their identities, digests and URLs. |
| Installed build | The app from the downloaded DMG was installed over local build 178 with `install.sh` and launched. The first-launch repair produced about ten seconds of placeholders; the 5-second confirmation restored `LIVE`. The 30-second confirmation coincided with leftover registrations from the packaging tools and returned placeholders until the next registration change, which restored `LIVE`. Three later relaunches stayed `LIVE` through both confirmations. In repeated experiments, re-registration outside an install never broke rendering (21 of 21); failures clustered around bundle replacement and cleanup. |
| Remaining scope | A confirmation can still coincide with post-update cleanup; relaunching Lunavect repairs it. A complete Sparkle installation cycle for this release and other macOS versions remain unverified. |

The 0.1.7 DMG SHA-256 is `512b6644e2ce03f2d67aa2543deba82509d47c4dbf505b61222423cc33052237`.

## Widget registration, background CPU and terminal focus — September 23, 2026

Both existing desktop widgets showed placeholders for about four hours after local build 176 was installed, while the extension reported successful timelines and shared data stayed fresh. NotificationCenter rejected each archive with `WidgetArchiver.ValidationError.bundleStubNotSupported` / `Bundle could not be looked up`. The app's one-time launch repair had already run; no later registration change occurred. Re-registering the installed host and its extension restored both widgets to `LIVE` within a second. On a later local launch the same failure followed the launch repair's extension restart and cleared at the next registration change. Each launch now re-confirms registration after 5 and 30 seconds without restarting the extension, and `install.sh` retires the previous copy before its final registration. After installing build 178, both widgets stayed `LIVE` through installation, launch repair and both checks, with every archive load successful. An actual Sparkle update cycle was not exercised.

Build 176 used 17 min 50 s of CPU in 4 h (7.5% average, including startup). Samples attributed most of it to per-character `CharacterSet` construction in session ID validation, re-decoding hook records and Claude Desktop metadata on every poll, opening the Codex state database on every poll and resolving every process path. Build 178 averaged 2.9% over 5 min of steady state with an active session and the animated menu-bar character; the earlier hot frames no longer appear and the remainder is mainly menu-bar animation and polling. The two measurements differ in duration and conditions; this is not a battery claim.

The unreleased terminal-focus path no longer searches running processes for Desktop, editor or background sessions, no longer treats a `node` process in the project folder as Claude, never launches a terminal that is not running and rejects device names with a trailing newline. Navigation tests inject focus instead of scanning the test machine's processes.

The Swift suite passed 670 tests with 55 optional skips and no failures; 84 Python tests passed. New regressions cover cached-file invalidation, late Codex thread records, installer registration order (fails against the previous script), repeated registration checks and terminal-focus inputs. Builds 177 and 178 are local signed updates, not notarized or published. Public 0.1.6 remains build 165.

## Local tool-launched Claude session filtering — September 22, 2026

A live extra catalog row was traced to a print-mode Claude CLI launched by a shell inside an existing Claude Desktop task. The catalog labelled it interactive; its ancestry still reached Desktop, so the previous adapter presented it as an independent conversation. The exact identity of the earlier row in the owner's screenshot was not recovered. The observed equivalent establishes this mechanism, not every earlier transient report.

The development filter requires a command process between agent runtimes. Direct runtime/supervisor chains stay unknown, and explicitly declared background tasks remain independent even when a hook reports nested ancestry. This distinction was added after an intermediate live probe incorrectly classified supervised background jobs. The final build preserved all 13 background records in the sampled catalog, including retained history; this is not a count of active tasks. Known internal origins survive missing catalog/hook evidence; an explicit independent resume is allowed.

The focused session, hook, visibility, lifecycle and efficiency suite passed 52 tests with no failures. After adding a background-merge assertion, that test passed again. Coverage includes an actual native parent/command/child process fixture, independent Desktop/Terminal launches, missing/orphan/cyclic ancestry, catalog gaps, counters, observations and independent resume. The universal Release archive and Developer ID export passed strict signatures, product resources, App Group, headless hook and helper-policy checks.

Local 0.1.6 build 167 was installed. Its loaded native accessibility tree showed one working task and zero waiting; the finished Claude task subsequently followed the existing automatic-hide preference. A screenshot attempt lost the transient popover, so visual inspection was not completed. Widget preferences were identical; defaults changed only helper-build registration, widget-registration stamp and cached automatic menu icon. NotificationCenter rendered both existing widgets as LIVE at 18:22 without resetting system services or placements.

Build 167 is a local signed update, not notarized or published. Public 0.1.6 remains build 165. The full release check was not run for this local change, and long-term absence of all possible phantom sessions is not established. Private diagnostic evidence is retained outside Git.

## 0.1.6 release checks — September 22, 2026

| Area | Result |
| --- | --- |
| Release source | Clean commit `91ccef1dea35297302d5d95f6cfd6112203b0d83`, tagged `v0.1.6`; archive provenance passed. |
| Automated checks | Full local check: 83 Python passed; 600 Swift passed, 55 conditional skips; built intent resources passed separately. Universal app/widget build, compatibility probes, resources, hooks and provenance passed. XcodeGen 2.46.0 parity and [source CI](https://github.com/lovach/Lunavect/actions/runs/35745735730) passed. |
| Distribution | Developer ID signed and Apple notarized, build 165. Anonymous DMG, ZIP, appcast and checksum downloads matched the packaged bytes. The downloaded DMG app passed strict codesign, Gatekeeper, stapler, resource, App Group and helper-policy checks. Public ZIP/feed signatures match the embedded update key; the latest feed points to 165. |
| Compatibility | Signing identity, bundle IDs, App Group, update key and preference defaults are unchanged. Older public release assets retain their identities, digests and URLs. |
| Installed build | The same notarized 0.1.6 (165) app was installed locally and launched. Widget preferences were identical; only helper-build and widget-registration defaults changed. NotificationCenter rendered both existing widgets as LIVE after installation; direct desktop visual verification remains separate. |
| Remaining scope | The event-tracking regression and isolated scroll invalidation are verified; the original transient false-wait incident was not captured, live FPS improvement was not measured, and an automatic Sparkle upgrade for this exact release is unverified. Desktop scheduling on other Macs remains unverified. |

The 0.1.6 DMG SHA-256 is `55e26c876b11448cc32f51526bc36f7ac647c70707b529d5f022d0b978ceabe2`.

## Local menu-bar delivery and session scrolling — September 22, 2026

A regression through the actual AppDelegate status subscription reproduced a waiting count remaining at one during AppKit event tracking after the session store had already changed the task to running. The old RunLoop.main scheduler delivered only after default-mode processing resumed. Delivering on DispatchQueue.main clears waiting and publishes running during tracking, without opening the panel. The test failed twice on the previous binding and passes with this change. This establishes one stale-display mechanism; the owner's earlier transient incident had already disappeared and its exact source was not captured.

Scroll offsets now publish only to the small overflow control. Mutable row/viewport geometry is read by native gesture handling without invalidating the SwiftUI session list on every pixel. A 240-offset regression verifies zero whole-panel publications, while gesture checks verify that hit testing reads updated geometry without a representable update. Existing overflow, paging, drag, swipe and lifecycle checks passed. There were 48 focused test executions across three green runs (one repeated counter test), with no failures. The red counter test is retained as local evidence.

The universal Release archive and Developer ID export passed strict signatures, product resources, App Group, headless hook and awake-policy checks. Local 0.1.5 build 164 was installed; the live native accessibility tree loaded nine rows, six running and zero waiting. Computer Use repeatedly lost access to the transient popover during scrolling, so a live scroll/FPS comparison and final screenshot were not obtained. The pre-install process sample was not a controlled FPS baseline. Automated invalidation checks do not establish a measured frame-rate improvement.

Existing widget preferences were identical after installation. App defaults changed only the helper build, widget-registration stamp and automatic-update check timestamp. NotificationCenter briefly reported missing containing bundles during replacement, then rendered both existing Lunavect widgets as LIVE at 16:16:10. System widget services and placements were not reset. Direct desktop visual verification remains separate. Build 164 was a local signed update, not notarized or published; at that check public 0.1.5 remained build 162. The full release check was not run for this local update.

## Local widget recovery, September 21, 2026

Both existing desktop widgets displayed placeholders while the extension produced successful timelines and shared data remained fresh. NotificationCenter rejected those timelines with `WidgetArchiver.ValidationError.bundleStubNotSupported` / `Bundle could not be looked up`. The system also logged missing containing bundles during registration changes. Re-registering the installed host followed by its embedded extension restored both existing widget instances to `LIVE` at 23:12; subsequent reloads and foreground transitions through 23:15 also remained `LIVE`. Only the Lunavect extension and host were restarted; system widget services, placements and preference files were not reset. Computer Use exposed only the Screen Time widget window, so direct visual confirmation of the two recovered widgets remains separate from this system-renderer evidence.

Installer cleanup now removes the development extension before registering the installed host. Distribution cleanup re-registers a validated installed host and its matching extension after removing temporary registrations; it does not launch apps or alter installed files/preferences. Nine focused installer/distribution tests passed, including rollback and invalid/foreign bundle cases. Both new invalidation regressions fail against the prior scripts. Shell syntax passed. This is a local tooling fix, not a new app/DMG release; long-term WidgetKit scheduling is not proven by these checks.

## Local segmented Codex rollout recovery — September 21, 2026

A live ordinary Desktop task remained active while build 162 reported only catalog/unknown state. Its rollout filename contained a second UUID after the thread ID. The legacy suffix guard rejected that file, and filename discovery also missed the new form. The fix accepts the bounded optional segment suffix, discovers only the primary thread ID once, and requires a matching session metadata header for segmented activity files. Directory containment, symlink rejection, lifecycle timestamps, runtime writer checks and internal-agent filtering remain intact.

The new activity/discovery regressions failed before the fix and passed afterward. Focused activity, discovery, session, hidden-session and store-lifecycle checks passed 74 tests with two conditional skips. A rebuilt read-only live probe changed the same task from unknown/catalog to running/localEvent with a live writer. The signed Release app/widget archive and Developer ID export passed strict signatures, resources, App Group and helper-policy checks.

Local build 163 was installed and the native panel showed both ordinary working tasks, including the previously missing task with its recovered elapsed timer; the hidden count remained unchanged. Widget preferences were identical, and 38 of 40 existing app-default values were identical; only helper-build registration and the widget-registration stamp changed. This local build has not been published or notarized, and the full release check was not run. At that check, public 0.1.5 remained build 162.

The previous 0.1.5 release checks remain recorded below.

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

The cask points to the 0.1.6 DMG and its verified SHA-256. The branded Finder layout retains its application icon, Applications link and transfer arrow. [Installer layout](images/installer.jpg).

The earlier 0.1.0 (103) package passed an isolated Homebrew install and uninstall on September 12. That exercise preserved the existing application and validated the downloaded signature and notarization. A Homebrew upgrade between distinct versions is a separate scenario; the real Sparkle update above does not establish it.

## Public screenshots

The current gallery contains twelve native 2× images captured on September 23 from the 0.1.8 production UI and a single fictional dataset: light/dark sessions, limits, statistics, menu-bar styles, appearance settings and four widget layouts. All twelve were visually inspected; compared with the September 14 set, only dates, times, the animated icon frame and period totals changed. The sandbox preflight, exact image set, dimensions and source-provenance checks passed.

The README and website showcase scenes are composed from 4× native renders with the same kind of fictional dataset; only system chrome around the renders is drawn. [How the scenes are made](public-screenshots.md#showcase-scenes). Settings and session controls were rendered in offscreen AppKit windows with private preview dependencies. The images demonstrate layout, not interactive settings flows, external-client navigation, desktop WidgetKit placement or system glass compositing. Older screenshots, the retouched desktop capture and the unused movie have been removed. [Source and reproduction instructions](public-screenshots.md).

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

[Check scopes](checks-and-release-gates.md) explains what each automated check establishes. Third-party resource provenance and unresolved permission status remain documented in [NOTICE](https://github.com/lovach/Lunavect/blob/main/NOTICE) and [IconSources.md](https://github.com/lovach/Lunavect/blob/main/Sources/Weekleft/Resources/IconSources.md).

## Reporting a problem

[Open an issue](https://github.com/lovach/Lunavect/issues/new/choose) with the app version, macOS version, Mac architecture and reproducible steps. Redact private session titles, paths and credentials from attachments.
