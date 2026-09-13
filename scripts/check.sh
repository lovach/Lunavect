#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
umask 077
# The override is a parent directory, never an existing build to reuse/delete.
# Each invocation owns a fresh child, even for simultaneous runs in one checkout.
DERIVED_PARENT="${WEEKLEFT_CHECK_DERIVED_DATA:-${TMPDIR:-/tmp}/Lunavect-Check.noindex}"
mkdir -p "$DERIVED_PARENT"
RUN_DIR=$(mktemp -d "$DERIVED_PARENT/run.XXXXXXXX")
DERIVED_DIR="$RUN_DIR/DerivedData.noindex"
RESULT_DIR=""
REPORT=""
REPORTER="$PROJECT_ROOT/scripts/check-report.py"

# Never inspect/unregister another app or delete the shared parent directory.
cleanup_check() {
  local status=$?
  trap - EXIT
  if [ -n "$REPORT" ]; then
    local report_status=0
    python3 "$REPORTER" finish "$REPORT" "$status" || report_status=$?
    if [ "$status" -eq 0 ]; then status=$report_status; fi
  fi
  rm -rf "$RUN_DIR"
  if [ -n "$RESULT_DIR" ]; then printf '\nCheck evidence: %s\n' "$RESULT_DIR"; fi
  exit "$status"
}
trap cleanup_check EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RESULT_PARENT="${WEEKLEFT_CHECK_RESULTS:-$PROJECT_ROOT/build/check-results}"
mkdir -p "$RESULT_PARENT"
RESULT_DIR=$(mktemp -d "$RESULT_PARENT/run.XXXXXXXX")
REPORT="$RESULT_DIR/check-results.json"
python3 "$REPORTER" init "$REPORT"
run_check() { python3 "$REPORTER" run "$REPORT" "$@"; }

run_check source_checkpoint python3 scripts/build-manifest.py begin --source-root "$PROJECT_ROOT" --output "$RESULT_DIR/build-manifest.json" --kind unsigned-check
run_check python_tests python3 -B -m unittest discover -s Tests/Scripts
run_check swift_tests swift test --jobs 2

# The compatibility check runs in its own process, never in the widget host.
BACKGROUND_CHECK="$RUN_DIR/background-check"
run_check widget_probe_build clang -fobjc-arc -framework Foundation -IWidget Tests/WidgetRuntime/BackgroundDescriptorCheck.m Widget/WidgetBackground.m -o "$BACKGROUND_CHECK"
run_check widget_fallback "$BACKGROUND_CHECK" --incompatible
# The reporter accepts exit 77 only for this explicitly optional ABI probe.
run_check widget_private_abi "$BACKGROUND_CHECK"

# Compile both native targets without using a developer account or provisioning.
# Use the checked-in Xcode project so CI also verifies it is buildable.
run_check unsigned_build xcodebuild -quiet \
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

run_check hook_helper python3 "$PROJECT_ROOT/scripts/verify-hook-helper.py" "$DERIVED_DIR/Build/Products/Release/Lunavect.app"
run_check product_resources python3 "$PROJECT_ROOT/scripts/verify-product-resources.py" "$DERIVED_DIR/Build/Products/Release/Lunavect.app" --source-root "$PROJECT_ROOT"
INTENT_BUNDLE_PATHS=$(python3 - "$DERIVED_DIR/Build/Products/Release/Lunavect.app" "$DERIVED_DIR/Build/Products/Release/Lunavect.app/Contents/PlugIns/LunavectWidget.appex" <<'PY'
import json, sys
print(json.dumps(sys.argv[1:]))
PY
)
run_check intent_resources env LUNAVECT_INTENT_BUNDLE_PATHS="$INTENT_BUNDLE_PATHS" swift test --jobs 2 --filter ActivityWidgetIntentLocalizationTests.testBuiltAppAndWidgetContainResolvableIntentMetadata
run_check build_provenance python3 scripts/build-manifest.py finalize --source-root "$PROJECT_ROOT" --manifest "$RESULT_DIR/build-manifest.json" --app "$DERIVED_DIR/Build/Products/Release/Lunavect.app"
