#!/usr/bin/env python3
"""Reassert the installed Lunavect host and widget after a temporary copy was unregistered.

Unregistering a build product with the same bundle identifiers can invalidate the
containing-bundle lookup of the installed widget, leaving desktop widgets on
placeholders. This only re-registers an installed copy whose host and widget
identifiers and build numbers match; it never launches, replaces or edits it.
"""
from pathlib import Path
import argparse
import plistlib
import subprocess
import sys

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister'


def installed_copies(home=None, system=Path('/Applications')):
    home = Path.home() if home is None else Path(home)
    return [home / 'Applications/Lunavect.app', Path(system) / 'Lunavect.app']


def reassert(candidates, run=subprocess.run):
    for installed in candidates:
        if installed.is_symlink() or not installed.is_dir():
            continue
        extension = installed / 'Contents/PlugIns/LunavectWidget.appex'
        try:
            host = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
            widget = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
        except (OSError, ValueError):
            continue
        if (host.get('CFBundleIdentifier') != 'com.weekleft.app'
                or widget.get('CFBundleIdentifier') != 'com.weekleft.app.widget'
                or not host.get('CFBundleVersion')
                or host['CFBundleVersion'] != widget.get('CFBundleVersion')):
            continue
        run([LSREGISTER, '-f', str(installed)], check=True)
        run(['pluginkit', '-a', str(extension)], check=True)
        return installed
    return None


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


def retire_temporary(copies, candidates, run=subprocess.run):
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
                run(['pluginkit', '-r', str(extension)], check=False)
            unregister(app, run=run)
    finally:
        # Retiring a copy can invalidate the installed host's lookup as well.
        if retired:
            reassert(candidates, run=run)
    return retired


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--retire-app', action='append', type=Path, default=[])
    args = parser.parse_args()
    if args.retire_app:
        retired = retire_temporary(args.retire_app, installed_copies())
        print(f'Temporary Lunavect registrations retired: {len(retired)}; installed host reasserted when present.')
    else:
        restored = reassert(installed_copies())
        if restored:
            print(f'Installed Lunavect widget registration reasserted: {restored}')
    sys.exit(0)
