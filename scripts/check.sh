#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DIR="${WEEKLEFT_CHECK_DERIVED_DATA:-${TMPDIR:-/tmp}/Lunavect-Check}"
cd "$PROJECT_ROOT"

# macOS can discover even unsigned test products and list them as a second app.
# Remove only this script's generated bundle after the build (also on failure).
cleanup_check_app() {
  local app="$DERIVED_DIR/Build/Products/Release/Lunavect.app"
  if [ -d "$app" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" = 'com.weekleft.app' ]; then
    pluginkit -r "$app/Contents/PlugIns/LunavectWidget.appex" >/dev/null 2>&1 || true
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" || true
    rm -rf "$app"
  fi
}
trap cleanup_check_app EXIT

python3 -B -m unittest discover -s Tests/Scripts
swift test

# The compatibility check runs in its own process, never in the widget host.
BACKGROUND_CHECK=$(mktemp "${TMPDIR:-/tmp}/lunavect-background.XXXXXX")
clang -fobjc-arc -framework Foundation -IWidget Tests/WidgetRuntime/BackgroundDescriptorCheck.m Widget/WidgetBackground.m -o "$BACKGROUND_CHECK"
"$BACKGROUND_CHECK" --incompatible
BACKGROUND_STATUS=0
"$BACKGROUND_CHECK" || BACKGROUND_STATUS=$?
rm -f "$BACKGROUND_CHECK"
if [ "$BACKGROUND_STATUS" -eq 77 ]; then
  printf 'SKIP: WidgetKit descriptor ABI is unsupported; standard background is used.\n'
elif [ "$BACKGROUND_STATUS" -ne 0 ]; then
  exit "$BACKGROUND_STATUS"
fi

# Compile both native targets without using a developer account or provisioning.
# Use the checked-in Xcode project so CI also verifies it is buildable.
xcodebuild -quiet \
  -project Weekleft.xcodeproj \
  -scheme Weekleft \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  REGISTER_APP_WITH_LAUNCH_SERVICES=NO \
  build

python3 "$PROJECT_ROOT/scripts/verify-hook-helper.py" "$DERIVED_DIR/Build/Products/Release/Lunavect.app"
