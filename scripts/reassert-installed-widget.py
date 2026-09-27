#!/usr/bin/env python3
"""Reassert the installed Lunavect host and widget after a temporary copy was unregistered.

Unregistering a build product with the same bundle identifiers can invalidate the
containing-bundle lookup of the installed widget, leaving desktop widgets on
placeholders. This only re-registers an installed copy whose host and widget
identifiers and build numbers match; it never launches, replaces or edits it.

With copies in both ~/Applications and /Applications, WidgetKit can bind either.
Only the copy that is running is reasserted, and the other is never registered;
when neither runs, the documented order (~/Applications first) applies. Both
cases print a warning. LUNAVECT_LSREGISTER, LUNAVECT_PLUGINKIT and
LUNAVECT_INSTALLED_APPS (os.pathsep-separated, empty for none) replace the
system tools and standard copies so fixtures never reach the host registry.
"""
from pathlib import Path
import argparse
import os
import plistlib
import subprocess
import sys

DEFAULT_LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister'


def tool_paths(environment=None):
    environment = os.environ if environment is None else environment
    return (environment.get('LUNAVECT_LSREGISTER') or DEFAULT_LSREGISTER,
            environment.get('LUNAVECT_PLUGINKIT') or 'pluginkit')


LSREGISTER, PLUGINKIT = tool_paths()


def installed_copies(home=None, system=Path('/Applications')):
    home = Path.home() if home is None else Path(home)
    return [home / 'Applications/Lunavect.app', Path(system) / 'Lunavect.app']


def default_installed_copies(environment=None):
    value = (os.environ if environment is None else environment).get('LUNAVECT_INSTALLED_APPS')
    if value is None:
        return installed_copies()
    return [Path(item) for item in value.split(os.pathsep) if item]


def list_processes(run=subprocess.run):
    """(pid, executable path) pairs; an unavailable listing means none are known."""
    try:
        listing = run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    processes = []
    for line in listing.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            processes.append((int(parts[0]), parts[1]))
    return processes


def host_info(app):
    """Info.plist of a real (non-alias) Lunavect bundle, otherwise None."""
    if app.is_symlink() or not app.is_dir():
        return None
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    except (OSError, ValueError):
        return None
    return info if info.get('CFBundleIdentifier') == 'com.weekleft.app' else None


def reassertable(app, host):
    try:
        widget = plistlib.loads((app / 'Contents/PlugIns/LunavectWidget.appex/Contents/Info.plist').read_bytes())
    except (OSError, ValueError):
        return False
    return (widget.get('CFBundleIdentifier') == 'com.weekleft.app.widget'
            and bool(host.get('CFBundleVersion'))
            and host['CFBundleVersion'] == widget.get('CFBundleVersion'))


def running_copies(copies, processes):
    """Copies whose main executable runs, matched by resolved path (legacy link included)."""
    executables = {(app.resolve() / 'Contents/MacOS' / (info.get('CFBundleExecutable') or 'Lunavect')): app
                   for app, info in copies}
    names = {path.name for path in executables}
    running = []
    for _, command in processes:
        if Path(command).name not in names:
            continue
        app = executables.get(Path(os.path.realpath(command)))
        if app is not None and app not in running:
            running.append(app)
    return running


def choose(candidates, list_processes=list_processes):
    """The one copy that may be registered, or None; warns when several exist."""
    copies, seen = [], set()
    for app in candidates:
        info = host_info(app)
        if info is not None and app.resolve() not in seen:
            seen.add(app.resolve())
            copies.append((app, info))
    valid = [app for app, info in copies if reassertable(app, info)]
    if len(copies) < 2:
        return valid[0] if valid else None
    paths = ', '.join(str(app) for app, _ in copies)
    running = running_copies(copies, list_processes())
    prefix = f'Two Lunavect copies are installed ({paths}); desktop widgets can bind to either.'
    advice = 'Keep one copy (see docs/installation.md#uninstall).'
    if len(running) == 1:
        others = ', '.join(str(app) for app, _ in copies if app != running[0])
        if running[0] not in valid:
            print(f'{prefix} The running copy {running[0]} does not have a matching widget build; '
                  f'not reasserting {others} either. {advice}', file=sys.stderr)
            return None
        print(f'{prefix} Reasserting only the running copy {running[0]}; {others} is left unregistered. {advice}',
              file=sys.stderr)
        return running[0]
    state = 'neither is running' if not running else 'more than one is running'
    chosen = valid[0] if valid else None
    action = (f'reasserting {chosen} in the documented order (~/Applications first)' if chosen
              else 'none has a matching widget build to reassert')
    print(f'{prefix} Since {state}, {action}. {advice}', file=sys.stderr)
    return chosen


def reassert(candidates, run=subprocess.run, list_processes=list_processes):
    installed = choose(candidates, list_processes=list_processes)
    if installed is None:
        return None
    run([LSREGISTER, '-f', str(installed)], check=True)
    run([PLUGINKIT, '-a', str(installed / 'Contents/PlugIns/LunavectWidget.appex')], check=True)
    return installed


def unregister(app, run=subprocess.run):
    """Already-retired paths are success only after a fresh registry check."""
    try:
        run([LSREGISTER, '-u', str(app)], check=True)
    except subprocess.CalledProcessError:
        listing = run([LSREGISTER, '-dump'], check=True, capture_output=True, text=True).stdout
        registered = {Path(line.split('path:', 1)[1].strip().rsplit(' (0x', 1)[0]).resolve()
                      for line in listing.splitlines() if line.strip().startswith('path:')}
        if app.resolve() in registered:
            raise


def retire_temporary(copies, candidates, run=subprocess.run, list_processes=list_processes):
    """Unregister only explicitly owned build copies before their files disappear."""
    installed = {path.resolve() for path in candidates}
    retired = []
    try:
        for app in copies:
            if app.resolve() in installed:
                continue
            try:
                info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            except (OSError, ValueError):
                continue
            if info.get('CFBundleIdentifier') != 'com.weekleft.app':
                continue
            retired.append(app)
            extension = app / 'Contents/PlugIns/LunavectWidget.appex'
            if extension.is_dir():
                run([PLUGINKIT, '-r', str(extension)], check=False)
            unregister(app, run=run)
    finally:
        # Retiring a copy can invalidate the installed host's lookup as well.
        if retired:
            reassert(candidates, run=run, list_processes=list_processes)
    return retired


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--retire-app', action='append', type=Path, default=[])
    args = parser.parse_args()
    if args.retire_app:
        retired = retire_temporary(args.retire_app, default_installed_copies())
        print(f'Temporary Lunavect registrations retired: {len(retired)}; installed host reasserted when present.')
    else:
        restored = reassert(default_installed_copies())
        if restored:
            print(f'Installed Lunavect widget registration reasserted: {restored}')
    sys.exit(0)
