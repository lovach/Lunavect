# Keep Awake with the lid closed

Open the eye button in the session panel. A privileged macOS helper disables system sleep, including lid-triggered sleep. It also blocks manual sleep while active. Do not put an awake Mac in a bag.

Choose a duration and turn on the switch, or enable **Automatically while sessions work**. Automatic mode follows confirmed working sessions from connected providers, including hidden sessions. Waiting for input, approval, finished and unknown states do not count as working. When work stops, a one-minute grace period avoids switching sleep on and off between short tasks. Change that delay in **Settings → Keep Awake** to immediate, 30 seconds, one minute, two minutes or five minutes. New work cancels the countdown. Switching modes preserves the saved manual duration.

The automatic preference persists across launches. It never grants macOS permission by itself. While it waits for approval, it re-reads the approval at most every five seconds; opening the panel and **Allow and turn on** read it at once. After a failure or a stop condition, automatic mode shows **Paused, retrying in 5 minutes** with the reason. It does not retry in a loop: it tries again once five minutes later, or at once when the stop conditions are changed; **Retry connection** retries immediately. Turn off the main switch to disarm automatic mode as well.

## Permission and recovery

Initial setup uses **Allow and turn on** and the macOS background-item approval flow. Lunavect reports the mode as active only after the signed helper confirms it. App and helper authenticate each other's signing identity.

An app update can invalidate macOS's reference to the previous helper executable. On the first launch of a new build, Lunavect refreshes the service registration, even when Keep Awake is off. If that refresh fails, the Keep Awake panel says so and offers **Renew registration**. If macOS refuses again, the panel offers **Copy command** (the `--unregister-awake-helper` command of this installation, see [removal](updates.md#complete-removal)) and **Login Items**, where Lunavect can be turned off and on under **Allow in the Background**. Renewal failures are logged under subsystem `com.weekleft.app`, category `awake`.

A registered helper that launchd cannot start still accepts messages and never answers. Before the first lease in a new build, Lunavect therefore pings the helper for up to three seconds. No answer, or a second lease request in a row without an answer, renews the registration once per launch. If the helper still does not answer, the panel says that macOS does not start it instead of retrying the same path. A single slow answer keeps the registration. A refused connection renews it once per launch; a later refusal is reported without another renewal. If macOS refuses the renewal while Keep Awake is being turned on, the panel offers **Copy command** and **Login Items** instead of retrying the connection. If Lunavect quits between removing and re-adding the registration, the next launch completes it. Pending permission and invalid signatures are not bypassed.

### When the helper does not start

Symptom: Keep Awake reports that the helper is not responding or that macOS does not start it, and `launchctl print system/com.weekleft.awake-helper` shows `job state = spawn failed`, a growing `runs` count or `last exit code = 78: EX_CONFIG`. The system log then repeats `Could not find and/or execute program specified by service`. This happens when the background-item record still points at a previous build or signing team. Repair: quit Lunavect, run the installed app's command below, confirm that `launchctl print` reports the service as absent, then open Lunavect and choose **Allow and turn on**.

```sh
"$HOME/Applications/Lunavect.app/Contents/MacOS/Lunavect" --unregister-awake-helper
launchctl print system/com.weekleft.awake-helper
```

Use `/Applications/Lunavect.app` for a system installation. If unregistering is refused, turn Lunavect off in System Settings → General → Login Items & Extensions → Allow in the Background, then on again.

By default, battery charge at 10% or below on battery power, or serious thermal pressure, stops the mode. **Settings → Keep Awake → Stop conditions** exposes independent battery and thermal switches, a battery threshold from 5% to 50%, and whether battery operation is allowed. The current policy is sent to the authenticated helper. Changes apply to an active mode immediately; a newly triggered stop is shown in the panel and does not cause an automatic restart loop; automatic mode retries after five minutes. Disabling these optional conditions affects Lunavect only; it does not alter macOS thermal protections.

The helper owns a 30-second lease renewed every ten seconds. A lost app connection releases it; lease expiry and the next five-second check provide a fallback. A root-owned recovery marker lets a restarted helper restore normal sleep after a crash. Failed restoration is retried by the running helper every five seconds; it does not exit while restoration is pending. These connection and recovery rules cannot be disabled in preferences.

launchd starts the helper in two cases only: at system start (`RunAtLoad`, to finish an interrupted recovery) and on demand when Lunavect connects to its Mach service. Since 0.2.5 the daemon definition has no `KeepAlive` rule. With it, any permanent failure, such as a program missing from the registered path, made launchd try again every 30 seconds indefinitely. A helper that cannot start logs the reason (category `awake`) and exits normally. If a heartbeat or stop gets no answer at all, Lunavect connects once more: launchd starts a new helper instance, which restores sleep from the recovery marker a crashed instance left behind. If both the helper and Lunavect stop at the same time, restoration happens at the next Lunavect launch that uses Keep Awake or at the next system start. A registration renewal (first launch of a new build, **Renew registration**, or the removal command) that finds sleep still disabled first connects once to the helper, whose start restores sleep from the recovery marker; it unregisters nothing while sleep stays disabled.

The helper checks the system sleep setting at most every 30 seconds during ordinary operation, rather than launching `pmset` for every heartbeat. It exits after a minute without a lease or pending recovery and starts on demand. Initial startup still checks for interrupted recovery. The `pmset -g` reading accepts output with or without a system-wide section and treats a malformed `SleepDisabled` line as an error, never as sleep being enabled.

### Updating from a build with the older daemon definition

An installed helper keeps the definition it was registered with. The first launch of the new build renews the registration (see above), and launchd then loads the definition without `KeepAlive`. To confirm after installing:

1. Quit and open Lunavect once; the Keep Awake panel shows no registration error.
2. `launchctl print system/com.weekleft.awake-helper` shows the installed build as `parent bundle version`, and `runs` no longer grows every 30 seconds. While no lease is active the job may be `not running`. The exact wording of keep-alive conditions in that output depends on the macOS version; the definition inside the app is `Contents/Library/LaunchDaemons/com.weekleft.awake-helper.plist`.
3. `log show --last 10m --predicate 'process == "launchd" AND eventMessage CONTAINS "com.weekleft.awake-helper"'` shows no repeated spawn failures.
4. Turn on Keep Awake for 15 minutes: `pmset -g | grep SleepDisabled` shows `1`; turn it off and it shows `0` (or no line).

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
