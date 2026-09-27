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
# Registration tools and installed copies come from reassert-installed-widget.py:
# LUNAVECT_LSREGISTER, LUNAVECT_PLUGINKIT and LUNAVECT_INSTALLED_APPS let fixtures
# replace them, so tests never reach the host's Launch Services database.
python3 - "$ARCHIVE" "$OUTPUT" "$BUILD" "$ROOT" <<'PY'
from pathlib import Path
import importlib.util, plistlib, shutil, subprocess, sys, time
archive, output, build = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location('reassert_installed_widget', Path(sys.argv[4]) / 'scripts/reassert-installed-widget.py')
installed_widget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installed_widget)
copies = [archive / 'Products/Applications/Lunavect.app',
          output / f'Submission-{build}/Lunavect.app',
          output / f'Export-{build}/Lunavect.app',
          output / f'Notarized-{build}/Lunavect.app',
          Path.home() / 'Library/Developer/Xcode/DerivedData/Lunavect-Distribution.noindex/Build/Intermediates.noindex/ArchiveIntermediates/Weekleft/InstallationBuildProductsLocation/Applications/Lunavect.app']
copies.extend(archive.glob('Submissions/*/Lunavect.app'))
register, pluginkit = installed_widget.LSREGISTER, installed_widget.PLUGINKIT
registered = {line.split('path:', 1)[1].strip().rsplit(' (0x', 1)[0]
              for line in subprocess.check_output([register, '-dump'], text=True).splitlines()
              if line.strip().startswith('path:')}
# Xcode can remove its intermediate app before cleanup. A missing path cannot
# be unregistered by Launch Services. Restore just that known build product long
# enough to retire its existing record, then remove our temporary restoration.
restored = []
intermediate = copies[4]
archived = archive / 'Products/Applications/Lunavect.app'
if str(intermediate) in registered and not intermediate.exists() and not intermediate.is_symlink():
    if plistlib.loads((archived / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != 'com.weekleft.app':
        raise SystemExit('Unexpected archive source for registration cleanup')
    intermediate.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(archived), str(intermediate)], check=True)
    restored.append(intermediate)
try:
    for app in copies:
        if not (app / 'Contents/Info.plist').is_file():
            continue
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'com.weekleft.app':
            raise SystemExit('Unexpected app in distribution output')
        if str(app) in registered:
            # Launch Services may briefly reject a bundle just restored from the
            # archive. Retry only this owned path; persistent failure remains fatal.
            for attempt in range(3):
                try:
                    subprocess.run([register, '-u', str(app)], check=True)
                    break
                except subprocess.CalledProcessError:
                    # Another unregister can already have retired this record.
                    # Confirm absence rather than ignoring a real cleanup error.
                    fresh = subprocess.check_output([register, '-dump'], text=True)
                    remaining = {Path(line.split('path:', 1)[1].strip().rsplit(' (0x', 1)[0]).resolve()
                                 for line in fresh.splitlines() if line.strip().startswith('path:')}
                    if app.resolve() not in remaining:
                        break
                    if attempt == 2:
                        raise
                    time.sleep(0.5 * (attempt + 1))
        for extension in (app / 'Contents/PlugIns').glob('*.appex'):
            subprocess.run([pluginkit, '-r', str(extension)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for app in restored:
        shutil.rmtree(app)
    # Removing an archive's extension can invalidate the containing-bundle lookup
    # for the installed copy too. Reassert the installed host AFTER all removals.
    # Do not launch it, replace files, change defaults or restart system services.
finally:
    # With two installed copies only the running one is reasserted (with a warning).
    if installed_widget.reassert(installed_widget.default_installed_copies()):
        print('Installed Lunavect widget registration restored after temporary-copy cleanup.')
print('Temporary distribution registrations removed; installed files and preferences unchanged.')
PY
