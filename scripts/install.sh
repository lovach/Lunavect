#!/bin/bash
set -euo pipefail
DERIVED_DIR="${WEEKLEFT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Weekleft.noindex}"
BUILD_CONFIGURATION="${WEEKLEFT_BUILD_CONFIGURATION:-Release}"
case "$BUILD_CONFIGURATION" in Debug|Release) ;; *) echo "Expected Debug or Release configuration" >&2; exit 2 ;; esac
APP_SOURCE="${LUNAVECT_INSTALL_SOURCE:-$DERIVED_DIR/Build/Products/$BUILD_CONFIGURATION/Lunavect.app}"
APP_DEST="$HOME/Applications/Lunavect.app"
LEGACY_APP="$HOME/Applications/Weekleft.app"
MIGRATED_LEGACY_APP=false
INSTALLED_NEW=false
CREATED_LEGACY_LINK=false
INSTALL_COMPLETE=false
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister
# Validate every destination before staging, migration, or registration changes.
for existing in "$APP_DEST" "$LEGACY_APP"; do
  if [ -L "$existing" ]; then
    if [ "$existing" != "$LEGACY_APP" ] || [ "$(readlink "$existing")" != 'Lunavect.app' ]; then
      echo 'Application path is an unrelated symlink; leaving it intact.' >&2; exit 1
    fi
  elif [ -e "$existing" ]; then
    if [ ! -d "$existing" ] || [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$existing/Contents/Info.plist" 2>/dev/null)" != 'com.weekleft.app' ]; then
      echo 'Application path belongs to another application; leaving it intact.' >&2; exit 1
    fi
  fi
done
if pgrep -x Weekleft >/dev/null || pgrep -x Lunavect >/dev/null; then
  echo 'Quit Lunavect before installing an updated build.' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_SOURCE"
python3 "$(dirname "$0")/verify-product-resources.py" "$APP_SOURCE"
python3 "$(dirname "$0")/verify-hook-helper.py" "$APP_SOURCE"
python3 "$(dirname "$0")/verify-app-groups.py" "$APP_SOURCE"
mkdir -p "$HOME/Applications"
# Replacing the bundle gives IconServices a new file identity. An in-place ditto
# can leave Spotlight showing the old icon even when the ICNS bytes are current.
STAGING_DIR=$(mktemp -d "$HOME/Applications/.Lunavect-install.XXXXXX")
cleanup_install() {
  result=$?
  trap - EXIT
  if [ "$INSTALL_COMPLETE" != true ]; then
    if [ "$CREATED_LEGACY_LINK" = true ]; then rm "$LEGACY_APP"; fi
    if [ "$INSTALLED_NEW" = true ]; then
      pluginkit -r "$APP_DEST/Contents/PlugIns/LunavectWidget.appex" || true
      "$LSREGISTER" -u "$APP_DEST" || true
      mv "$APP_DEST" "$STAGING_DIR/Failed.app" || { echo "Rollback failed; retained $STAGING_DIR" >&2; exit 1; }
    fi
    if [ -d "$STAGING_DIR/Previous.app" ]; then
      mv "$STAGING_DIR/Previous.app" "$APP_DEST" || { echo "Rollback failed; retained $STAGING_DIR" >&2; exit 1; }
      "$LSREGISTER" -f "$APP_DEST" || echo 'Previous app restored; LaunchServices registration needs retry.' >&2
      pluginkit -a "$APP_DEST/Contents/PlugIns/LunavectWidget.appex" || echo 'Previous app restored; widget registration needs retry.' >&2
    fi
    if [ -d "$STAGING_DIR/Legacy.app" ]; then
      mv "$STAGING_DIR/Legacy.app" "$LEGACY_APP" || { echo "Rollback failed; retained $STAGING_DIR" >&2; exit 1; }
      "$LSREGISTER" -f "$LEGACY_APP" || echo 'Legacy app restored; registration needs retry.' >&2
    fi
  fi
  rm -rf "$STAGING_DIR"
  exit "$result"
}
trap cleanup_install EXIT
ditto "$APP_SOURCE" "$STAGING_DIR/Lunavect.app"
codesign --verify --deep --strict "$STAGING_DIR/Lunavect.app"
if [ -d "$APP_DEST" ]; then
  python3 "$(dirname "$0")/migrate-app-group.py" --from-app "$APP_DEST" --to-app "$STAGING_DIR/Lunavect.app"
