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
