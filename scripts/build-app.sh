#!/bin/zsh
# Builds DrivePark.app from the DriveParkApp SwiftPM product and installs it
# into ~/Applications.
#
# Signing identity matters more than it looks. An ad-hoc signature gives the
# app a new code identity on every single build, and macOS treats each build as
# a different app. Two consequences, both observed on 2026-09-01:
#   - Notification Center never registers the app at all. requestAuthorization
#     shows no prompt, posting a notification goes nowhere, and nothing errors.
#     The app simply has no entry in ncprefs. Sound still works, because
#     NSSound has no such requirement, which is why the chime played while the
#     banner never appeared.
#   - TCC re-asks for removable-volume access after every rebuild.
# A Developer ID identity fixes both, and is required for notarization anyway.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product DriveParkApp
APP="$HOME/Applications/DrivePark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DriveParkApp "$APP/Contents/MacOS/DrivePark"
cp scripts/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
# Classic four-byte type/creator file. Xcode still writes it, and some
# subsystems that inspect bundles predate reading Info.plist alone.
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Override with DRIVEPARK_SIGN_IDENTITY if you need a specific certificate.
IDENTITY="${DRIVEPARK_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}')
fi

if [[ -n "$IDENTITY" ]]; then
  # --options runtime is the hardened runtime, required for notarization.
  # --timestamp needs the network; fall back rather than fail the build.
  if codesign --force --options runtime --timestamp \
       --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with Developer ID (timestamped): $IDENTITY"
  else
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "Signed with Developer ID (no timestamp, network unavailable): $IDENTITY"
  fi
else
  codesign --force --sign - "$APP"
  echo "WARNING: ad-hoc signed. Notifications will not work and TCC will"
  echo "re-prompt on every build. Install a Developer ID certificate."
fi

echo "Built and installed: $APP"
