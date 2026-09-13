# Contributing to Lunavect

Bug reports, fixes, translations and documentation improvements are welcome.

## Before starting

Search [existing issues](https://github.com/lovach/Lunavect/issues) for the same problem. Use the [bug report](https://github.com/lovach/Lunavect/issues/new?template=bug.yml) or [feature request](https://github.com/lovach/Lunavect/issues/new?template=feature.yml) form. For a substantial feature or redesign, describe the proposed behavior in an issue before investing in the implementation.

Report security vulnerabilities [privately](SECURITY.md). Keep credentials, personal conversations and unredacted diagnostics out of public issues, commits and pull requests.

## Development

Fork the repository and make a branch from `main`. A full Xcode installation and compatible Swift toolchain are required. Start with the [development guide](docs/development.md) for the source map, build commands and local signing setup.

```sh
./scripts/check.sh
```

This runs the project's checks and creates an unsigned universal Release build. It does not install the app. For a focused code change, use the relevant tests while iterating. Documentation changes need working links and correct commands, not unrelated app tests.

## Pull requests

Keep each pull request focused on one problem. Explain the user-visible behavior, why it changes and what you checked. For an interface change, include a screenshot with fictional data. State any testing you could not perform. For performance changes, keep workload dimensions, configuration and source provenance with the samples; report comparable before/after measurements rather than inferring a speedup from a refactor. See the [measurement protocol](docs/development.md#synthetic-performance-measurements).

Preserve these contracts:

- Missing or stale data must not become a fabricated allowance, live session or working interval.
- Connecting and disconnecting a client must preserve unrelated settings and handlers.
- Existing user data, bundle IDs and App Groups need a migration if changed. The internal `Weekleft` name remains in compatibility-facing paths.
- Changes to targets or build structure must keep `project.yml` and `Weekleft.xcodeproj` in sync.
- New interface text belongs in the shared translation catalog. See [localization](docs/localization.md).

Include a regression test when it demonstrates a bug fix. For native UI changes, inspect the rendered interface; compilation alone does not establish that controls are usable. Do not claim live-client, WidgetKit or Intel compatibility from a source build alone.

Original code and documentation use the [MIT license](LICENSE). Preserve third-party notices and check [NOTICE](NOTICE) before adding or redistributing artwork or dependencies. Forks need their own signing and update configuration; do not publish packages using another maintainer's update identity.
