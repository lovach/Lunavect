# Updates and release packaging

Lunavect uses Sparkle for signed updates distributed through GitHub Releases. The dependency version is pinned in `Package.swift` and `project.yml`.

## Updating the app

Use **Settings → Updates** to check for updates or change automatic checks and downloads. A ready update is shown in the menu bar and session panel. Automatic installation is scheduled for an ordinary app quit; users can also apply it through the updater interface. Lunavect does not terminate Claude or Codex to install its own update.

Update requests go to GitHub and its download infrastructure. Session data and activity history are not attached. Builds without a valid update feed and public key do not start the updater. See [Privacy and permissions](../PRIVACY.md#network-requests).

The [first public release](https://github.com/lovach/Lunavect/releases/tag/v0.1.0) is 0.1.0 (103). Testing an update between two different public versions is still an open item in [verification](verification.md).

## Preparing a release

For a new Lunavect release, preserve its signing identity, bundle IDs, App Group, update feed and Ed25519 update key. Create a new key only for a separate fork or a planned key migration, not for an ordinary update.

1. Run the project checks and inspect the relevant live behavior. Choose a build number higher than every published build.
2. Build and export a Developer ID signed app. Complete notarization and staple the ticket. Do not edit the bundle afterward.
3. Package the signed update ZIP, appcast and DMG in a new output directory.
4. Publish them together with checksums in a stable GitHub Release. The appcast's ZIP URL must point to that exact release tag.
5. Verify the downloaded files, then update the README, installation guide and Homebrew cask to the intended DMG and its checksum.
6. Test an actual upgrade from the previous public app, including retained settings, client connections and widget data. Check disabled automatic updates, offline/retry and rejection of a damaged signature.

A local build or successful packaging command does not establish public download or upgrade behavior. Keep the older public artifacts available at their original URLs.

## Signing and export

Public build configuration is in `Config/Distribution.xcconfig` and `Config/Updates.xcconfig`. Private signing and update keys stay outside the repository.

The following commands show the first release's version and build. For a new release, replace them with the intended version and a higher build number:

```sh
./scripts/distribute.sh archive 0.1.0 103
./scripts/distribute.sh submit 0.1.0 103
# After Apple's notarization completes:
./scripts/distribute.sh export 0.1.0 103
```

The distribution workflow uses the Apple account configured in Xcode. Export reports when notarization has not yet completed. A completed export contains the app's notarization ticket.

The signed macOS App Group is `<TEAM_ID>.com.lunavect.shared`; its prefix must match the signing team. Bundle IDs remain `com.weekleft.app` and `com.weekleft.app.widget`. The app does not use this group for Keychain access. See [Apple's App Group documentation](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

The local install script can migrate Lunavect's shared files when moving from a development App Group to the distribution group. It preserves source files and does not overwrite conflicting destination data. Ordinary public updates keep the same team and container. This local migration script is not a claim that every clean-install or upgrade path has been tested.

## Update keys for a fork

Resolve the pinned dependencies with `swift package resolve`. Sparkle tools are available in `.build/artifacts/sparkle/Sparkle/bin/`.

Use Sparkle's `generate_keys` to create your own Ed25519 key. Store the private key in Keychain or a protected location outside the repository. If packaging uses a key file, export it with the documented `generate_keys -x` option and restrict access to that file. Never put its contents in a commit or build log.

Set your own repository and public key in the build configuration. These placeholders are for a fork and must be replaced:

```xcconfig
// $() preserves the URL slashes in xcconfig syntax.
LUNAVECT_UPDATE_FEED_URL = https:/$()/github.com/OWNER/REPOSITORY/releases/latest/download/appcast.xml
LUNAVECT_UPDATE_PUBLIC_KEY = BASE64_PUBLIC_ED25519_KEY
```

Keep the public key consistent with the private key used to sign updates. If you raise the minimum macOS version, retain earlier compatible entries in the appcast according to Sparkle's publishing guide.

## Package the updater files

Use the exported, notarized app and a new output directory:

```sh
python3 scripts/package-update.py \
  --app '/path/to/Lunavect.app' \
  --output '/path/to/new-release-assets' \
  --key-file '/private/location/sparkle.key'
```

The script checks release configuration, codesign, Gatekeeper and the notarization ticket. It creates the ZIP and signed appcast, then checks signatures and the public key in the app. It does not publish files. Do not edit the appcast after signing.

## Package the DMG

Keep packaging dependencies and output outside the repository:

```sh
python3 -m venv /path/outside-repository/dmg-venv
/path/outside-repository/dmg-venv/bin/pip install -r scripts/dmg/requirements.txt
/path/outside-repository/dmg-venv/bin/python scripts/package-dmg.py \
  --app '/path/to/Notarized-103/Lunavect.app' \
  --output '/path/to/release-assets/Lunavect-0.1.0.dmg'
```

Replace these paths and version numbers with your exported app and intended output. The DMG is a read-only image containing the app and an Applications link. Its Finder layout uses `scripts/dmg/layout.json`; the AppKit background renderer provides 1× and 2× artwork. The pinned `dmgbuild` dependencies write the layout metadata without automating Finder. See the [installer screenshot](images/installer.jpg).

The packaging script verifies the app before packaging and inside the mounted image, and checks the background, window geometry, icon positions and visible files. Do not set `hide_extensions` on the signed app: changing its Finder metadata can invalidate strict signature checks.

The app's signature and notarization do not mean this script separately signs the DMG. The updater uses the ZIP and appcast, not the DMG. A cosmetic DMG revision can keep the same app version, but should have a distinct filename and checksum so existing release URLs retain their contents.

## Verify the public download

Compare the downloaded DMG's SHA-256 with the checksum published for that exact installer. Mount it and check the app:

```sh
codesign --verify --deep --strict '/Volumes/Lunavect/Lunavect.app'
spctl --assess --type execute '/Volumes/Lunavect/Lunavect.app'
xcrun stapler validate '/Volumes/Lunavect/Lunavect.app'
```

Use the actual mounted volume path. Then check installation, launch, retained settings, fresh client events and allowances. Widget placement and refresh require their own desktop check.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [customization](https://sparkle-project.org/documentation/customization/), [gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/), [publishing](https://sparkle-project.org/documentation/publishing/).
