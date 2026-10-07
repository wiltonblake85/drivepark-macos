#!/bin/zsh
# Packages DrivePark.app into a signed DMG, and notarizes it when credentials
# are available.
#
# Gatekeeper on another person's Mac is the whole point. A Developer ID
# signature alone still gets "Apple could not verify DrivePark is free of
# malware", because signing proves who built it and notarization proves Apple
# scanned it. Both are required before anyone can double-click a download.
#
# Credentials: run once, interactively, then this script finds them.
#   xcrun notarytool store-credentials "drivepark" \
#     --apple-id <your Apple ID> --team-id 4G2DZU69L8 --password <app-specific>
# The app-specific password comes from appleid.apple.com, not your real one.
#
# Exit status is the release verdict (audit, Low, 2026-10-07). It used to
# print a hardened-runtime check that could not fail, sign the DMG with
# whatever identity it found first whatever DRIVEPARK_SIGN_IDENTITY said, and
# exit 0 with a disk image that was never notarized. Now:
#   0  signed, timestamped, hardened, notarized, stapled, and Gatekeeper
#      accepts it
#   1  a step failed; the message says which
#   2  built and signed, but NOT notarized (no credentials). Not a release.
set -e
cd "$(dirname "$0")/.."

fail() { echo "ERROR: $*" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
PROFILE="${DRIVEPARK_NOTARY_PROFILE:-drivepark}"
DIST="dist"
STAGE="$DIST/stage"
DMG="$DIST/DrivePark-$VERSION.dmg"

[[ "${DRIVEPARK_NO_TIMESTAMP:-}" == "1" ]] \
  && fail "DRIVEPARK_NO_TIMESTAMP=1 is set. A release needs a timestamped signature."

# One identity for the app and the disk image, chosen once.
IDENTITY="${DRIVEPARK_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}')
fi
[[ -n "$IDENTITY" ]] || fail "no Developer ID Application identity. A release cannot be ad-hoc signed."
export DRIVEPARK_SIGN_IDENTITY="$IDENTITY"

echo "==> Building and signing the app"
./scripts/build-app.sh
APP_SRC="${DRIVEPARK_INSTALL_DIR:-$HOME/Applications}/DrivePark.app"

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_SRC" "$STAGE/DrivePark.app"
ln -s /Applications "$STAGE/Applications"
APP="$STAGE/DrivePark.app"

echo "==> Checking the app's signature (notarization rejects any of these)"
codesign --verify --strict --deep "$APP" || fail "the app's signature does not verify."
DETAILS=$(codesign -d --verbose=2 "$APP" 2>&1)
echo "$DETAILS" | grep -qE '^CodeDirectory .*flags=.*runtime' \
  || fail "the app is not signed with the hardened runtime."
echo "$DETAILS" | grep -q '^Timestamp=' \
  || fail "the app's signature has no secure timestamp."
echo "$DETAILS" | grep -q '^Authority=Developer ID Application' \
  || fail "the app is not signed with a Developer ID Application certificate."
echo "    hardened runtime, timestamp and Developer ID: present"

echo "==> Building the disk image"
hdiutil create -volname "DrivePark" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"

codesign --force --timestamp --sign "$IDENTITY" "$DMG" \
  || fail "signing the disk image failed."
codesign --verify --strict "$DMG" || fail "the disk image's signature does not verify."
echo "==> Signed the disk image with $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo ""
  echo "NOT NOTARIZED. No notarytool credentials under the profile '$PROFILE'."
  echo "The disk image is built and signed, and it will still warn on another"
  echo "person's Mac until Apple has scanned it. This is not a release. To finish:"
  echo ""
  echo "  xcrun notarytool store-credentials \"$PROFILE\" \\"
  echo "    --apple-id <your Apple ID email> \\"
  echo "    --team-id 4G2DZU69L8 \\"
  echo "    --password <app-specific password from appleid.apple.com>"
  echo ""
  echo "then run this script again."
  echo "Disk image (unnotarized): $DMG"
  exit 2
fi

echo "==> Submitting to Apple. This usually takes a few minutes."
RESULT="$DIST/notarize-result.json"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
  --output-format json > "$RESULT" || true
STATUS=$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo "no answer")
if [[ "$STATUS" != "Accepted" ]]; then
  SUBMISSION=$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || echo "")
  echo "Apple's verdict: $STATUS" >&2
  if [[ -n "$SUBMISSION" ]]; then
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
  fi
  fail "notarization was not accepted."
fi
echo "    Accepted"

echo "==> Stapling the ticket so it works offline"
xcrun stapler staple "$DMG" || fail "stapling failed."
xcrun stapler validate "$DMG" || fail "the stapled ticket does not validate."

echo "==> Gatekeeper verdict on the finished article"
spctl -a -vv -t install "$DMG" || fail "Gatekeeper rejects the disk image."

echo ""
echo "Released: $DMG"
ls -lh "$DMG" | awk '{print $5, $9}'
