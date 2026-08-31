# Park

A macOS menu bar utility for people whose external drives never actually eject.

## Why this exists

I run three drives in a multi-bay enclosure. Clicking eject looked like it
worked for years: the volumes vanished from Finder, the tools reported
success, and the disks stayed attached the whole time. When I finally read
the Disk Arbitration logs while reproducing it, two things fell out:

1. On APFS drives, ejecting "the whole disk" of a volume gives you the
   synthesized APFS container, not the physical disk underneath it. macOS
   reports success in milliseconds and rebuilds the container from the
   still-attached physical store. Nothing was ejected.
2. Many multi-bay enclosures report their drives as fixed, non-removable
   media. The eject verb has nothing to grab; no app can make those disks
   detach. A tool claiming otherwise is reporting a request status, not
   reality.

So "eject" is the wrong promise for this hardware. Park makes a different
one: unmount everything, verify it against a fresh read of system state,
hold it unmounted, and say plainly when the enclosure is safe to power off.

## What Park does

- One click parks the tower: Park unmounts every volume on every external
  disk, in sequence, with retries.
- When macOS refuses an unmount, Park names the process holding the files
  ("blocked by IINA (pid 97495)") so you aren't left guessing.
- Park verifies every claim; it re-reads the mount table after acting and
  never reports success from a callback.
- While parked, Park vetoes remount attempts, so a re-enumerating enclosure
  cannot silently bring volumes back. Even `diskutil mount` gets refused
  with "Parked by park".
- Park sends each parked disk a courtesy spin-down and reports what
  actually happened: spun down, detached, or still attached.
- The menu bar icon is the answer: a checkmark means it's safe to power off.

## Install

Build from source for now (a signed, notarized download is planned):

```sh
git clone https://github.com/wiltonblake85/park-macos.git
cd park-macos
./scripts/build-app.sh
open ~/Applications/Park.app
```

Requires macOS 14 or later and Xcode command line tools.

## CLI

The same engine ships as a command line tool:

```sh
swift build
.build/debug/park status    # true state of every external disk
.build/debug/park now       # park: unmount, verify, spin down
.build/debug/park now --hold  # park and keep the remount veto active
.build/debug/park release   # remount everything
```

## Status

Early. Built and tested daily against a three-bay TerraMaster DAS full of
APFS drives, which is exactly the hardware this class of tool usually fails
on. SPEC.md holds the engine spec and the evidence behind it.

## License

MIT. See LICENSE.
