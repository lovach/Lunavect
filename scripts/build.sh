#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DIR="${WEEKLEFT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Weekleft.noindex}"
BUILD_CONFIGURATION="${WEEKLEFT_BUILD_CONFIGURATION:-Release}"
case "$BUILD_CONFIGURATION" in Debug|Release) ;; *) echo "Expected Debug or Release configuration" >&2; exit 2 ;; esac
cd "$PROJECT_ROOT"
# Keep generated bundles outside iCloud Documents: File Provider FinderInfo can break codesigning.
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
# WidgetKit caches descriptors by bundle identity/version. Reusing the same
# build number can retain the old opaque background after a local update.
BUILD_NUMBER=$(python3 - "$PROJECT_ROOT/project.yml" "$HOME/Applications/Lunavect.app/Contents/Info.plist" "$DERIVED_DIR/Build/Products/Debug/Lunavect.app/Contents/Info.plist" "$DERIVED_DIR/Build/Products/Release/Lunavect.app/Contents/Info.plist" <<'PYTHON'
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
xcodebuild -project Weekleft.xcodeproj -scheme Weekleft -configuration "$BUILD_CONFIGURATION" -derivedDataPath "$DERIVED_DIR" -xcconfig Config/Signing.xcconfig -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" REGISTER_APP_WITH_LAUNCH_SERVICES=NO build
codesign --verify --deep --strict "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
python3 "$PROJECT_ROOT/scripts/verify-hook-helper.py" "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
python3 "$PROJECT_ROOT/scripts/verify-app-groups.py" "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
# Build products must never compete with the installed WidgetKit extension.
# Xcode/LaunchServices can still discover the nested appex while signing.
pluginkit -r "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app/Contents/PlugIns/LunavectWidget.appex" || true
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister -u "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app" || true
printf '\nBuilt app: %s\n' "$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app"
