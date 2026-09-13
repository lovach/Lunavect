#!/usr/bin/env python3
"""Check the embedded helper's compiled signing policy without starting its service."""
import argparse
from pathlib import Path
import subprocess


def verify(app, policy):
    helper = app / 'Contents/Library/LaunchServices/LunavectAwakeHelper'
    result = subprocess.run([str(helper), '--signing-policy'], check=True, capture_output=True, text=True, timeout=5)
    if result.stdout.strip() != policy:
        raise ValueError('Embedded awake helper does not use the expected ' + policy + ' signing policy')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--policy', required=True, choices=('development', 'developer-id'))
    args = parser.parse_args()
    try:
        verify(args.app, args.policy)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
    print('Embedded awake signing policy verified: ' + args.policy)
