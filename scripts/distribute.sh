#!/bin/bash
# Xcode signs with the selected Apple account; no passwords or private keys here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-}"
VERSION="${2:-}"
BUILD="${3:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo 'Usage: scripts/distribute.sh archive|submit|export VERSION BUILD' >&2
  exit 2
fi
OUTPUT="${LUNAVECT_RELEASE_ROOT:-$HOME/Library/Developer/Xcode/Archives/Lunavect}"
ARCHIVE="$OUTPUT/Lunavect-$VERSION-$BUILD.xcarchive"
mkdir -p "$OUTPUT"
cd "$ROOT"
case "$ACTION" in
  archive)
    if [ -e "$ARCHIVE" ]; then echo 'Archive already exists; use a new build number.' >&2; exit 1; fi
    xcodebuild -project Weekleft.xcodeproj -scheme Weekleft -configuration Release \
      -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
      -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Lunavect-Distribution.noindex" \
      -xcconfig Config/Distribution.xcconfig -allowProvisioningUpdates \
      CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$VERSION" REGISTER_APP_WITH_LAUNCH_SERVICES=NO archive
    ;;
  submit)
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
    xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUTPUT/Notarized-$BUILD"
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
print('Temporary distribution registrations removed; installed app unchanged.')
PY
