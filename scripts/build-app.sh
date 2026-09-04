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
# Stand the watchdog down for the duration. Its whole job is to relaunch
# DrivePark the moment the app disappears, and during this script the app
# disappears on purpose and the bundle it would relaunch is briefly
# half-written. Launching a half-written bundle is how the app vanished with no
# crash report on 2026-09-01.
DOMAIN="com.wiltonblake.drivepark"
defaults write "$DOMAIN" watchdogPausedUntil -float $(( $(date +%s) + 300 ))
trap 'defaults delete "$DOMAIN" watchdogPausedUntil 2>/dev/null || true' EXIT

swift build -c release --product DriveParkApp
APP="$HOME/Applications/DrivePark.app"

# Stop a running copy before replacing the bundle underneath it.
#
# rm -rf on a running app does not error, it just quietly kills the process a
# moment later: macOS validates signed pages that no longer exist, and with a
# hardened runtime it is less forgiving still. No crash report, no log line,
# nothing. It cost an afternoon on 2026-09-01, when the app vanished from the
# menu bar and the only evidence was its absence.
WAS_RUNNING=0
if pgrep -x DrivePark >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "Stopping the running copy first"
  osascript -e 'quit app "DrivePark"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -x DrivePark >/dev/null 2>&1 || break
    sleep 1
  done
  # -x matches the executable name. -f with the full path silently misses the
  # launchd-started copy, whose argv is the RELATIVE "Contents/MacOS/DrivePark"
  # that BundleProgram gives it.
  pkill -x DrivePark >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DriveParkApp "$APP/Contents/MacOS/DrivePark"
cp scripts/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
# Classic four-byte type/creator file. Xcode still writes it, and some
# subsystems that inspect bundles predate reading Info.plist alone.
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The watchdog agent. SMAppService requires the plist to live here.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp scripts/LaunchAgent.plist \
   "$APP/Contents/Library/LaunchAgents/com.wiltonblake.drivepark.agent.plist"

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

# The agent runs this binary in watchdog mode, so it needs a kick to pick up
# the new one. Independent of the app now: restarting the watchdog no longer
# restarts, or kills, the copy showing the menu bar icon.
AGENT="gui/$(id -u)/com.wiltonblake.drivepark.agent"
if launchctl print "$AGENT" >/dev/null 2>&1; then
  launchctl kickstart -k "$AGENT" >/dev/null 2>&1 \
    && echo "Watchdog restarted on the new binary" \
    || echo "WARNING: the watchdog agent would not restart"
fi

if [[ "$WAS_RUNNING" == "1" ]]; then
  open "$APP"
  echo "Relaunched, because it was running before this build"
fi

echo "Built and installed: $APP"