fi
# A live extension can keep the previous executable mapped across an in-place
# update, including its old WidgetKit descriptor. Restart only our installed
# extension before replacing its bundle. Do not reset chronod or other users' widgets.
python3 -c '
import os, signal, subprocess, sys
executable = sys.argv[1] + "/Contents/PlugIns/LunavectWidget.appex/Contents/MacOS/LunavectWidget"
for line in subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) == 2 and parts[1] == executable:
        try:
            os.kill(int(parts[0]), signal.SIGTERM)
            print("Stopped previous Lunavect widget extension before update")
        except ProcessLookupError:
            pass
' "$APP_DEST"
if [ -e "$APP_DEST" ]; then
  mv "$APP_DEST" "$STAGING_DIR/Previous.app"
fi
mv "$STAGING_DIR/Lunavect.app" "$APP_DEST"
INSTALLED_NEW=true
codesign --verify --deep --strict "$APP_DEST"
if [ -d "$LEGACY_APP" ] && [ ! -L "$LEGACY_APP" ]; then
  # Keep the uncompressed original available until every registration succeeds.
  BACKUP_DIR="$HOME/Library/Application Support/Weekleft/InstallBackups"
  mkdir -p "$BACKUP_DIR"
  BACKUP_STAGE=$(mktemp -d "$BACKUP_DIR/Weekleft-$(date +%Y%m%d-%H%M%S).XXXXXX")
  ditto -c -k --keepParent "$LEGACY_APP" "$BACKUP_STAGE/Weekleft.previous.zip"
  unzip -tq "$BACKUP_STAGE/Weekleft.previous.zip" >/dev/null
  "$LSREGISTER" -u "$LEGACY_APP" || true
  mv "$LEGACY_APP" "$STAGING_DIR/Legacy.app"
  MIGRATED_LEGACY_APP=true
fi
# Keep already trusted hooks/statusLine commands working at their exact old path.
# The compatibility link is hidden in Finder; the visible app is Lunavect.
if [ ! -e "$LEGACY_APP" ] && [ ! -L "$LEGACY_APP" ]; then
  ln -s Lunavect.app "$LEGACY_APP"
  CREATED_LEGACY_LINK=true
  chflags -h hidden "$LEGACY_APP"
fi
"$LSREGISTER" -u "$APP_SOURCE" || true
if [ -d "$DERIVED_DIR/Build/Products/Debug/Weekleft.app" ]; then
  "$LSREGISTER" -u "$DERIVED_DIR/Build/Products/Debug/Weekleft.app" || true
fi
# Explicitly remove the development appex too; unregistering its containing app
# alone leaves a competing WidgetKit entry on this macOS version.
pluginkit -r "$APP_SOURCE/Contents/PlugIns/LunavectWidget.appex" || true
# Register the installed host last: removing another copy of the same extension
# can invalidate WidgetKit's containing-bundle lookup even when timelines succeed.
"$LSREGISTER" -f "$APP_DEST"
pluginkit -a "$APP_DEST/Contents/PlugIns/LunavectWidget.appex"
INSTALL_COMPLETE=true
if [ "$MIGRATED_LEGACY_APP" = true ]; then
  # chronod retains an XPC service template pointing at the old executable even
  # after LaunchServices/PlugInKit registration changes. Refresh it only for the
  # physical Weekleft -> Lunavect migration; saved widget placements stay intact.
  printf 'Refreshing widget service after application rename; widgets may briefly reload.\n'
  /usr/bin/pkill -TERM -u "$(id -u)" -x chronod || true
  # The gallery keeps the containing app's old display name in its own process.
  /usr/bin/pkill -TERM -u "$(id -u)" -x NotificationCenter || true
fi
printf 'Installed: %s\n' "$APP_DEST"
