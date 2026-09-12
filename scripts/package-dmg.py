#!/usr/bin/env python3
"""Package a notarized Lunavect app in a read-only drag-to-Applications DMG."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile


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
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    info = verify_app(app)
    if output.exists() or output.suffix != '.dmg':
        raise ValueError('Choose a new .dmg output path')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='lunavect-dmg-', dir=output.parent) as temporary:
        temporary = Path(temporary)
        contents, mount = temporary / 'contents', temporary / 'mount'
        contents.mkdir(); mount.mkdir()
        checked('ditto', str(app), str(contents / 'Lunavect.app'))
        (contents / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (contents / 'Read Me.txt').write_text(
            'Lunavect ' + info['CFBundleShortVersionString'] + '\n\n'
            'Drag Lunavect to Applications, then open it from Applications.\n'
            'Connect Claude Code, Codex, or both using the setup guide.\n'
            'Sign in only inside the official client.\n\n'
            'Updating: quit Lunavect and replace your existing copy.\n'
            'Keep a single installed copy so the widget gallery stays unambiguous.\n\n'
            'Source and help: https://github.com/lovach/Lunavect\n')
        image = temporary / output.name
        checked('hdiutil', 'create', '-quiet', '-fs', 'APFS', '-format', 'ULFO',
                '-volname', 'Lunavect', '-srcfolder', str(contents), str(image))
        checked('hdiutil', 'verify', str(image))
        checked('hdiutil', 'attach', '-quiet', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(image))
        try:
            mounted = mount / 'Lunavect.app'
            verify_app(mounted)
            if (mount / 'Applications').readlink() != Path('/Applications'):
                raise ValueError('Invalid Applications link')
            if (mounted / 'Contents/Info.plist').read_bytes() != (app / 'Contents/Info.plist').read_bytes():
                raise ValueError('Mounted app metadata differs from the release')
        finally:
            checked('hdiutil', 'detach', '-quiet', str(mount))
        image.rename(output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    print(f'Verified DMG containing the notarized app: {output.name}\nSHA-256: {digest}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
