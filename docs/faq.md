# Frequently asked questions

## Is Lunavect free?

Yes. Lunavect is free and open source. It does not include a Claude or Codex subscription, buy credits, or increase your provider's limits. You use your own official client and account.

## Can I use only Claude or only Codex?

Yes. Connect either provider or both in **Settings → Connections**. Only the client you connect is required.

## Is Claude Desktop enough?

No. The Claude integration requires **Claude Code CLI**. Lunavect uses Claude Code's own usage output and status-line data for allowances. Desktop metadata can help identify sessions, but does not replace the CLI requirement. The connection guide can help install the CLI.

## Which Codex client do I need?

Use the official Codex client. Lunavect can discover the CLI, including the copy bundled with Codex for macOS, and uses its local app-server for usage data. Session detection and navigation depend on the originating client and the events it exposes. See [connections](connections.md) and [compatibility notes](verification.md).

## Do I need an API key or another login?

Lunavect does not ask you to paste an API key or create a Lunavect account. It reuses the official client's sign-in. If sign-in is needed, the connection guide opens the client's own login flow. Available limits depend on your account and the data that client exposes; not every account mode provides weekly and five-hour allowances.

## Why is a usage limit unavailable?

Installation, sign-in, event handlers and fresh quota data are separate checks. Open **Settings → Connections**, select the affected provider and follow its diagnostic action. For Claude, the guide may ask you to complete the first `/usage` launch. For Codex, approve new Lunavect event handlers through `/hooks` if requested.

Missing or expired data is not interpreted as an unlimited account. Compare a value's timestamp and reset time with the official client before reporting a mismatch.

## Why is a session missing or no longer working?

Check the provider filter, **Active** filter, search and **Hidden sessions**. A title in a saved catalog does not prove that a task is running. Lunavect needs a current state from client events or another available source. Check connection diagnostics if new tasks never appear.

Hiding a row only changes its visibility in Lunavect. It does not cancel the task or delete the conversation. See [session states and controls](sessions.md).

## Does activity mean tokens, CPU time or billable usage?

No. It measures intervals when sessions are observed working. Waiting for permission or input is not counted as observed work. History recovered from client logs is marked `≈` because it can be approximate and may include waiting.

Two providers can work at the same time. Their individual durations may add up to more than the combined duration, which counts overlapping time once. See [how activity is counted](activity.md).

## Why does a desktop widget update later than the app?

The app saves data and requests a refresh, but macOS schedules WidgetKit updates. The widget does not poll your accounts itself. Keep Lunavect running to collect new activity and usage data, and check the source timestamp when a value looks old.

## How do I add or change a widget?

Right-click the desktop, choose **Edit Widgets**, search for **Lunavect** and select a size. To change an activity widget's period or source, right-click the placed widget and choose **Edit Widget**. Changing the preview in Lunavect does not change an already placed widget. See [installation](installation.md#add-a-desktop-widget).

## What leaves my Mac?

Lunavect does not upload session titles, project paths or activity history to its developer. Updates use GitHub; installation, sign-in and quota refreshes use the official clients and their services. See [Privacy and permissions](../PRIVACY.md) for local files, configuration changes, network requests and deletion.

## Does it work on Intel Macs?

The download includes Apple silicon and Intel code and requires macOS 14 or later. The public release has been exercised on Apple silicon; Intel hardware and every supported macOS version have not been verified. The [compatibility page](verification.md) records what has actually been checked.

## How do I update or uninstall it?

Use **Settings → Updates** or the [Homebrew update commands](installation.md#update). Before uninstalling, disconnect providers and quit Lunavect. Removing the app retains its preferences and history; [Privacy and permissions](../PRIVACY.md#disconnecting-and-deleting-data) explains how to remove those separately.

## Where should I report a problem?

Use the [bug report form](https://github.com/lovach/Lunavect/issues/new?template=bug.yml). Include the Lunavect and macOS versions, Mac architecture, client version and steps to reproduce. Remove private data from attachments. Send security findings through the [private reporting route](../SECURITY.md).

[Back to README](../README.md) · [Installation](installation.md)
