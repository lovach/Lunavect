#!/usr/bin/env python3
"""Package a notarized Lunavect app in a read-only drag-to-Applications DMG."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import sys

ARTWORK = Path(__file__).resolve().parent / 'dmg'
_spec = importlib.util.spec_from_file_location('release_preflight', Path(__file__).with_name('release-preflight.py'))
preflight = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(preflight)
REGISTER = '/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister'


def checked(*command):
    subprocess.run(command, check=True)


def verify_app(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.weekleft.app':
        raise ValueError('Expected Lunavect.app')
    signature = subprocess.check_output(['codesign', '-dvv', str(app)], stderr=subprocess.STDOUT, text=True)
    if 'Authority=Developer ID Application:' not in signature:
        raise ValueError('A Developer ID distribution signature is required')
    checked('codesign', '--verify', '--deep', '--strict', str(app))
    checked('spctl', '--assess', '--type', 'execute', str(app))
    checked('xcrun', 'stapler', 'validate', str(app))
    checked(sys.executable, str(Path(__file__).with_name('verify-awake-policy.py')), str(app), '--policy', 'developer-id')
    return info


def verify_layout(mount, layout):
    from ds_store import DSStore

    with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
        window = store['.']['bwsp']
        icons = store['.']['icvp']
        (x, y), (width, height) = layout['window_rect']
        if window['WindowBounds'] != f'{{{{{x}, {y}}}, {{{width}, {height}}}}}':
            raise ValueError('Installer window dimensions were not saved')
        if any(window[key] for key in ('ShowToolbar', 'ShowSidebar', 'ShowStatusBar', 'ShowPathbar')):
            raise ValueError('Installer must open as a compact icon window')
        if icons['backgroundType'] != 2 or icons['iconSize'] != layout['icon_size']:
            raise ValueError('Installer artwork or icon size is missing')
        for name, position in layout['icon_locations'].items():
            if tuple(store[name]['Iloc'])[:2] != tuple(position):
                raise ValueError(f'Installer icon is misplaced: {name}')
    if not (mount / '.background.tiff').is_file():
        raise ValueError('Retina installer background is missing')
    visible = {p.name for p in mount.iterdir() if not p.name.startswith('.')}
    if visible != {'Lunavect.app', 'Applications'}:
        raise ValueError(f'Unexpected visible installer files: {visible}')


class CleanupFailed(Exception):
    """Packaging failed and retiring its exported source failed as well."""

    def __init__(self, original, cleanup):
        super().__init__(f'{original}\nRegistration cleanup also failed: {cleanup}')


def retire_exported(app):
    checked(sys.executable, str(Path(__file__).with_name('reassert-installed-widget.py')),
            '--retire-app', str(app))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--test-fixture', action='store_true',
                        help='Accept LUNAVECT_* registration overrides (script tests only); a release refuses them')
    args = parser.parse_args()
    # The retirement honours LUNAVECT_* registration overrides; a release must not.
    preflight.refuse_fixture_overrides(parser, args.test_fixture)
    # Retire the exported source after success and failure alike; a cleanup
    # failure must not replace the reason packaging stopped.
    try:
        prepare(args)
    except BaseException as original:
        try:
            retire_exported(args.app)
        except Exception as cleanup:
            raise CleanupFailed(original, cleanup) from original
        raise
    retire_exported(args.app)


def prepare(args):
    try:
        import dmgbuild
    except ImportError:
        raise ValueError('Install the release-only dependencies from scripts/dmg/requirements.txt in a virtual environment')
    app, output = args.app.resolve(), args.output.resolve()
    info = verify_app(app)
    if output.exists() or output.suffix != '.dmg':
        raise ValueError('Choose a new .dmg output path')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='lunavect-dmg-', dir=output.parent) as temporary:
        temporary = Path(temporary)
        mount = temporary / 'mount'
        mount.mkdir()
        checked('swift', str(ARTWORK / 'render-background.swift'), str(temporary))
        layout = json.loads((ARTWORK / 'layout.json').read_text())
        image = temporary / output.name
        temporary_apps = set()

        def packaging_event(event):
            if event.get('type') == 'operation::start' and event.get('operation') == 'file::add':
                temporary_apps.add(event['file'])
            if event.get('type') == 'operation::finished' and event.get('operation') == 'dsstore::create':
                for copied in temporary_apps:
                    subprocess.run([REGISTER, '-u', copied], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Write Finder metadata directly, without asking for Automation or
        # Accessibility permissions or changing the build Mac's Finder settings.
        try:
            dmgbuild.build_dmg(str(image), 'Lunavect', settings={
                **layout,
                'filesystem': 'APFS', 'format': 'ULFO',
                'files': [(str(app), 'Lunavect.app')],
                'symlinks': {'Applications': '/Applications'},
                'icon': str(app / 'Contents/Resources' / Path(info['CFBundleIconFile']).with_suffix('.icns')),
                'background': str(temporary / 'background.png'),
                'default_view': 'icon-view', 'grid_spacing': 80,
                'show_toolbar': False, 'show_sidebar': False,
                'show_status_bar': False, 'show_tab_view': False,
                'show_pathbar': False,
            }, callback=packaging_event)
        finally:
            for copied in temporary_apps:
                subprocess.run([REGISTER, '-u', copied], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        checked('hdiutil', 'verify', str(image))
        checked('hdiutil', 'attach', '-quiet', '-readonly', '-noautoopen', '-nobrowse', '-mountpoint', str(mount), str(image))
        try:
            mounted = mount / 'Lunavect.app'
            verify_app(mounted)
            if (mount / 'Applications').readlink() != Path('/Applications'):
                raise ValueError('Invalid Applications link')
            if (mounted / 'Contents/Info.plist').read_bytes() != (app / 'Contents/Info.plist').read_bytes():
                raise ValueError('Mounted app metadata differs from the release')
            verify_layout(mount, layout)
        finally:
            subprocess.run([REGISTER, '-u', str(mount / 'Lunavect.app')], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            checked('hdiutil', 'detach', '-quiet', str(mount))
        image.rename(output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    print(f'Verified DMG containing the notarized app: {output.name}\nSHA-256: {digest}')


def entry():
    try:
        main()
    except (CleanupFailed, ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    entry()
