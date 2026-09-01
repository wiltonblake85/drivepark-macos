#!/bin/zsh
# Builds DrivePark.app from the DriveParkApp SwiftPM product and installs it
# into ~/Applications with an ad-hoc signature.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product DriveParkApp
APP="$HOME/Applications/DrivePark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DriveParkApp "$APP/Contents/MacOS/DrivePark"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built and installed: $APP"
