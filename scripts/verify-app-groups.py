#!/usr/bin/env python3
"""Verify the app/widget sharing contract in a signed macOS build."""
import fnmatch
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
expected = None
expected_team = None
extensions = list((app / "Contents/PlugIns").glob("*.appex"))
if len(extensions) != 1:
    sys.exit("Expected exactly one embedded widget extension")
for bundle in (app, extensions[0]):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    group = info.get("WeekleftAppGroup")
    if not group or (expected is not None and group != expected):
        sys.exit(f"App Group mismatch: {bundle.name}")
    expected = group
    signature = subprocess.check_output(["codesign", "-dvv", str(bundle)], stderr=subprocess.STDOUT, text=True)
    match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", signature, re.MULTILINE)
    team = match.group(1) if match else None
    if team is None or (expected_team is not None and team != expected_team):
        sys.exit(f"App/widget signing team mismatch: {bundle.name}")
    expected_team = team
    entitlements = plistlib.loads(subprocess.check_output(
        ["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.DEVNULL))
    if group not in entitlements.get("com.apple.security.application-groups", []):
        sys.exit(f"App Group missing from signature: {bundle.name}")
    if group.startswith("group."):
        profile = bundle / "Contents/embedded.provisionprofile"
        if not profile.exists():
            sys.exit(f"App Group requires provisioning profile: {bundle.name}")
        data = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(profile)], stderr=subprocess.DEVNULL))
        groups = data.get("Entitlements", {}).get("com.apple.security.application-groups", [])
        if not any(fnmatch.fnmatchcase(group, value) for value in groups):
            sys.exit(f"App Group not authorized by provisioning profile: {bundle.name}")
    elif not group.startswith(team + "."):
        sys.exit(f"Unprovisioned App Group must match its signing team: {bundle.name}")
print("App and widget sharing contract verified")
