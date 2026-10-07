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
#
# Every failure stops the script (audit, Low, 2026-10-07). It used to drop
# --timestamp silently when signing failed, and kill a running DrivePark
# without asking. Environment:
#   DRIVEPARK_SIGN_IDENTITY   the certificate to sign with (default: the first
#                             Developer ID Application identity found)
#   DRIVEPARK_NO_TIMESTAMP=1  sign without a secure timestamp, for a build with
#                             no network. Said out loud; package.sh refuses it.
#   DRIVEPARK_QUIT_RUNNING=1  quit a running DrivePark without asking, for a
#                             script with no terminal to ask at
#   DRIVEPARK_INSTALL_DIR     where to install (default ~/Applications)
set -e
cd "$(dirname "$0")/.."

INSTALL_DIR="${DRIVEPARK_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/DrivePark.app"

# The build number, from the commit count, so every build that ships is
# distinguishable from the last. It was hard-coded to 1.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null) || {
  echo "ERROR: cannot derive the build number: this is not a git checkout." >&2
  exit 1
}
# Stand the watchdog down for the duration. Its whole job is to relaunch
# DrivePark the moment the app disappears, and during this script the app
# disappears on purpose and the bundle it would relaunch is briefly
# half-written. Launching a half-written bundle is how the app vanished with no
# crash report on 2026-09-01.
DOMAIN="com.wiltonblake.drivepark"
defaults write "$DOMAIN" watchdogPausedUntil -float $(( $(date +%s) + 300 ))
trap 'defaults delete "$DOMAIN" watchdogPausedUntil 2>/dev/null || true' EXIT

# The menu bar app running out of the bundle about to be replaced, if any.
#
# rm -rf on a running app does not error, it just quietly kills the process a
# moment later: macOS validates signed pages that no longer exist, and with a
# hardened runtime it is less forgiving still. No crash report, no log line,
# nothing. It cost an afternoon on 2026-09-01, when the app vanished from the
# menu bar and the only evidence was its absence.
#
# The watchdog is the same executable, started by launchd with the RELATIVE
# argv "Contents/MacOS/DrivePark", so it is told apart by the pid launchd
# reports for the agent. It is restarted on the new binary below.
AGENT="gui/$(id -u)/com.wiltonblake.drivepark.agent"
WATCHDOG_PID=$(launchctl print "$AGENT" 2>/dev/null | awk '/^\tpid = / {print $3; exit}')
running_app_pids() {
  local pid
  for pid in $(pgrep -x DrivePark 2>/dev/null); do
    [[ "$pid" == "$WATCHDOG_PID" ]] && continue
    [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == "$APP/Contents/MacOS/DrivePark" ]] && echo "$pid"
  done
}

# Asked before the build, not after, so nobody waits through a release build
# to be told no. It used to quit the app and then pkill it, unasked.
WAS_RUNNING=0
if [[ -n "$(running_app_pids)" ]]; then
  if [[ "${DRIVEPARK_QUIT_RUNNING:-}" != "1" ]]; then
    if [[ ! -t 0 ]]; then
      echo "ERROR: DrivePark is running from $APP and there is no terminal to ask." >&2
      echo "Quit it from its menu first, or set DRIVEPARK_QUIT_RUNNING=1." >&2
      exit 1
    fi
    echo "DrivePark is running from $APP. Installing this build means quitting it;"
    echo "any veto it holds drops, and parked drives stay unmounted."
    if ! read -q "REPLY?Quit DrivePark and install? [y/N] "; then
      echo ""
      echo "Left running. Nothing was built or installed."
      exit 1
    fi
    echo ""
  fi
  WAS_RUNNING=1
fi

swift build -c release --product DriveParkApp

if [[ "$WAS_RUNNING" == "1" ]]; then
  echo "Quitting the running copy"
  # The app's own Quit path: it stamps quitRequestedAt, so the watchdog
  # stands down instead of relaunching it into a half-written bundle.
  osascript -e 'quit app "DrivePark"' >/dev/null 2>&1 || true
  for _ in {1..10}; do
    [[ -z "$(running_app_pids)" ]] && break
    sleep 1
  done
  if [[ -n "$(running_app_pids)" ]]; then
    echo "ERROR: DrivePark did not quit within 10 s. It was not killed; quit it" >&2
    echo "from its menu, then run this again." >&2
    exit 1
  fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DriveParkApp "$APP/Contents/MacOS/DrivePark"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
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
  # --timestamp needs the network. A signature without one cannot be
  # notarized, so a failure here stops the build; it used to fall back to
  # an untimestamped signature and say nothing a script would notice.
  if [[ "${DRIVEPARK_NO_TIMESTAMP:-}" == "1" ]]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "WARNING: signed WITHOUT a secure timestamp (DRIVEPARK_NO_TIMESTAMP=1)."
    echo "Fine for this Mac. It cannot be notarized or shipped."
  else
    if ! codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"; then
      echo "ERROR: signing with a timestamp failed (is the network up?)." >&2
      echo "For a local build only: DRIVEPARK_NO_TIMESTAMP=1 $0" >&2
      exit 1
    fi
    echo "Signed with Developer ID (timestamped): $IDENTITY"
  fi
else
  codesign --force --sign - "$APP"
  echo "WARNING: ad-hoc signed. Notifications will not work and TCC will"
  echo "re-prompt on every build. Install a Developer ID certificate."
fi

# The agent runs this binary in watchdog mode, so it needs a kick to pick up
# the new one. Independent of the app now: restarting the watchdog no longer
# restarts, or kills, the copy showing the menu bar icon.
if [[ "$INSTALL_DIR" == "$HOME/Applications" ]] && launchctl print "$AGENT" >/dev/null 2>&1; then
  launchctl kickstart -k "$AGENT" >/dev/null 2>&1 \
    && echo "Watchdog restarted on the new binary" \
    || echo "WARNING: the watchdog agent would not restart"
fi

if [[ "$WAS_RUNNING" == "1" ]]; then
  open "$APP"
  echo "Relaunched, because it was running before this build"
fi

echo "Built and installed: $APP (build $BUILD_NUMBER)"
