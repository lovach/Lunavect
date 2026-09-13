#!/usr/bin/env python3
"""Regenerate a disposable project and compare it without changing the checkout."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

VERSION = '2.46.0'


def verify(root, executable='xcodegen'):
    version = subprocess.check_output([executable, '--version'], text=True).strip()
    if version != 'Version: ' + VERSION:
        raise ValueError('Project parity requires XcodeGen ' + VERSION + '; found ' + version)
    with tempfile.TemporaryDirectory(prefix='lunavect-project-parity-') as temporary:
        copied = Path(temporary)
        shutil.copyfile(root / 'project.yml', copied / 'project.yml')
        for name in ('Sources', 'Widget', 'Config'):
            shutil.copytree(root / name, copied / name, ignore=shutil.ignore_patterns('Local.xcconfig'))
        subprocess.run([executable, 'generate', '--spec', str(copied / 'project.yml'), '--project', str(copied)],
                       check=True, capture_output=True, text=True)
        generated = copied / 'Weekleft.xcodeproj'
        expected = root / 'Weekleft.xcodeproj'
        names = {Path('project.pbxproj')}
        for project in (expected, generated):
            names.update(path.relative_to(project) for path in (project / 'xcshareddata/xcschemes').glob('*.xcscheme'))
        different = [str(name) for name in sorted(names) if not (expected / name).is_file()
                     or not (generated / name).is_file() or (expected / name).read_bytes() != (generated / name).read_bytes()]
        if different:
            raise ValueError('Xcode project differs from project.yml: ' + ', '.join(different) + '; regenerate with XcodeGen ' + VERSION)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--xcodegen', default=os.environ.get('XCODEGEN', 'xcodegen'))
    args = parser.parse_args()
    try:
        verify(args.source_root.resolve(), args.xcodegen)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
    print('XcodeGen ' + VERSION + ' project and shared schemes match; checkout unchanged.')


if __name__ == '__main__':
    main()
