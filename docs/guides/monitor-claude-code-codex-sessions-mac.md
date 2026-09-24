# Monitor multiple Claude Code and Codex sessions on a Mac

Running several AI coding agents at once is fast until you lose track of them: which one is still working, which one waits for your approval, which one failed an hour ago. The terminal tab title and `claude agents` tell part of the story, one window at a time.

[Lunavect](https://lovach.github.io/Lunavect/) puts every Claude Code and Codex session on your Mac in one menu bar panel:

- **Live state for every session:** working, thinking, running a tool, in background with a count of its background tasks, waiting for permission or input, response ready, failed with a reason, or no network.
- **Counts in the menu bar:** for example "Busy 8 · Waiting 1", so you see at a glance whether anything needs you.
- **One click to the session:** Terminal and iTerm2 sessions open in their own tab; Desktop sessions open in their client.
- **Search, filters, pin and hide:** find a task by title or project, show only sessions waiting for you, keep important ones on top.
- **Keep Awake while agents work:** optional, so a long run is not stopped by sleep.
- **Usage limits and activity:** weekly and five-hour allowances for both providers, and working time by day, week and month.

![Lunavect session panel listing Claude Code and Codex sessions with their live states](../images/readme-sessions-light.png)

Everything stays local: Lunavect reads the official clients' local data and event handlers, with no account, API key or backend.

[Download Lunavect](https://github.com/lovach/Lunavect/releases/latest) · [Sessions](../sessions.md) · [Keep Awake](../keep-awake.md) · [FAQ](../faq.md)

## Common questions

**Does it work with Claude Code in any terminal?** Sessions from any terminal appear; opening a session's own tab is supported for Terminal and iTerm2.

**Are internal agents counted as sessions?** No. Codex's internal subagents and memory agent, and Claude runtimes started by another agent, stay out of the list and counts. Claude's own background tasks are shown as a count on their session.
