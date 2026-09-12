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

## Build and test

From the repository root:

```sh
./scripts/check.sh
```

This runs Swift and Python tests, widget background compatibility checks, and a universal Release build of the app, helpers and widget without a signing account. Xcode products go to a temporary directory outside the repository, configurable with `WEEKLEFT_CHECK_DERIVED_DATA`. The check removes its generated app bundle to avoid duplicate entries in the macOS widget gallery.

For focused changes, run the relevant suite:

```sh
swift test --filter SessionDragSnapshotTests
```

Opt-in native renders and live integration tests are skipped unless their environment variables are explicitly set. A passing build does not prove live client integration or desktop WidgetKit behavior. See [verification and compatibility](verification.md).

GitHub Actions runs `scripts/check.sh` on pushes to `main`, pull requests and manual dispatch, with read-only repository access and no signing secrets.

## Signed local development

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your own signing team. The local file is ignored by Git.

```sh
./scripts/build.sh
./scripts/install.sh
```

The default configuration is Release. Use `WEEKLEFT_BUILD_CONFIGURATION=Debug` explicitly for debugging. Build products live outside the project. The install script targets `~/Applications/Lunavect.app`, so review it before running if you have an existing installation.

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

The public gallery is rendered directly from production SwiftUI components using fictional sessions, allowances and activity. It does not read the user's session history or connect accounts.

```sh
LUNAVECT_RELEASE_SCREENSHOTS="$PWD/docs/images" \
  swift test --filter ReleaseScreenshots.testRenderPublicScreenshots
```

The renderer creates light/dark overview images, session appearances, usage and activity screens, widget layouts and a social preview. Inspect the PNGs before committing them. These renders document the interface; they are not evidence of desktop widget placement or live account behavior.

## Releases

Publish the DMG, signed update ZIP, signed appcast and checksums together. Verify the files downloaded from GitHub, then update the README's direct DMG links to that exact release. See [distribution commands](updates.md) and [the current compatibility matrix](verification.md).

Original code is [MIT licensed](../LICENSE). Keep third-party attribution and permission status in [NOTICE](../NOTICE) and the resource provenance document.
