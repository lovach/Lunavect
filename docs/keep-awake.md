# Keep Awake with the lid closed

Open the eye button in the session panel. A privileged macOS helper disables system sleep, including lid-triggered sleep. It also blocks manual sleep while active. Do not put an awake Mac in a bag.

Choose a duration and turn on the switch, or enable **Automatically while sessions work**. Automatic mode follows confirmed working sessions from connected providers, including hidden sessions. Waiting for input, approval, finished and unknown states do not count as working. When work stops, a one-minute grace period avoids switching sleep on and off between short tasks. Change that delay in **Settings → Keep Awake** to immediate, 30 seconds, one minute, two minutes or five minutes. New work cancels the countdown. Switching modes preserves the saved manual duration.

The automatic preference persists across launches. It never grants macOS permission by itself. After a failure or a stop condition, automatic mode shows **Paused, retrying in 5 minutes** with the reason. It does not retry in a loop: it tries again once five minutes later, or at once when the stop conditions are changed; **Retry connection** retries immediately. Turn off the main switch to disarm automatic mode as well.

## Permission and recovery

Initial setup uses **Allow and turn on** and the macOS background-item approval flow. Lunavect reports the mode as active only after the signed helper confirms it. App and helper authenticate each other's signing identity.

An app update can invalidate macOS's reference to the previous helper executable. Before first use in a new build, Lunavect refreshes the service registration. If an already-approved helper cannot be reached, it retries registration once; a helper that is only slow to answer is reported as not responding and keeps its registration. If Lunavect quits between removing and re-adding the registration, the next launch completes it. Pending permission and invalid signatures are not bypassed.

By default, battery charge at 10% or below on battery power, or serious thermal pressure, stops the mode. **Settings → Keep Awake → Stop conditions** exposes independent battery and thermal switches, a battery threshold from 5% to 50%, and whether battery operation is allowed. The current policy is sent to the authenticated helper. Changes apply to an active mode immediately; a newly triggered stop is shown in the panel and does not cause an automatic restart loop; automatic mode retries after five minutes. Disabling these optional conditions affects Lunavect only; it does not alter macOS thermal protections.

The helper owns a 30-second lease renewed every ten seconds. A lost app connection releases it; lease expiry and the next five-second check provide a fallback. A root-owned recovery marker lets a restarted helper restore normal sleep after a crash. Failed restoration is retried. These connection and recovery rules cannot be disabled in preferences.

The helper checks the system sleep setting at most every 30 seconds during ordinary operation, rather than launching `pmset` for every heartbeat. It exits after a minute without a lease or pending recovery and starts on demand. Initial startup still checks for interrupted recovery.

## Verification boundary

Installed development build 128 was physically checked on September 12, 2026, on a Mac16,5 running macOS 26.5.2 (25F84), without an external display. The manual 15-minute mode was used.

| Check | Observed result |
| --- | --- |
| Lid closed on AC power | Stayed awake for approximately 2 minutes 10 seconds. |
| AC disconnected, then lid closed on battery | Stayed awake for approximately 2 minutes 40 seconds at 87% charge. |
| Keep Awake switched off | `SleepDisabled` returned to `0`. Closing the lid caused a recorded 36-second **Clamshell Sleep**, followed by wake on opening. |
| Helper after switching off | Exited normally with status `0` after its idle interval. |

A local read-only monitor sampled the hardware lid state, power source, sleep setting and thermal state every two seconds. It created no power assertion. During both enabled tests, `SleepDisabled` remained set, thermal state was nominal, and the longest sampling interval was 2.008 seconds. The system power log recorded no sleep during those intervals. With the mode off, both the system log and the monitor recorded sleep and wake, with the expected pause in sampling. That physical-test recording was stopped after verification.

A subsequent automatic-mode check on the same installed build used a real Codex session, with the lid open. The panel confirmed **While sessions work**, and the monitor recorded `SleepDisabled = 1` at 15:10:45 UTC. After that session turn finished, the setting returned to `0` at 15:12:27 UTC. This verifies release of the sleep override after completion; it does not independently measure the exact grace period from the session's completion timestamp. At cleanup, the panel showed both Keep Awake and automatic mode off, without a helper error, and the diagnostic monitor was stopped.

Earlier installed development build 124 checks covered restoration after the app connection was lost. Unit tests cover the automatic idle grace period, permission failures, lease expiry and restoration. The build 128 physical tests do not establish prolonged closed-lid operation, low-battery or thermal shutdown, disconnecting power while the lid is already closed, or behavior on other Macs. Closed-lid automatic completion and crash/relaunch coverage remain separate checks.
