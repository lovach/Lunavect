#!/bin/bash
# Xcode signs with the selected Apple account; no passwords or private keys here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-}"
VERSION="${2:-}"
BUILD="${3:-}"
PREVIOUS_APPCAST="${4:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo 'Usage: scripts/distribute.sh archive|submit|export VERSION BUILD [PREVIOUS_APPCAST (required for archive)]' >&2
  exit 2
fi
OUTPUT="${LUNAVECT_RELEASE_ROOT:-$HOME/Library/Developer/Xcode/Archives/Lunavect}"
ARCHIVE="$OUTPUT/Lunavect-$VERSION-$BUILD.xcarchive"
MANIFEST="$OUTPUT/Lunavect-$VERSION-$BUILD-manifest.json"
mkdir -p "$OUTPUT"
# An archive whose checks failed keeps an unfinished manifest. Later steps accept
# only a complete distribution manifest whose recorded app hash still matches.
require_verified_archive() {
  python3 "$ROOT/scripts/build-manifest.py" verify --manifest "$MANIFEST" --kind distribution \
    --version "$VERSION" --build "$BUILD" --app "$ARCHIVE/Products/Applications/Lunavect.app"
}
cd "$ROOT"
case "$ACTION" in
  archive)
    if [ -z "$PREVIOUS_APPCAST" ]; then echo 'Archive requires a fresh published PREVIOUS_APPCAST file.' >&2; exit 2; fi
    python3 "$ROOT/scripts/release-preflight.py" --source-root "$ROOT" --version "$VERSION" --build "$BUILD" --previous-appcast "$PREVIOUS_APPCAST"
    if [ -e "$ARCHIVE" ]; then echo 'Archive already exists; use a new build number.' >&2; exit 1; fi
    python3 "$ROOT/scripts/build-manifest.py" begin --source-root "$ROOT" --kind distribution --require-clean --output "$MANIFEST"
    xcodebuild -project Lunavect.xcodeproj -scheme Weekleft -configuration Release \
      -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
      -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Lunavect-Distribution.noindex" \
      -xcconfig Config/Distribution.xcconfig -allowProvisioningUpdates \
      SWIFT_ACTIVE_COMPILATION_CONDITIONS=LUNAVECT_DISTRIBUTION \
      CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$VERSION" REGISTER_APP_WITH_LAUNCH_SERVICES=NO archive
    python3 "$ROOT/scripts/verify-product-resources.py" "$ARCHIVE/Products/Applications/Lunavect.app" --source-root "$ROOT"
    python3 "$ROOT/scripts/verify-awake-policy.py" "$ARCHIVE/Products/Applications/Lunavect.app" --policy developer-id
    python3 "$ROOT/scripts/build-manifest.py" finalize --source-root "$ROOT" --manifest "$MANIFEST" --app "$ARCHIVE/Products/Applications/Lunavect.app"
    ;;
  submit)
    require_verified_archive
    python3 "$ROOT/scripts/verify-product-resources.py" "$ARCHIVE/Products/Applications/Lunavect.app"
    OPTIONS=$(mktemp)
    trap 'rm -f "$OPTIONS"' EXIT
    python3 - "$OPTIONS" "$ROOT/Config/Distribution.xcconfig" <<'PY'
import plistlib, re, sys
with open(sys.argv[2]) as source:
    team = re.search(r'^DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$', source.read(), re.M).group(1)
with open(sys.argv[1], 'wb') as target:
    plistlib.dump({'method': 'developer-id', 'destination': 'upload', 'teamID': team, 'signingStyle': 'automatic'}, target)
PY
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUTPUT/Submission-$BUILD" \
      -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates
    ;;
  export)
    require_verified_archive
    xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUTPUT/Notarized-$BUILD"
    python3 "$ROOT/scripts/verify-product-resources.py" "$OUTPUT/Notarized-$BUILD/Lunavect.app"
    ;;
  *) echo 'Choose archive, submit, or export.' >&2; exit 2 ;;
esac

# Xcode's export/notarization checks can register temporary copies even when
# archive registration is disabled. Keep them out of Spotlight/widget discovery.
python3 - "$ARCHIVE" "$OUTPUT" "$BUILD" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
archive, output, build = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
copies = [archive / 'Products/Applications/Lunavect.app',
          output / f'Submission-{build}/Lunavect.app',
          output / f'Export-{build}/Lunavect.app',
          output / f'Notarized-{build}/Lunavect.app',
          Path.home() / 'Library/Developer/Xcode/DerivedData/Lunavect-Distribution.noindex/Build/Intermediates.noindex/ArchiveIntermediates/Weekleft/InstallationBuildProductsLocation/Applications/Lunavect.app']
copies.extend(archive.glob('Submissions/*/Lunavect.app'))
register = '/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister'
registered = {line.split('path:', 1)[1].strip().rsplit(' (0x', 1)[0]
              for line in subprocess.check_output([register, '-dump'], text=True).splitlines()
              if line.strip().startswith('path:')}
for app in copies:
    if not (app / 'Contents/Info.plist').is_file():
        continue
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.weekleft.app':
        raise SystemExit('Unexpected app in distribution output')
    if str(app) in registered:
        subprocess.run([register, '-u', str(app)], check=True)
    for extension in (app / 'Contents/PlugIns').glob('*.appex'):
        subprocess.run(['pluginkit', '-r', str(extension)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
# Removing an archive's extension can invalidate the containing-bundle lookup
# for the installed copy too. Reassert the installed host AFTER all removals.
# Do not launch it, replace files, change defaults or restart system services.
for installed in [Path.home() / 'Applications/Lunavect.app', Path('/Applications/Lunavect.app')]:
    if installed.is_symlink() or not installed.is_dir():
        continue
    extension = installed / 'Contents/PlugIns/LunavectWidget.appex'
    try:
        host_info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
        widget_info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
    except (OSError, ValueError):
        continue
    if (host_info.get('CFBundleIdentifier') != 'com.weekleft.app'
            or widget_info.get('CFBundleIdentifier') != 'com.weekleft.app.widget'
            or not host_info.get('CFBundleVersion')
            or host_info['CFBundleVersion'] != widget_info.get('CFBundleVersion')):
        continue
    subprocess.run([register, '-f', str(installed)], check=True)
    subprocess.run(['pluginkit', '-a', str(extension)], check=True)
    print('Installed Lunavect widget registration restored after temporary-copy cleanup.')
    break
print('Temporary distribution registrations removed; installed files and preferences unchanged.')
PY
