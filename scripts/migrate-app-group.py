#!/usr/bin/env python3
"""Preserve local development data when installing a differently signed release.

Only our shared files move. Originals remain in their old container. Existing
destination data is never overwritten; a conflicting migration stops installation.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re


def group_for(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.weekleft.app':
        raise ValueError('Expected an existing Lunavect application')
    group = info.get('WeekleftAppGroup', '')
    if not re.fullmatch(r'(?:group\.[A-Za-z0-9.-]+|[A-Z0-9]{10}\.[A-Za-z0-9.-]+)', group):
        raise ValueError('Invalid Lunavect App Group')
    return group


def reject_links(path, boundary):
    for part in (path, *path.parents):
        if part == boundary:
            break
        if part.is_symlink():
            raise ValueError('Refusing a symbolic link in shared data')


def migrate(old_app, new_app, home):
    old_group, new_group = group_for(old_app), group_for(new_app)
    if old_group == new_group:
        return 0
    containers = home / 'Library/Group Containers'
    source, destination = containers / old_group, containers / new_group
    candidates = [(Path('Weekleft') / name, Path('Weekleft') / name)
                  for name in ('snapshot.json', 'activity.json')]
    selected = source / 'Weekleft/ActivitySelection'
    reject_links(selected, containers)
    if selected.exists():
        for item in sorted(selected.glob('*.json')):
            if not re.fullmatch(r'Lunavect(?:Activity|Overview)Widget-(?:day|week|month)-(?:all|claude|codex)\.json', item.name):
                continue
            candidates.append((item.relative_to(source), item.relative_to(source)))
    candidates.append((Path(f'Library/Preferences/{old_group}.plist'),
                       Path(f'Library/Preferences/{new_group}.plist')))
    pending = []
    # Validate all inputs and conflicts before the first write.
    for old_relative, new_relative in candidates:
        old, new = source / old_relative, destination / new_relative
        reject_links(old, containers)
        reject_links(new, containers)
        if not old.exists():
            continue
        if not old.is_file() or old.stat().st_size > 32_000_000:
            raise ValueError('Unexpected shared data file')
        data = old.read_bytes()
        if old.suffix == '.plist':
            if not isinstance(plistlib.loads(data), dict):
                raise ValueError('Invalid shared preferences')
        else:
            json.loads(data, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Non-finite JSON')))
        if new.exists():
            if not new.is_file() or new.read_bytes() != data:
                raise ValueError('New container already has different data; review before migrating')
        else:
            pending.append((new, data))
    for new, data in pending:
        new.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        reject_links(new, containers)
        descriptor = os.open(new, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        except BaseException:
            new.unlink(missing_ok=True)
            raise
        if new.read_bytes() != data:
            raise ValueError('Shared data copy verification failed')
    return len(pending)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--from-app', required=True, type=Path)
    parser.add_argument('--to-app', required=True, type=Path)
    args = parser.parse_args()
    try:
        count = migrate(args.from_app, args.to_app, Path.home())
        print(f'App Group migration verified: {count} files copied; originals retained')
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
