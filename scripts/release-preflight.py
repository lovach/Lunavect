#!/usr/bin/env python3
"""Validate release identity against an explicitly supplied published appcast."""
import argparse
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def marketing_version(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', value):
        raise ValueError('Previous appcast contains an unavailable or malformed marketing version')
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (4 - len(parts))


def validate_previous(version, build, previous):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[0-9]+', str(build)) or int(build) <= 0:
        raise ValueError('Expected VERSION major.minor.patch and positive integer BUILD')
    root = ET.parse(previous).getroot()
    builds, versions = [], []
    for item in root.findall('./channel/item'):
        enclosure = item.find('enclosure')
        value = item.findtext(SPARKLE + 'version')
        if value is None and enclosure is not None:
            value = enclosure.get(SPARKLE + 'version')
        if value is None or not re.fullmatch(r'[0-9]+', value):
            raise ValueError('Previous appcast contains an unavailable or nonnumeric build')
        builds.append(int(value))
        short = item.findtext(SPARKLE + 'shortVersionString')
        if short is None and enclosure is not None:
            short = enclosure.get(SPARKLE + 'shortVersionString')
        versions.append(marketing_version(short))
    if not builds:
        raise ValueError('Previous appcast has no published builds')
    if int(build) <= max(builds):
        raise ValueError('Release build must exceed every build in the previous appcast')
    if marketing_version(version) <= max(versions):
        raise ValueError('Release marketing version must exceed every version in the previous appcast')


def validate_source(root, version):
    if subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--is-shallow-repository'], text=True).strip() != 'false':
        raise ValueError('Distribution requires full Git history and refreshed tags; shallow history cannot establish tag availability')
    if subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all']):
        raise ValueError('Distribution requires a clean Git checkout; local build/check may remain dirty')
    tag = 'refs/tags/v' + version
    result = subprocess.run(['git', '-C', str(root), 'show-ref', '--verify', '--quiet', tag])
    if result.returncode == 0:
        raise ValueError('Release tag already exists: v' + version)
    if result.returncode != 1:
        raise ValueError('Cannot inspect release tags')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--previous-appcast', type=Path, required=True,
                        help='Fresh downloaded published appcast; no automatic account/network access')
    parser.add_argument('--source-root', type=Path)
    args = parser.parse_args()
    try:
        validate_previous(args.version, args.build, args.previous_appcast)
        if args.source_root:
            validate_source(args.source_root, args.version)
    except (ValueError, OSError, ET.ParseError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
    print('Release identity verified against supplied appcast' + (' and clean source/tags' if args.source_root else ''))


if __name__ == '__main__':
    main()
