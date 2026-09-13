# Notifications and sounds

**Settings → Notifications** has independent switches for banners and sounds. Both are off on a new installation. Sound-only mode does not request notification permission. Choose which events to announce: response ready, approval needed or input needed. These choices remain editable when both channels are off.

Completion uses **Lunavect · Lift**, an original 0.46-second rising tone with a soft onset and a short glass-like decay. **Play sound** previews it without changing notification settings. Approval and input events use the system attention sound. If banners are enabled, clicking a notification opens its session.

Notifications follow newly observed state transitions. Re-reading the same state does not replay a sound, and the initial session list does not generate historical completion alerts. macOS notification settings can independently silence banner sounds.

When several sessions finish close together, the completion sound plays at most once every five seconds by default. **Pause between completion sounds** offers no pause, 2, 5, 10 or 30 seconds. Each enabled banner still appears and opens its own session. The same limit applies in sound-only mode and when a failed banner falls back to direct audio. Approval and input sounds are not suppressed by this completion cooldown. Explicit sound previews and test notifications play immediately.

The completion cue is synthesized from oscillators and short reflections, without sampled recordings or external dependencies, by `scripts/generate-notification-sound.py`. Its source and WAV asset use the project's MIT license. The WAV is bundled with the app for both notification banners and direct sound-only playback.
