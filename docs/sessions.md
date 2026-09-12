# Sessions

Click Lunavect in the macOS menu bar to open the session panel. It brings Claude Code and Codex tasks into one list, with a title, project and the latest available state. Settings open separately from the panel.

## Reading a session

| State | Meaning |
| --- | --- |
| Working / Thinking / tool name | A source currently reports work. The timer belongs to the current response, not the session's total lifetime. |
| Permission needed | The client is waiting for approval. Return to the client to respond. |
| Input needed | The client is waiting for input. |
| Response ready | A response finished; the session may still be open in its client. |
| Idle | A session is open without confirmed current work. |
| Unknown or stale | Lunavect does not have a sufficiently current state. This is not treated as working or finished. |

The working and awaiting-input counters summarize current states. A saved title, recent file read or an old catalog entry does not turn a task into a live session. The decorative menu-bar phrases describe an animation state, not a tool the agent has actually called.

## Find and arrange sessions

Use search to find a title or project. **All**, **Claude** and **Codex** select providers; **Active** narrows the list to active states. The row menu contains the available actions for that session, including pinning, hiding, opening a project and copying a resume command. Drag rows to change their order.

Open **Hidden sessions** to review and restore hidden rows. Hiding affects Lunavect's list only: it does not cancel work or delete a conversation. A hidden session that is still working can continue to contribute to activity totals.

Optional automatic hiding is configured in Settings. It applies to inactive sessions after the selected interval; it does not hide working, waiting or unknown states just because an event is old. A new installation leaves automatic hiding off.

## Return to a task

Click a row or use its open action. Lunavect uses the originating client when it can identify one. Terminal sessions need the CLI and project folder to remain available; their resume command is opened through Terminal. Other clients depend on the navigation route that client supports.

Opening an application is not always the same as returning to the exact conversation. If the client is missing, the project was moved or the route is unsupported, use the row's project or resume action when available. Include the client and its version in reports about navigation problems.

## How state is determined

Lunavect combines local lifecycle hooks, available client runtime information and session metadata. Claude Desktop metadata can supply a title for an existing Claude Code session. Codex can use a local log-based fallback when shared runtime information is unavailable. Compatibility with other local status-bar records is optional and does not modify their event handlers.

Titles and project metadata are kept separate from activity evidence. Re-reading an event does not change its timestamp. Old events eventually lose authority, and late events from a completed turn should not restart its working indicator. An empty Claude startup/shutdown cycle is not presented as a completed task.

The panel updates timers while visible. Closing it stops its display timer, while background collection can continue. Freshness depends on the source; long work, sleep/wake and changes in client formats can affect what Lunavect can confirm.

## If the list looks wrong

1. Clear search and filters, then check **Hidden sessions**.
2. Open **Settings → Connections** and inspect the affected provider.
3. Check handler approval if requested, then run a new task in the official client.
4. If the problem remains, [report it](https://github.com/lovach/Lunavect/issues/new?template=bug.yml) with the expected and actual state and steps to reproduce.

Do not attach private conversations or unredacted session records. Full lifecycle and exact-session navigation coverage across clients remains incomplete; see [verification](verification.md).

[Connections](connections.md) · [Activity](activity.md) · [Privacy](../PRIVACY.md)
