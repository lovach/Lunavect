#!/usr/bin/env python3
"""Reject file-sync conflict copies before SwiftPM or XcodeGen can compile them.

iCloud Drive and similar tools create siblings such as ``Name 2.swift`` or a
``folder 2`` directory. SwiftPM and XcodeGen include every file in a source
directory, so a byte-identical copy redeclares types and fails the build with
errors that do not name the cause. GitHub also runs every workflow file and
Pages publishes every docs file, so copies there act without being compiled.
This check names the copies instead.
"""
import argparse
from pathlib import Path
import re

SCOPES = ('Sources', 'Tests', 'scripts', 'integrations', 'Config', 'Lunavect.xcodeproj', '.github', 'docs', 'design')
# "Name 2.swift", "Name 3", "Name 2.tar.gz"; never a digit glued to the stem ("v2.swift").
CONFLICT = re.compile(r'^.+ [0-9]+(?:\.[^./ ]+)*$')


def conflict_copies(root):
    found = []
    for scope in SCOPES:
        base = root / scope
        if not base.exists():
            continue
        for path in sorted(base.rglob('*')):
            relative = path.relative_to(root)
            if any(part in ('.build', 'node_modules', '__pycache__') for part in relative.parts):
                continue
            if CONFLICT.match(path.name) and not any(CONFLICT.match(part) for part in relative.parts[:-1]):
                found.append(relative)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    copies = conflict_copies(args.source_root.resolve())
    if copies:
        listing = '\n'.join('  ' + str(path) for path in copies)
        parser.exit(1, 'File-sync conflict copies found; compare each with its original, then move it out of the checkout:\n'
                    + listing + '\n')
    print('No file-sync conflict copies in ' + ', '.join(SCOPES) + '.')


if __name__ == '__main__':
    main()
