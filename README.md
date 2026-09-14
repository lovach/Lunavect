<div align="center">

<img src="design/selected/lunavect-appicon-1024.png" width="192" height="192" alt="Lunavect icon">

# Lunavect

A macOS menu bar app and desktop widgets for **Claude Code** and **Codex**.

<p>
  <a href="https://github.com/lovach/Lunavect/releases/download/v0.1.2/Lunavect-0.1.2.dmg"><img src="docs/images/download-macos.svg" width="256" height="56" alt="Download Lunavect for macOS — DMG"></a>
</p>

macOS 14+ · Apple silicon & Intel · Free and open source

[Sessions](#sessions) · [Usage limits](#usage-limits) · [Widgets](#desktop-widgets) · [Install](#install) · [Release notes](CHANGELOG.md)

<p>
  <a href="docs/images/readme-overview-dark.png">
    <picture>
      <source media="(max-width: 600px) and (prefers-color-scheme: light)" srcset="docs/images/readme-sessions-light.png">
      <source media="(max-width: 600px)" srcset="docs/images/readme-sessions-dark.png">
      <source media="(prefers-color-scheme: dark)" srcset="docs/images/readme-overview-dark.png">
      <source media="(prefers-color-scheme: light)" srcset="docs/images/readme-overview-light.png">
      <img src="docs/images/readme-overview-dark.png" width="784" alt="Lunavect session panel beside weekly usage limits and daily activity for Claude Code and Codex">
    </picture>
  </a>
</p>

<sub>Current interface, captured on September 14, 2026 with fictional data. [About the screenshots](docs/verification.md#public-screenshots).</sub>

## Install

### Install with Homebrew

<div align="left">

```sh
brew tap lovach/lunavect https://github.com/lovach/Lunavect
brew install --cask lovach/lunavect/lunavect
open -a Lunavect
```

</div>

Or [download the DMG](https://github.com/lovach/Lunavect/releases/download/v0.1.2/Lunavect-0.1.2.dmg) and drag **Lunavect** to **Applications**. The release is Developer ID signed and notarized by Apple.

Open **Connect Claude** or **Connect Codex** in Lunavect. Claude requires **Claude Code CLI**; Claude Desktop alone is not enough. Connect either service or both. Sign-in stays with the official clients.

[Setup, updates and uninstall](docs/installation.md) · [Compatibility and known limitations](docs/verification.md)

## Screenshots

### Sessions

See which task is working, needs input or has finished.<br>
Search by session or project. Filter, pin, reorder and hide sessions.

<p>
  <a href="docs/images/readme-sessions-light.png"><img src="docs/images/readme-sessions-light.png" width="392" alt="Claude Code and Codex session panel in light appearance"></a>
  <a href="docs/images/readme-sessions-dark.png"><img src="docs/images/readme-sessions-dark.png" width="392" alt="Claude Code and Codex session panel in dark appearance"></a>
</p>

### Usage limits

Weekly and five-hour allowances, with a reset time for each provider.<br>
Missing or expired limits stay marked as unavailable.

<p>
  <a href="docs/images/limits.png"><img src="docs/images/limits.png" width="800" alt="Usage settings showing weekly and five-hour remaining allowances and reset times for Claude and Codex"></a>
</p>

### Desktop widgets

Small, medium and large layouts for limits, activity or both.<br>
Choose a solid background or adjustable glass in Settings → Widgets.<br>
macOS manages placement and refresh; glass is experimental and off by default.

<p>
  <a href="docs/images/widget-overview.png"><img src="docs/images/widget-overview.png" width="344" alt="Compact weekly limits above an activity chart with detailed hour labels"></a>
  <a href="docs/images/widget-activity-large.png"><img src="docs/images/widget-activity-large.png" width="344" alt="Activity widget with full duration values and daily history"></a>
</p>
<p>
  <a href="docs/images/widget-limits.png"><img src="docs/images/widget-limits.png" width="344" alt="Weekly remaining allowances and reset countdowns"></a>
  <a href="docs/images/widget-activity-small.png"><img src="docs/images/widget-activity-small.png" width="164" alt="Small activity widget with readable provider totals"></a>
</p>

### Activity

Working time by day, week and month, with project and session breakdowns.<br>
Recovered history is marked as approximate.

<p>
  <a href="docs/images/readme-activity.png"><img src="docs/images/readme-activity.png" width="800" alt="Activity statistics with provider totals, a daily chart, recovered history and project navigation"></a>
</p>

### Menu bar

Choose bars and percentages, compact icons and percentages, or rings.<br>
The compact mode removes the bars and reduces the height of the indicator.

<p>
  <a href="docs/images/menu-bar.png"><img src="docs/images/menu-bar.png" width="720" alt="Three native menu-bar limit styles: bars and percentages, icons and percentages, and rings"></a>
</p>

### Make it yours

Choose a character and session-status style, or let Lunavect pick the character automatically.<br>
Activity phrases switch after two dot cycles. Input and approval requests take priority.

<p>
  <a href="docs/images/settings-menu-bar.png"><img src="docs/images/settings-menu-bar.png" width="800" alt="Menu-bar settings with all character choices visible and configurable session status"></a>
</p>

All images open at full resolution when clicked. Session names, paths and usage values are samples.

## FAQ

**Can I use only Claude or only Codex?**<br>
Yes. Connect either provider or both. Claude requires Claude Code CLI; Claude Desktop alone is not enough.

**Do I need another account or an API key?**<br>
No Lunavect account or pasted API key is required. Sign-in stays with the official clients; available allowances depend on your account.

**Why is a limit unavailable or a widget behind the app?**<br>
Limits need fresh data from the client. Widgets read saved data and refresh when macOS schedules them. Check Connections and the value's timestamp.

**Is activity the same as token usage?**<br>
No. It measures working intervals. Recovered history is marked `≈`, and overlapping sessions are counted once in the combined total.

[All questions and answers](docs/faq.md) · [Installation and troubleshooting](docs/installation.md)

## Data and connections

Session titles, project paths and activity history stay on your Mac. Lunavect reads local client data and configures event handlers when you connect a service. It has no account system or analytics backend. Update checks go to GitHub without session data; the official clients make their own network requests.

Activity measures working intervals. Recovered history is marked as approximate. Missing or expired usage limits remain unavailable.

[Privacy and permissions](PRIVACY.md) · [Connection details](docs/connections.md) · [How activity is counted](docs/activity.md)

## Development

Requires full Xcode and a compatible Swift toolchain.

<div align="left">

```sh
git clone https://github.com/lovach/Lunavect.git
cd Lunavect
./scripts/check.sh
```

</div>

The check runs tests and builds the universal Release app, helpers and WidgetKit extension without a signing account.

[Contributing](CONTRIBUTING.md) · [Development guide](docs/development.md) · [GitHub Actions](https://github.com/lovach/Lunavect/actions/workflows/ci.yml) · [Release checks](docs/verification.md)

Bug reports should include the macOS version and steps to reproduce. Remove private session titles, paths and credentials from attachments. For testing on another Mac, use the [first-install checklist](docs/first-install-check.md). Feature requests are welcome in [Issues](https://github.com/lovach/Lunavect/issues/new?template=feature.yml).

[Documentation](docs/README.md) · [FAQ](docs/faq.md) · [Security reports](SECURITY.md)

## License

[MIT](LICENSE) for original Lunavect code. Third-party software and artwork are covered separately in [NOTICE](NOTICE). Lunavect is independent of Anthropic and OpenAI.

</div>
