# How to check Codex usage limits on a Mac

Codex with a ChatGPT plan has a **five-hour limit** and a **weekly limit**, each with its own reset time. To see them:

1. **In the Codex CLI:** run `/status` in an active session. It shows the five-hour and weekly limits with their reset times.
2. **In your ChatGPT account:** the Codex usage dashboard shows the same limits.
3. **In your Mac menu bar, all the time:** [Lunavect](https://lovach.github.io/Lunavect/) shows how much of both Codex limits is left, next to your Claude Code limits and running sessions.

## Keep Codex limits in view with Lunavect

Lunavect is a free, open-source menu bar app for Codex and Claude Code. After you connect Codex, it asks the official Codex app or CLI on your Mac for the current rate limits; sign-in stays with Codex.

- **Menu bar:** Codex and Claude allowances side by side as bars, percentages or rings, with reset countdowns.
- **Alerts:** one notification when a five-hour or weekly allowance drops below the level you choose, and one when it returns.
- **Widgets:** limits and activity on your desktop in small, medium and large sizes.
- **Sessions:** every Codex task with its live state — working, waiting for permission or input, or done.

![Lunavect in the menu bar showing Claude 68% and Codex 54% of weekly usage left](../images/menu-bar.png)

[Download Lunavect](https://github.com/lovach/Lunavect/releases/latest) · [Installation](../installation.md) · [Connections](../connections.md)

## Common questions

**Does Lunavect need an OpenAI API key?** No. It uses the official Codex client that is already signed in on your Mac.

**Why is a Codex limit shown as unavailable?** Lunavect shows only fresh values from the client. If Codex is not running or cannot answer, the value is marked as unavailable instead of guessed. See [connections](../connections.md).

**Can I use only Codex?** Yes. Connect Codex, Claude Code or both.
