#!/usr/bin/env python3
"""Reject mismatched app/widget branding, versions and localization resources."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


# Explicit per-bundle resource contract. Retain approved source artwork unchanged.
SHARED = {'LunavectTide.icns', 'claude.pdf', 'codex.pdf', 'Translations.json',
          'Lunavect-LICENSE.txt', 'ThirdParty-LICENSE.txt'}
APP_ONLY = {'LunavectMark.png', 'LunavectMarkLeft.png', 'LunavectMarkRight.png',
            'clawd-laptop.json', 'clawd-walking.gif', 'clawd-waving.gif',
            'codex-companion.webp', 'lunavect-complete.wav', 'Lunavect-NOTICE.txt',
            'IconSources.md', 'Sparkle-LICENSE.txt'}
IDE_PACKAGES = {'lunavect-vscode.vsix', 'lunavect-jetbrains.zip', 'manifest.json'}
# App Intents metadata read by Edit Widget and the chart buttons. A silent
# extraction failure still builds, so require the packaged artifact itself.
APP_INTENTS = {'SelectActivityPointIntent'}
WIDGET_INTENTS = APP_INTENTS | {'ActivityConfiguration'}
INTENT_ENUMS = {'ActivityPeriod', 'ActivitySource'}
# A universal Release product (check.sh, distribution archive) carries both
# slices in every executable it runs: app, widget, hook and keep-awake helper.
UNIVERSAL = {'arm64', 'x86_64'}
HELPERS = ('Contents/Helpers/LunavectHook', 'Contents/Library/LaunchServices/LunavectAwakeHelper')


def resource_source(root, name):
    folder = 'Sources/WeekleftCore/Resources' if name == 'Translations.json' else 'Sources/Weekleft/Resources'
    return root / folder / name


def verify_resource(path):
    data = path.read_bytes()
    if not data:
        raise ValueError(f'{path.name}: empty resource')
    signatures = {'.pdf': b'%PDF-', '.png': b'\x89PNG\r\n\x1a\n', '.icns': b'icns', '.gif': b'GIF8'}
    if path.suffix in signatures and not data.startswith(signatures[path.suffix]):
        raise ValueError(f'{path.name}: invalid resource header')
    if path.suffix == '.json':
        json.loads(data)
    if path.suffix in ('.webp', '.wav'):
        kind = b'WEBP' if path.suffix == '.webp' else b'WAVE'
        if data[:4] != b'RIFF' or data[8:12] != kind:
            raise ValueError(f'{path.name}: invalid RIFF resource')


def verify_intent_metadata(bundle, actions):
    path = bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
    if not path.is_file():
        raise ValueError(f'{bundle.name}: missing App Intents metadata')
    value = json.loads(path.read_bytes())
    declared = value.get('actions') if isinstance(value, dict) else None
    enums = value.get('enums') if isinstance(value, dict) else None
    identifiers = {item.get('identifier') for item in enums if isinstance(item, dict)} if isinstance(enums, list) else set()
    if not isinstance(declared, dict) or not actions <= set(declared) or not INTENT_ENUMS <= identifiers:
        raise ValueError(f'{bundle.name}: App Intents metadata lacks the activity intents')


def architectures(path):
    """Slices of one Mach-O file as reported by lipo; a non-Mach-O file fails."""
    result = subprocess.run(['/usr/bin/lipo', '-archs', str(path)], capture_output=True, text=True, check=True)
    return set(result.stdout.split())


def verify_universal(app, widget, infos, read):
    executables = [bundle / 'Contents/MacOS' / info.get('CFBundleExecutable', '')
                   for bundle, info in ((app, infos[0]), (widget, infos[1]))]
    executables += [app / helper for helper in HELPERS]
    for path in executables:
        if not path.name or not path.is_file():
            raise ValueError(f'{path.relative_to(app)}: missing executable')
        missing = UNIVERSAL - read(path)
        if missing:
            raise ValueError(f'{path.relative_to(app)} lacks {", ".join(sorted(missing))}: not a universal build')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def icon_path(bundle, info):
    name = info.get('CFBundleIconFile', '')
    if not name or Path(name).name != name:
        raise ValueError(f'{bundle.name}: missing or invalid CFBundleIconFile')
    path = bundle / 'Contents/Resources' / Path(name).with_suffix('.icns')
    if not path.is_file() or path.read_bytes()[:4] != b'icns':
        raise ValueError(f'{bundle.name}: declared icon is missing or invalid')
    return path


def verify(app, source_root=None, universal=False, architectures=architectures):
    widget = app / 'Contents/PlugIns/LunavectWidget.appex'
    bundles = (app, widget)
    infos = [plistlib.loads((bundle / 'Contents/Info.plist').read_bytes()) for bundle in bundles]
    if universal:
        verify_universal(app, widget, infos, architectures)
    for key in ('CFBundleName', 'CFBundleDisplayName'):
        if any(info.get(key) != 'Lunavect' for info in infos):
            raise ValueError(f'App and widget must use the current Lunavect {key}')
    for key in ('CFBundleVersion', 'CFBundleShortVersionString', 'WeekleftAppGroup', 'CFBundleLocalizations'):
        if not infos[0].get(key) or infos[0].get(key) != infos[1].get(key):
            raise ValueError(f'App/widget {key} differs or is missing')
    icons = [icon_path(bundle, info) for bundle, info in zip(bundles, infos)]
    if digest(icons[0]) != digest(icons[1]):
        raise ValueError('App and widget contain different icon artwork')
    for bundle, required in ((app, SHARED | APP_ONLY), (widget, SHARED)):
        directory = bundle / 'Contents/Resources'
        for name in required:
            verify_resource(directory / name)
        allowed = required | {'Metadata.appintents'} | {language + '.lproj' for language in infos[0]['CFBundleLocalizations']}
        if bundle == app:
            allowed.add('IDEConnectors')
        unexpected = {path.name for path in directory.iterdir()} - allowed
        if unexpected:
            raise ValueError(f'{bundle.name}: resources outside bundle allowlist: {", ".join(sorted(unexpected))}')
        for language in infos[0]['CFBundleLocalizations']:
            path = directory / (language + '.lproj') / 'Localizable.strings'
            if not path.is_file() or not path.stat().st_size:
                raise ValueError(f'{bundle.name}: missing {language} intent localization')
    verify_intent_metadata(app, APP_INTENTS)
    verify_intent_metadata(widget, WIDGET_INTENTS)
    connectors = app / 'Contents/Resources/IDEConnectors'
    if {path.name for path in connectors.iterdir()} != IDE_PACKAGES:
        raise ValueError('IDE connector installer set is incomplete or contains unexpected files')
    manifest = json.loads((connectors / 'manifest.json').read_bytes())
    if set(manifest.get('artifacts', {})) != IDE_PACKAGES - {'manifest.json'}:
        raise ValueError('IDE connector installer manifest is incomplete')
    for name, expected in manifest['artifacts'].items():
        if digest(connectors / name) != expected:
            raise ValueError(f'IDE connector {name} differs from its manifest')
    if source_root is not None:
        for name in IDE_PACKAGES:
            if digest(connectors / name) != digest(source_root / 'Sources/Weekleft/Resources/IDEConnectors' / name):
                raise ValueError(f'Built IDE connector {name} is stale relative to the source')
    for name in SHARED:
        if digest(app / 'Contents/Resources' / name) != digest(widget / 'Contents/Resources' / name):
            raise ValueError(f'App/widget {name} differs')
    if source_root is not None:
        selected = json.loads((source_root / 'design/selected/selection.json').read_text())
        master = source_root / 'design/selected' / selected['file']
        if digest(master) != selected['sha256']:
            raise ValueError('Selected icon master differs from its approved hash')
        expected_icon = source_root / selected['application_resource']
        if icons[0].name != expected_icon.name or digest(icons[0]) != digest(expected_icon):
            raise ValueError('Built app does not contain the selected current icon')
        for name in SHARED | APP_ONLY:
            if digest(app / 'Contents/Resources' / name) != digest(resource_source(source_root, name)):
                raise ValueError(f'Built {name} is stale relative to the source')
    return infos[0]['CFBundleVersion']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--universal', action='store_true',
                        help='Also require arm64 and x86_64 slices in the app, widget and helper executables')
    args = parser.parse_args()
    try:
        build = verify(args.app, args.source_root, args.universal)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Product resource verification failed: {error}\n')
    print(f'Product resources verified: app/widget build {build}, matching icons, translations and intent metadata'
          + ('; universal arm64/x86_64 executables' if args.universal else ''))
