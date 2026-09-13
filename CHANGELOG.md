# Changelog

## 0.1.2 — 2026-09-13

- Recognize explicit closing decision questions from Claude as awaiting input and include them in the waiting count.
- Preserve inferred questions across idle session polls until new work, a terminal state or the existing freshness limit supersedes them.
- Inspect the supported local Stop payload without saving the assistant response text. Recognition is conservative and may miss other wording.

## 0.1.1 — 2026-09-13

- Stable session ordering while the panel is open, consistent waiting counts and clearer navigation through long lists.
- More reliable Codex desktop session discovery and activity recovery, including supported CLI launchers.
- Compact menu-bar limits with icons and percentages, plus configurable countdowns and provider colors.
- Widget backdrop transparency from 0–100%, with removable backgrounds and optional native glass material.
- Clearer activity widgets with full duration values, persistent period context and compact overview limits.
- More space and intermediate scale labels for the overview chart; manual subscription dates stay in Settings.
- Empty Claude lifecycle-only launches stay out of session lists until actual task activity starts.
- Settings that preserve existing choices during upgrades, keep Lunavect in the menu bar and return directly to sessions.
- Safer data persistence, local history recovery and Keep Awake helper lifecycle, with expanded regression checks.


## 0.1.0 — First public release

- macOS menu-bar session overview for Claude Code and Codex, with one-client or two-client setup.
- Weekly and available five-hour usage allowances, reset times, and optional Claude model limits.
- Local activity statistics and WidgetKit limits, activity, and overview widgets.
- Session navigation, reordering, hiding, automatic return on new work, and optional idle hiding.
- Optional completion notifications, animated companions, and six interface languages.
- Developer ID distribution and signed GitHub update feeds.

### Known limits

Other Macs, subscription plans, and client versions still need validation. Widget refresh is controlled by macOS. Transparent widget backgrounds and closed-lid keep-awake are experimental. See docs/verification.md for the current evidence and remaining checks.
