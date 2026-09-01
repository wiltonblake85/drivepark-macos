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
set -e
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
PROFILE="${DRIVEPARK_NOTARY_PROFILE:-drivepark}"
DIST="dist"
STAGE="$DIST/stage"
DMG="$DIST/DrivePark-$VERSION.dmg"

echo "==> Building and signing the app"
./scripts/build-app.sh

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$HOME/Applications/DrivePark.app" "$STAGE/DrivePark.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Building the disk image"
hdiutil create -volname "DrivePark" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$DMG"
  echo "==> Signed the disk image"
fi

echo "==> Hardened runtime check (notarization rejects without it)"
codesign -d --verbose=2 "$STAGE/DrivePark.app" 2>&1 | grep -E "flags" || true

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "==> Submitting to Apple. This usually takes a few minutes."
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling the ticket so it works offline"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "==> Gatekeeper verdict on the finished article"
  spctl -a -vv -t install "$DMG" 2>&1 | head -4
else
  echo ""
  echo "NOT NOTARIZED. No notarytool credentials under the profile '$PROFILE'."
  echo "The disk image is built and signed, and it will still warn on another"
  echo "person's Mac until Apple has scanned it. To finish:"
  echo ""
  echo "  xcrun notarytool store-credentials \"$PROFILE\" \\"
  echo "    --apple-id <your Apple ID email> \\"
  echo "    --team-id 4G2DZU69L8 \\"
  echo "    --password <app-specific password from appleid.apple.com>"
  echo ""
  echo "then run this script again."
fi

echo ""
echo "Disk image: $DMG"
ls -lh "$DMG" 2>/dev/null | awk '{print $5, $9}'
