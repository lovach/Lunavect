#!/usr/bin/env python3
"""Check that an app bundle embeds the headless hook and can invoke it."""
import pathlib
import subprocess
import sys

helper = pathlib.Path(sys.argv[1]) / 'Contents/Helpers/LunavectHook'
if not helper.is_file():
    raise SystemExit('Missing embedded LunavectHook')
libraries = subprocess.check_output(['/usr/bin/otool', '-L', str(helper)], text=True)
for framework in ('AppKit.framework', 'SwiftUI.framework', 'Sparkle.framework'):
    if framework in libraries:
        raise SystemExit(f'Hook unexpectedly links {framework}')
for provider in ('claude', 'codex'):
    # Deliberately no session ID: startup smoke test writes no user data.
    result = subprocess.run([str(helper), '--session-hook', provider], input='{}', text=True,
                            capture_output=True, timeout=5, check=True)
    if result.stdout.strip() != '{}':
        raise SystemExit(f'Unexpected {provider} hook response')
print('Verified headless hook: no GUI frameworks, Claude/Codex entry points respond')
