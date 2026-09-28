import Foundation

/// Real Claude Code 2.1.280 screens captured on 2026-09-28 with the exact probe
/// command (`--safe-mode --ax-screen-reader ... /usage`), PTY bytes unchanged
/// except for a private working-folder path replaced with a neutral one.
enum ClaudeUsageScreenFixtures {
    /// The CLI without a subscription sign-in (captured where it could not reach
    /// the keychain) shows the session cost panel instead of subscription limits.
    static let apiBilling = "[Screen Reader Mode: on via flag]\r\n\u{1B}7\u{1B}[r\u{1B}8\u{1B}[?25h\u{1B}[?2004h\u{1B}[?2031h\u{1B}[?1004h\u{1B}[>0q\u{1B}[?u\u{1B}[c\u{1B}[GClaude Code v2.1.280\r\nOpus 5.5 (1M context) · API Usage Billing\r\n~/Library/Application Support/Weekleft/QuotaProbe\r\nwarning: Safe mode: all customizations are disabled (CLAUDE.md, skills, plugins, hooks, MCP, agents, and more)\r\nRestart without --safe-mode to re-enable\r\nyou: /usage\r\nSettings  Status   Config   Usage   Stats\r\nSession\r\nTotal cost:            $0.0000\r\nTotal duration (API):  0s\r\nTotal duration (wall): 0s\r\nTotal code changes:    0 lines added, 0 lines removed\r\nUsage:                 0 input, 0 output, 0 cache read, 0 cache write\r\nEsc to cancel\u{1B}[29G\u{1B}[7A"
    /// First launch in a folder that Claude Code does not trust yet.
    static let untrustedFolder = "[Screen Reader Mode: on via flag]\r\n\u{1B}7\u{1B}[r\u{1B}8\u{1B}[?25h\u{1B}[?2004h\u{1B}[?2031h\u{1B}[?1004h\u{1B}[>0q\u{1B}[?u\u{1B}[c\u{1B}[GPermission Required: Accessing workspace:\r\n/Users/example/Library/Application Support/Weekleft/QuotaProbe\r\nQuick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take\r\n a moment to review what's in this folder first.\r\nClaude Code'll be able to read, edit, and execute files here.\r\nSecurity guide\r\ny. Yes, I trust this folder\r\nn. No, exit\r\nEnter y/n:\r\nEnter to confirm · Esc to cancel\u{1B}[12G\u{1B}[1A"
    // TODO(real-subscription-capture): the subscription `/usage` screen of the
    // current CLI has not been captured yet (owner's manual step, ПЛАН.md §5 п.3).
    // Put it here as `subscription` and enable
    // ClaudeUsageScreenTests.testRealSubscriptionScreenFixture. The synthetic
    // screens in ClaudeUsageProbeTests stay until then.
    static let subscription: String? = nil
    /// When `subscription` was captured: resets on the screen are read relative to it.
    static let subscriptionCapturedAt: Date? = nil
}
