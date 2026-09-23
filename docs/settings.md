# Settings and first launch

Settings are grouped into Overview (Limits and Statistics), Application (General, Connections, Notifications and Keep Awake), Appearance (Menu Bar and Widgets), and Data (Subscriptions). Updates has a separate entry at the bottom of the sidebar. Values save automatically. Optional features can be configured before enabling them.

## First-launch defaults

| Feature | Default |
| --- | --- |
| Language and theme | Follow the system |
| Menu bar | Lunavect icon and session summary; decorative thinking phrases off |
| Menu bar limits | Off; weekly bars and percentages when enabled, no reset countdown |
| Notifications | Banners and sounds off; completion, approval and input events selected for later use |
| Completion sound | Lunavect Lift; at most once every five seconds |
| Launch at login and shortcut | Off; no shortcut assigned |
| Keep Awake | Off; manual duration 15 minutes; automatic mode off |
| Automatic-mode delay | One minute after confirmed work stops |
| Keep Awake stop conditions | Battery operation allowed; stop at 10% or below on battery, and at serious thermal pressure |
| Sessions | Automatic hiding off |
| Widgets | Standard background; five-hour quota off; no subscription dates invented |
| Updates | Automatic checks on; automatic downloads off |

These defaults apply once to a new installation. An update preserves existing choices and the earlier fallback behavior for unset preferences. Existing installations keep their previous manual Keep Awake duration behavior until a duration is saved. Connecting a provider or granting a macOS permission remains a separate user action.

<p align="center"><img src="images/limits.png" width="720" alt="Limits settings with weekly and five-hour allowances and reset times for Claude and Codex"></p>

## Available controls

- **Limits:** remaining weekly and optional five-hour allowances, reset times, model-specific quotas when supplied, and connection status. The five-hour switch is shared with widgets.
- **Statistics:** hourly, weekly and monthly activity, source selection, project/session details and import history. The line joins recorded points; missing values between them remain unknown.
- **General:** language, theme, launch at login, panel shortcut and when to hide finished sessions.
- **Connections:** enabled providers, their local bridges and connection diagnostics.
- **Notifications:** independent banners and sound; completion, approval and input events; completion sound preview; a pause of 0, 2, 5, 10 or 30 seconds between completion sounds. Events stay editable when both channels are off.
- **Keep Awake:** manual duration, automatic operation during work, a delay of 0, 30, 60, 120 or 300 seconds after work stops, battery operation, a 5–50% battery threshold and independent battery/thermal stopping switches. See [Keep Awake](keep-awake.md).
- **Menu Bar:** separate limits and session-status switches, quota window, provider, style, colors, reset countdown, character, automatic character selection, animation and status text.
- **Widgets:** quota display, **Glass background** and backdrop transparency. The slider spans 0–100%: 0% is an opaque backdrop, 100% removes Lunavect’s tint while retaining the system material. Saved numeric values are preserved. macOS controls the blur and wallpaper tint, and accessibility settings can force an opaque background. The decorative background belongs to WidgetKit’s removable container. The optional compatibility layer requests native material only for Lunavect’s widget kinds and falls back unchanged on an unsupported runtime; desktop appearance requires verification on each supported macOS version. The content, size, period and provider of a placed widget are selected through macOS's widget controls; the in-app preview does not change a placed widget.
- **Subscriptions:** manually supplied subscription dates.
- **Updates:** checking and downloading are separate choices. Downloads enable checking; disabling checks also disables automatic downloads. Manual checks remain available.

## Navigation and reversible actions

Opening the session panel or the four-step guide keeps Settings open. Lunavect stays a menu-bar utility while Settings or the guide is open, without adding an application icon to the Dock or application switcher. Reopen its windows from the menu-bar icon. Approving Keep Awake returns to the surface that requested permission. Sidebar buttons support Up and Down arrow navigation when focused.

The explicit **Back to sessions** button closes Settings and then opens the session panel after the window closes. Other open Lunavect windows stay open. Closing Settings with the red window button closes only that window; Lunavect continues running in the menu bar. To quit the app completely, use **Command-Q** or **Quit** in the menu bar icon's context menu.

While the session panel is open, existing rows keep their order as statuses and timers change. New sessions append at the end. Explicit pinning or moving still takes effect immediately; reopening uses the current saved/default order. The waiting count is a plain text filter with no checkbox or surrounding border.

The session viewport fits a whole number of rows at its top and bottom scroll limits. When more rows exist, a compact arrow and count show how many continue below; activating it reveals the next rows. At the bottom it offers a return upward. Background updates never request scrolling; keyboard focus changes, explicit moves and the paging button do.

**Hide in Lunavect** only hides a session in this app. Hidden entries can be restored; deleting a saved hidden entry is a separate action with confirmation. Disconnecting a provider or its event handlers keeps saved data, removes Lunavect’s integration and restores the previous Claude status line. The result offers **Reconnect**. The Codex executable picker stores only an explicit user choice; automatic discovery remains automatic.

## Restore defaults

**General → Restore default settings** previews the scope and asks before applying it. The confirmation states that language and theme return to the system setting. It also resets menu-bar and widget appearance, notification and sound choices, the panel shortcut, launch at login, Keep Awake, session auto-hide and update preferences. Active Keep Awake is stopped, including a pending permission follow-up.

Connections, source configuration, activity history, hidden sessions, their arrangement and subscription dates are retained. The operation does not delete account data or revoke macOS permissions, and it does not replay onboarding.

The profile is defined in `AppDefaultSettings`; preference owners apply resets through their normal setters so visible UI, registered shortcuts and the helper agree with saved values. Tests use isolated preference domains and a fake helper for defaults, upgrades, reset behavior and configured stop conditions.

## Menu-bar appearance

<p align="center"><img src="images/settings-menu-bar.png" width="720" alt="Menu Bar settings with the character choices and session status"></p>

Session status, icon appearance and usage limits are separate visible groups. The character cards remain visible in automatic mode; selecting one switches to manual selection. Short choice rows align labels and controls on one line, and longer labels wrap at smaller window sizes.

Playful activity phrases are available in all three status styles. Each phrase lasts for two full cycles of animated dots, then the next phrase restarts at one dot. Requests for input or approval always take priority. See [thinking phrases](thinking-phrases.md) and [verification](verification.md) for behavior and testing limits.
