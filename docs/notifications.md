# Notifications and sounds

**Settings → Notifications** has independent switches for banners and sounds. Both are off on a new installation. Sound-only mode does not request notification permission. Choose which events to announce: response ready, approval needed, input needed, errors and limits. These choices remain editable when both channels are off.

Completion uses **Lunavect · Lift**, an original 0.46-second rising tone with a soft onset and a short glass-like decay. **Play sound** previews it without changing notification settings. Approval and input events use the system attention sound. If banners are enabled, clicking a notification opens its session without waiting for a list refresh; if the session is no longer listed, the session panel explains why.

Notifications follow newly observed state transitions. A Claude reply that ends while Claude's own background tasks are still running is not announced: the notification arrives once, after the last task has finished and Claude has stopped with nothing left to wait for (see [Background tasks in Claude](sessions.md#background-tasks-in-claude)). Re-reading the same state does not replay a sound, and the initial session list does not generate historical completion alerts. macOS notification settings can independently silence banner sounds.

When several sessions finish close together, the completion sound plays at most once every five seconds by default. **Pause between completion sounds** offers no pause, 2, 5, 10 or 30 seconds. Each enabled banner still appears and opens its own session. Notification Center keeps one entry per session: a newer state, such as the reply after an approval request, replaces the session's earlier banner. Limit notices and test notifications remain separate entries. The same limit applies in sound-only mode and when a failed banner falls back to direct audio. Approval and input sounds are not suppressed by this completion cooldown. Explicit sound previews and test notifications play immediately.

The completion cue is synthesized from oscillators and short reflections, without sampled recordings or external dependencies, by `scripts/generate-notification-sound.py`. Its source and WAV asset use the project's MIT license. The WAV is bundled with the app for both notification banners and direct sound-only playback.

## Errors

When a Claude Code turn ends with an API error, the row names the reason and **Errors** sends one notification: **Limit reached** (with the time it is available again when Lunavect knows the exhausted window), **Can't reach Claude**, **Claude service error**, **Sign in again**, **Account issue** or **Error**. The reason comes from the documented [`StopFailure.error` field](https://code.claude.com/docs/en/hooks#stopfailure-input); a server error counts as a lost connection when its message says so. Only the reason is stored, never the error text. Codex does not report such an event.

## Limits

**Limits** warns once when a five-hour or weekly allowance of Claude or Codex drops below the chosen level (5, 10, 20 or 25%, 10% by default) and announces its return at the reset time, but only for a window that was low. Warnings use fresh values only: saved values, values older than 15 minutes and values reported with a source error never cross the threshold. A relaunch does not repeat a warning for the same window. A return is announced when the reset passes, or on wake or relaunch up to an hour later; older returns are not announced. Warnings are not used up while limit notifications are off, and a disconnected provider is never announced. When a reached limit is announced with an error, the time shown is when every exhausted window has reset, taken from fresh values only.
