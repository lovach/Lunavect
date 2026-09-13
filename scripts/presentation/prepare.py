#!/usr/bin/env python3
"""Prepare an independent media source copy without launching or installing it."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]


def prepare(output):
    output.mkdir(parents=True, exist_ok=False)
    for name in ('Package.swift', 'Package.resolved'):
        shutil.copyfile(ROOT / name, output / name)
    shutil.copytree(ROOT / 'Sources', output / 'Sources')
    # SwiftPM validates every declared target even for a product-only build.
    shutil.copytree(ROOT / 'Tests', output / 'Tests', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    main = output / 'Sources/Weekleft/Main.swift'
    source = main.read_text()
    # Shared popover support also lives in Main.swift; retain it. Only the media
    # launcher receives @main, so the live application entry point is never run.
    marker = '@main enum WeekleftLauncher'
    if source.count(marker) != 1:
        raise ValueError('Application entry point changed; review media preparation before continuing')
    main.write_text(source.replace(marker, 'enum WeekleftLauncher', 1))
    shutil.copyfile(ROOT / 'scripts/presentation/DemoMain.swift', output / 'Sources/Weekleft/DemoMain.swift')
    shutil.copyfile(ROOT / 'Tests/WeekleftUITests/PresentationFixture.swift', output / 'Sources/Weekleft/PresentationFixture.swift')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New private source directory')
    args = parser.parse_args()
    try:
        prepare(args.output)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
    print('Prepared media source; not built, launched, rendered or installed.')
