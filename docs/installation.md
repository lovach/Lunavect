# Installing Lunavect

## Requirements

- macOS 14 Sonoma or later. The download includes Apple silicon and Intel code; the release has been tested on Apple silicon. Intel hardware and other supported macOS versions still need testing.
- Claude Code CLI for Claude usage and sessions. Claude Desktop alone is not enough.
- The official Codex client for Codex usage and sessions.

Only the client you choose to connect is required. Allowances depend on what that client exposes for your account.

## Homebrew

With [Homebrew](https://brew.sh/) installed:

```sh
brew tap lovach/lunavect https://github.com/lovach/Lunavect
brew install --cask lovach/lunavect/lunavect
open -a Lunavect
```

The cask downloads the signed release DMG and checks its SHA-256 checksum.

## Direct download

1. [Download the DMG](https://github.com/lovach/Lunavect/releases/download/v0.1.1/Lunavect-0.1.1.dmg), about 11 MB.
2. Open it and drag **Lunavect** to **Applications**.
3. Open Lunavect from Applications.

The app is Developer ID signed and notarized by Apple. The ZIP and `appcast.xml` on the release page are for the built-in updater. Choose the DMG for manual installation. Checksum files are included on the [Releases page](https://github.com/lovach/Lunavect/releases).

## Connect a client

Choose **Connect Claude** or **Connect Codex** in Lunavect. The guide checks the official client, offers installation when needed, and starts sign-in through that client. Before enabling the connection, it explains the local event handlers and Claude status-line changes.

You can connect either service or both. Existing authentication stays with the official clients. Lunavect does not ask you to paste provider passwords or API keys.

## Add a desktop widget

1. Right-click the desktop and choose **Edit Widgets**.
2. Search for **Lunavect** and choose a widget and size.
3. For an activity widget, right-click the placed widget and choose **Edit Widget** to set its source and time period.

macOS schedules widget refreshes. Native layouts have been inspected; placement and refresh of the release on the real desktop remain unverified. See the [compatibility notes](verification.md).

## Update

Use **Settings → Updates** in Lunavect to check for a release or manage automatic downloads.

For a Homebrew installation:

```sh
brew update
brew upgrade --cask lovach/lunavect/lunavect
```

## Uninstall

Disconnect Claude and Codex in **Settings → Connections**, then quit Lunavect. This lets Lunavect restore previous event handlers and the Claude status line before the app is removed.

For a Homebrew installation:

```sh
brew uninstall --cask lovach/lunavect/lunavect
```

For a direct installation, delete Lunavect from Applications. Settings and activity history are retained. See [connection removal](connections.md#disconnect) for more detail.

## Troubleshooting

- **A limit is unavailable:** open **Settings → Connections**. Check the selected client's status and follow its repair guidance. A successful sign-in does not guarantee that the client has supplied fresh allowances.
- **Sessions stop updating:** use the connection diagnostics to check event handlers. Session state depends on client events; reconnecting or repairing a service should be done through Settings.
- **A value looks stale:** check its timestamp. Missing or expired limits are not treated as unlimited usage.

If the problem remains, [report a bug](https://github.com/lovach/Lunavect/issues/new?template=bug.yml) with the app version, macOS version, Mac architecture and steps to reproduce. Remove private titles, paths and credentials from attachments.

[FAQ](faq.md) · [Privacy and data removal](../PRIVACY.md) · [Verified checks and open limitations](verification.md) · [Back to README](../README.md)
