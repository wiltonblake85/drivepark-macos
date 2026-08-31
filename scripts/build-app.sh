#!/bin/zsh
# Builds Park.app from the ParkApp SwiftPM product and installs it
# into ~/Applications with an ad-hoc signature.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product ParkApp
APP="$HOME/Applications/Park.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ParkApp "$APP/Contents/MacOS/Park"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built and installed: $APP"
