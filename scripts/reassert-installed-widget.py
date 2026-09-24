#!/usr/bin/env python3
"""Reassert the installed Lunavect host and widget after a temporary copy was unregistered.

Unregistering a build product with the same bundle identifiers can invalidate the
containing-bundle lookup of the installed widget, leaving desktop widgets on
placeholders. This only re-registers an installed copy whose host and widget
identifiers and build numbers match; it never launches, replaces or edits it.
"""
from pathlib import Path
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


if __name__ == '__main__':
    restored = reassert(installed_copies())
    if restored:
        print(f'Installed Lunavect widget registration reasserted: {restored}')
    sys.exit(0)
