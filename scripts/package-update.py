#!/usr/bin/env python3
"""Prepare a signed GitHub Release update locally; never upload or publish."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from urllib.parse import urlparse
import xml.etree.ElementTree as ET


def inspect_app(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'com.weekleft.app':
        raise ValueError('Expected the Lunavect application bundle')
    feed = info.get('SUFeedURL', '')
    if not re.fullmatch(r'https://github\.com/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/releases/latest/download/appcast\.xml', feed):
        raise ValueError('Configure the GitHub SUFeedURL before building the release')
    public_key = info.get('SUPublicEDKey', '')
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('Configure a valid public Ed25519 key before building')
    for key in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
        if info.get(key) is not True:
            raise ValueError(f'{key} must be enabled')
    version, build = info.get('CFBundleShortVersionString', ''), info.get('CFBundleVersion', '')
    if not re.fullmatch(r'\d+(?:\.\d+){1,3}', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('Expected a numeric version and monotonically increasing build number')
    repo = '/'.join(urlparse(feed).path.split('/')[1:3])
    return info, repo, version, build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New directory for release assets')
    parser.add_argument('--key-file', type=Path, required=True, help='Private Sparkle key outside the repository; never printed')
    parser.add_argument('--tools', type=Path, default=Path('.build/artifacts/sparkle/Sparkle/bin'))
    args = parser.parse_args()
    app, output, key = args.app.resolve(), args.output.resolve(), args.key_file.resolve()
    info, repo, version, build = inspect_app(app)
    if output.exists():
        raise ValueError('Output directory already exists; choose a new directory')
    if not key.is_file() or key.stat().st_mode & 0o077:
        raise ValueError('Private key file must exist and have owner-only permissions (chmod 600)')
    project = Path(__file__).resolve().parent.parent
    if key.is_relative_to(project):
        raise ValueError('Keep the private key outside the project')
    generate = (args.tools / 'generate_appcast').resolve()
    sign = (args.tools / 'sign_update').resolve()
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', str(app)], check=True)
    subprocess.run(['/usr/bin/xcrun', 'stapler', 'validate', str(app)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.lunavect-update-', dir=output.parent) as staging:
        staging = Path(staging)
        archive = staging / f'Lunavect-{version}-{build}.zip'
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
        prefix = f'https://github.com/{repo}/releases/download/v{version}/'
        subprocess.run([str(generate), '--ed-key-file', str(key), '--download-url-prefix', prefix,
                        '--maximum-deltas', '0', str(staging)], check=True)
        feed = staging / 'appcast.xml'
        subprocess.run([str(sign), '--verify', '--ed-key-file', str(key), str(feed)], check=True)
        enclosure = ET.parse(feed).getroot().find('./channel/item/enclosure')
        if enclosure is None or enclosure.attrib.get('url') != prefix + archive.name:
            raise ValueError('Generated appcast does not reference the expected GitHub asset')
        signature = enclosure.attrib.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
        if not signature:
            raise ValueError('Missing archive signature')
        subprocess.run([str(sign), '--verify', '--ed-key-file', str(key), str(archive), signature], check=True)
        subprocess.run(['/usr/bin/swift', str(project / 'scripts/verify-update-signature.swift'),
                        info['SUPublicEDKey'], str(archive), signature], check=True)
        output.mkdir(mode=0o700)
        archive.rename(output / archive.name)
        feed.rename(output / feed.name)
    print(f'Prepared {archive.name} and appcast.xml for GitHub tag v{version}. Nothing uploaded.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
