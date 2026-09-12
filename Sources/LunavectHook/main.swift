import Foundation
#if SWIFT_PACKAGE
import WeekleftCore
#endif

// A headless entry point: no AppKit, SwiftUI, Sparkle, app lifecycle or windows.
if let index = CommandLine.arguments.firstIndex(of: "--session-hook"),
   CommandLine.arguments.indices.contains(index + 1),
   let provider = ProviderID(rawValue: CommandLine.arguments[index + 1]) {
    SessionHooks.captureFromStandardInput(provider: provider)
} else if CommandLine.arguments.contains("--claude-statusline") {
    ClaudeProvider.runStatusLine()
} else {
    fputs("LunavectHook: expected --session-hook claude|codex or --claude-statusline\n", stderr)
    exit(64)
}
