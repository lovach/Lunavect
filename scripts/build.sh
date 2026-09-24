#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DIR="${WEEKLEFT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Weekleft.noindex}"
BUILD_CONFIGURATION="${WEEKLEFT_BUILD_CONFIGURATION:-Release}"
SIGNING_CONFIG="${WEEKLEFT_SIGNING_CONFIG:-$PROJECT_ROOT/Config/Signing.xcconfig}"
if [ ! -f "$SIGNING_CONFIG" ]; then echo 'Signing configuration does not exist.' >&2; exit 2; fi
case "$BUILD_CONFIGURATION" in Debug|Release) ;; *) echo "Expected Debug or Release configuration" >&2; exit 2 ;; esac
cd "$PROJECT_ROOT"
# Keep generated bundles outside iCloud Documents: File Provider FinderInfo can break codesigning.
# Regenerate only with the XcodeGen version that CI's parity check pins: another
# version rewrites the tracked project and schemes with unrelated drift.
PINNED_XCODEGEN=$(sed -n "s/^VERSION = '\([0-9.]*\)'\$/\1/p" "$PROJECT_ROOT/scripts/check-project-parity.py" || true)
if command -v xcodegen >/dev/null 2>&1; then
  FOUND_XCODEGEN=$(xcodegen --version 2>/dev/null || true)
  if [ -n "$PINNED_XCODEGEN" ] && [ "$FOUND_XCODEGEN" = "Version: $PINNED_XCODEGEN" ]; then
    xcodegen generate
  else
    echo "Skipping project generation: XcodeGen ${PINNED_XCODEGEN:-(unknown pin)} is required, found '${FOUND_XCODEGEN:-no version}'. Building the committed Lunavect.xcodeproj." >&2
  fi
fi
# WidgetKit caches descriptors by bundle identity/version. Reusing the same
# build number can retain the old opaque background after a local update.
BUILD_NUMBER=$(python3 - "$PROJECT_ROOT/project.yml" "$HOME/Applications/Lunavect.app/Contents/Info.plist" "/Applications/Lunavect.app/Contents/Info.plist" "$DERIVED_DIR/Build/Products/Debug/Lunavect.app/Contents/Info.plist" "$DERIVED_DIR/Build/Products/Release/Lunavect.app/Contents/Info.plist" <<'PYTHON'
import plistlib, re, sys
from pathlib import Path
versions = [int(re.search(r"CURRENT_PROJECT_VERSION: ([0-9]+)", Path(sys.argv[1]).read_text()).group(1))]
for path in sys.argv[2:]:
    try:
        with open(path, 'rb') as f:
            value = str(plistlib.load(f).get('CFBundleVersion', ''))
        if value.isdecimal(): versions.append(int(value))
    except (OSError, ValueError):
        pass
print(max(versions) + 1)
PYTHON
)
xcodebuild -project Lunavect.xcodeproj -scheme Weekleft -configuration "$BUILD_CONFIGURATION" -derivedDataPath "$DERIVED_DIR" -xcconfig "$SIGNING_CONFIG" -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" REGISTER_APP_WITH_LAUNCH_SERVICES=NO build
codesign --verify --deep --strict "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
python3 "$PROJECT_ROOT/scripts/verify-product-resources.py" "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app" --source-root "$PROJECT_ROOT"
python3 "$PROJECT_ROOT/scripts/verify-hook-helper.py" "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
python3 "$PROJECT_ROOT/scripts/verify-app-groups.py" "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
# Build products must never compete with the installed WidgetKit extension.
# Xcode/LaunchServices can still discover the nested appex while signing.
pluginkit -r "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app/Contents/PlugIns/LunavectWidget.appex" || true
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister -u "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app" || true
# Removing that registration can break the installed widget's lookup; reassert it last.
python3 "$PROJECT_ROOT/scripts/reassert-installed-widget.py" || echo 'Installed widget registration could not be reasserted; run scripts/install.sh.' >&2
printf '\nBuilt app: %s\n' "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
