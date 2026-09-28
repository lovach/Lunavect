#!/usr/bin/env python3
"""Check that an app bundle embeds the headless hook and can invoke it.

Client settings name the helper through a stable link in Lunavect's support
folder (~/Library/Application Support/Weekleft/bin/LunavectHook), and Claude
Code and Codex run that command with /bin/sh. The check therefore also runs the
helper through a temporary link whose path has spaces and an apostrophe, quoted
exactly as the app writes it. It never touches the real link or user data.
"""
import pathlib
import shlex
import subprocess
import sys
import tempfile


def respond(command, provider):
    # Deliberately no session ID: startup smoke test writes no user data.
    result = subprocess.run(['/bin/sh', '-c', command], input='{}', text=True,
                            capture_output=True, timeout=5, check=True)
    if result.stdout.strip() != '{}':
        raise SystemExit(f'Unexpected {provider} hook response')


def check_invocations(helper):
    helper = pathlib.Path(helper).resolve()
    with tempfile.TemporaryDirectory(prefix='lunavect-hook-') as temporary:
        link = pathlib.Path(temporary) / "Application Support/Wet Dog's bin/LunavectHook"
        link.parent.mkdir(parents=True)
        link.symlink_to(helper)
        for provider in ('claude', 'codex'):
            respond(shlex.quote(str(helper)) + f' --session-hook {provider}', provider)
            # The installed form: quoted stable link plus the ownership marker comment.
            respond(shlex.quote(str(link)) + f' --session-hook {provider} # lunavect-session-monitor:{provider}', provider)


def verify(app):
    helper = pathlib.Path(app) / 'Contents/Helpers/LunavectHook'
    if not helper.is_file():
        raise SystemExit('Missing embedded LunavectHook')
    libraries = subprocess.check_output(['/usr/bin/otool', '-L', str(helper)], text=True)
    for framework in ('AppKit.framework', 'SwiftUI.framework', 'Sparkle.framework'):
        if framework in libraries:
            raise SystemExit(f'Hook unexpectedly links {framework}')
    check_invocations(helper)


if __name__ == '__main__':
    verify(sys.argv[1])
    print('Verified headless hook: no GUI frameworks, Claude/Codex entry points respond, also through a quoted link')
