<p align="center">
  <img src="design/selected/lunavect-appicon-1024.png" width="96" alt="Lunavect icon">
</p>

<h1 align="center">Lunavect</h1>

<p align="center">
  <strong>Claude Code and Codex, together in your Mac's menu bar.</strong><br>
  Session status, usage limits and desktop widgets. Free and open source.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <a href="https://github.com/lovach/Lunavect/releases/latest"><img src="https://img.shields.io/github/v/release/lovach/Lunavect?color=a5d8ff" alt="Latest release"></a>
  <a href="https://github.com/lovach/Lunavect/actions/workflows/ci.yml"><img src="https://github.com/lovach/Lunavect/actions/workflows/ci.yml/badge.svg" alt="macOS checks"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/macOS-14%2B-555?logo=apple&logoColor=white" alt="macOS 14 or later"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-a5d8ff" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/lovach/Lunavect/releases/download/v0.1.0/Lunavect-0.1.0-installer-2.dmg"><img src="docs/images/download-macos.svg" width="256" height="56" alt="Download Lunavect for macOS — DMG"></a>
  <br><sub>Apple silicon &amp; Intel · Developer ID signed · Apple notarized</sub>
</p>

<p align="center">
  <a href="docs/images/macos-menu-bar.png"><img src="docs/images/macos-menu-bar.png" width="250" alt="Sessions on macOS — retouched development preview"></a>&nbsp;&nbsp;
  <a href="docs/images/limits.png"><img src="docs/images/limits.png" width="250" alt="Usage limits — weekly and five-hour allowances for Claude and Codex"></a>&nbsp;&nbsp;
  <a href="docs/images/activity.png"><img src="docs/images/activity.png" width="250" alt="Activity history — daily, weekly and monthly statistics"></a>
</p>

<p align="center">
  <a href="docs/images/macos-menu-bar.png">Sessions on macOS</a> ·
  <a href="docs/images/limits.png">Usage limits</a> ·
  <a href="docs/images/activity.png">Activity history</a>
</p>

<p align="center"><sub>Click a preview to enlarge it. All images use sample data. The macOS capture is retouched; its menu-bar usage indicators are a development preview, not part of 0.1.0. <a href="docs/verification.md#public-screenshots">Image details</a>.</sub></p>

## Install

### Install with Homebrew

With [Homebrew](https://brew.sh/) installed, paste these commands into Terminal:

```sh
brew tap lovach/lunavect https://github.com/lovach/Lunavect
brew install --cask lovach/lunavect/lunavect
open -a Lunavect
```

### Direct download

[Download the DMG](https://github.com/lovach/Lunavect/releases/download/v0.1.0/Lunavect-0.1.0-installer-2.dmg) (about 11 MB), open it, and drag **Lunavect** to **Applications**.

On first launch, choose **Connect Claude** or **Connect Codex**. The guide checks the official client, helps you sign in through it, and explains the local changes before enabling the connection. Connect either service or both.

### Requirements

- **macOS 14 Sonoma or later.** One download contains Apple silicon and Intel code. The release has been tested on Apple silicon; Intel hardware still needs testing.
- **Claude Code** for Claude usage and sessions. Claude Desktop alone is not enough.
- **The official Codex client** for Codex usage and sessions. Authentication stays in that client.

## Features

### Follow your sessions

Keep coding in Claude Code or Codex. Open Lunavect from the menu bar when you need a view across both.

- **Working, waiting or ready.** See running sessions, requests for permission or input, and completed responses, with current working and waiting counts.
- **Find the right task.** Search session names and projects; filter by Claude, Codex or active sessions.
- **Keep the panel useful.** Pin important sessions, reorder them, or move others to the hidden list. Jump back to a session from its actions.
- **Choose how it looks.** Light and dark appearances and compact menu-bar layouts.

<p align="center">
  <a href="docs/images/sessions-themes.png"><img src="docs/images/sessions-themes.png" width="800" alt="The same session panel in light and dark appearances, with working, permission-needed and ready states"></a>
</p>

### Keep an eye on your limits

- **Weekly and five-hour allowances.** See the remaining percentage and next reset for each connected service. Model-specific Claude limits appear when the client provides them.
- **Widgets in three sizes.** Choose limits, activity or a combined overview. Show one service or compare both.
- **Your own widget setup.** Right-click the desktop → **Edit Widgets** → search **Lunavect**. For an activity widget, right-click it → **Edit Widget** to choose its source and time period.

<p align="center">
  <a href="docs/images/widgets.png"><img src="docs/images/widgets.png" width="800" alt="Small limits and activity widgets, a medium comparison chart and a large combined overview"></a>
  <br><sub>Native widget layouts with sample data. Desktop placement and refresh are managed by macOS.</sub>
</p>

### Understand your activity

- **Day, week and month views.** Compare Claude and Codex on one time scale or focus on a single service.
- **Inspect the details.** Select a point to explore available project and session breakdowns for that period.
- **Know what is being measured.** Activity tracks locally recorded working intervals. Recovered history is marked as approximate; unavailable intervals remain unknown.

[Explore the activity chart](docs/images/activity-detail.png) · [How activity is counted](docs/activity.md)

### Make it fit your workflow

Optional sounds and notifications, a choice of menu-bar companions, and six interface languages: **English, Russian, German, Spanish, French and Simplified Chinese**. Built-in signed updates are available in **Settings → Updates**.

## Privacy

No Lunavect account, analytics backend, or provider passwords to paste into the app. Sign-in stays with the official Claude and Codex clients.

Session names, project paths and activity history stay on your Mac. With your connection choices, Lunavect reads local client data and configures local event handlers. GitHub receives normal update requests without session information; the official clients and their installers make their own network requests.

[Connection setup and removal](docs/connections.md) · [Local activity storage](docs/activity.md)

## Frequently asked questions

<details>
<summary><strong>How do I update or uninstall?</strong></summary>

Use **Settings → Updates** in the app. For a Homebrew installation:

```sh
brew update
brew upgrade --cask lovach/lunavect/lunavect
```

Before uninstalling, disconnect Claude and Codex in **Settings → Connections**, then quit Lunavect. This restores previous event handlers and the Claude status line.

```sh
brew uninstall --cask lovach/lunavect/lunavect
```

For a direct installation, delete Lunavect from Applications after disconnecting. Settings and activity history are retained. See [connection removal](docs/connections.md) for details.

</details>

<details>
<summary><strong>Why is a limit unavailable or a session out of date?</strong></summary>

Allowances depend on what the official client exposes for your account. Missing or expired values stay unavailable; they do not mean unlimited usage. Session state depends on client events, so a quiet or disconnected client may need attention.

Open **Settings → Connections** for diagnostics and repair guidance. See [session states](docs/sessions.md).

</details>

<details>
<summary><strong>Which release file should I download?</strong></summary>

Choose the **DMG**. The ZIP and `appcast.xml` support the built-in updater. Versions, release notes and SHA-256 checksum files are on the [Releases page](https://github.com/lovach/Lunavect/releases).

</details>

<details>
<summary><strong>What is still being tested?</strong></summary>

Lunavect is an early release. Broader testing is needed for first-time setup, Intel Macs, session lifecycle edge cases, live desktop widgets and updates between distinct releases. Widget refresh follows macOS's schedule. Experimental widget transparency is off by default; optional closed-lid keep-awake behavior needs testing on your Mac.

See [verified checks and compatibility](docs/verification.md) for the release evidence and remaining limits.

</details>

## Documentation

| Guide | What it covers |
| --- | --- |
| [Connections](docs/connections.md) | Client setup, local changes, repair and removal |
| [Sessions](docs/sessions.md) | States, event sources and session actions |
| [Activity](docs/activity.md) | Time accounting, recovered history and storage |
| [Compatibility](docs/verification.md) | Verified release checks and open limitations |
| [Development](docs/development.md) | Source map, build requirements and focused tests |
| [Updates](docs/updates.md) | Signing, packaging and the update feed |

## Build from source

Install full Xcode with a compatible Swift toolchain, then:

```sh
git clone https://github.com/lovach/Lunavect.git
cd Lunavect
./scripts/check.sh
```

This runs checks and builds the universal Release app, helpers and WidgetKit extension without a signing account. For local installation and development setup, follow the [development guide](docs/development.md).

## Contributing

[Report a bug](https://github.com/lovach/Lunavect/issues/new?template=bug.yml) or [suggest a feature](https://github.com/lovach/Lunavect/issues/new?template=feature.yml). Include your macOS version and steps to reproduce; remove private session names, paths and credentials from attachments. Testing on another Mac is especially useful — start with the [first-install checklist](docs/first-install-check.md).

## License

Original Lunavect code is [MIT licensed](LICENSE). Third-party software, artwork and marks have separate terms in [NOTICE](NOTICE). Lunavect is independent of Anthropic and OpenAI.
