# DrivePark — v1 Engine Spec

Name: DrivePark (settled 2026-09-01). CLI command: `park`. Date: 2026-08-31.
Evidence base: live diagnostic session on mac-lan with a TerraMaster 3-bay DAS
(volumes Backup, Plex, Bottom Drawer; all APFS; TDAS USB bridge). Behavior was
identical with the enclosure connected through the ProDock TB4 and connected
directly to the Mac, so the enclosure bridge is the governing hardware fact.

## 1. Problem statement (what the evidence showed)

1. Eject tools in this category act on the synthesized APFS container
   (disk5/7/9), never the physical disk underneath it (disk4/6/8). Disk
   Arbitration reports success in ~8 ms and macOS re-synthesizes the container
   from the still-attached physical store. The mapping that would prevent this,
   APFS container to physical store, is absent from the source I read.
2. Even a correct physical-disk eject does not stick: the TDAS bridge reports
   its media as Fixed (non-removable), so the eject verb cannot detach it.
   `diskutil eject disk4` printed "ejected" while disk4 remained attached with
   identical IORegistry ids (no re-enumeration ever occurred).
3. One volume unmount needed 3 solicitations over ~11 s with zero user
   feedback. Slow unmounts with silent progress read as "broken."
4. No existing tool verifies outcomes. They report the request's callback
   status, not the machine's actual state afterward.

Conclusion: on fixed-media multi-bay enclosures, "eject" is the wrong verb.
The correct product verb is PARK: unmount everything, verify it, hold it
unmounted, and state plainly when the enclosure is safe to power off.

## 2. Definitions

- Enclosure: all physical disks sharing one USB device ancestry (matched by
  vendor/product/serial and topology so it survives replug and port changes).
- Parked: every volume on every disk of the enclosure is verified unmounted
  AND remount attempts are being vetoed.
- Verified: a state read back from the system after the operation, never
  inferred from an operation's return status.
- Blocker: a process holding open files on a volume, causing a busy dissent.

## 3. Core loop

DISCOVER -> UNMOUNT -> VERIFY -> PARK (hold) -> REPORT, plus UNPARK.

1. DISCOVER. Enumerate external physical disks; map each APFS synthesized
   container to its physical store and each volume to its container; group
   disks into enclosures via IORegistry USB ancestry.
2. UNMOUNT. Per disk, sequentially (never parallel ejects at one bridge):
   unmount every volume in the container via Disk Arbitration. On busy
   dissent, enumerate blocker PIDs (libproc/proc_listpidspath), report app
   names, offer remedies (quit app, pause Spotlight for the volume, wait).
   Retry ladder: immediate, +2 s, +5 s, +10 s. Force is opt-in only, never
   default.
3. VERIFY. Re-read mount table and Disk Arbitration descriptions. A volume
   counts as unmounted only if the fresh read says so. Report per disk.
4. PARK. Register a Disk Arbitration mount-approval callback and dissent any
   automount of managed volume UUIDs while parked. This is the feature the
   incumbents lack: it keeps a re-presenting bridge from silently remounting.
   Additionally attempt a physical-disk eject as a courtesy spin-down (many
   fixed-media bridges spin drives down on STOP UNIT) and report its true
   effect honestly: "spun down" or "no effect", never "ejected" unless the
   device actually detached on re-read.
5. REPORT. Single line of truth: "Tower parked. Safe to power off." or the
   named reason why not, per disk, with the blocking process when known.
6. UNPARK. Drop the veto, mount volumes, verify mounts, report.

## 4. Failure taxonomy

- Busy dissent -> name blockers, remedies, retry ladder.
- Timeout/slow unmount -> live progress ("Plex: flushing, attempt 2/4").
- Fixed media -> park semantics; never promise detach.
- Disk vanished mid-operation -> treat as parked if volumes gone; re-discover.
- Partial park (2 of 3 disks) -> overall state is NOT PARKED; say which disk
  and why. No green light on partial success.

## 5. CLI v1 surface

- `park status`   read-only tree: enclosures, disks, volumes, mount state.
- `park now`      run the core loop; `--hold` keeps the veto active until
                  Ctrl-C or `park release`.
- `park release`  unpark (remount managed volumes).
- Exit codes: 0 parked/ok, 1 partial, 2 failed, 64 usage.

## 6. Non-goals for v1

No privileged helper (user-level unmounts sufficed in the diagnostic; add a
helper in v1.5 only if real dissents demand it), no encrypted-APFS unlocking,
no localization.

Superseded 2026-09-01: this section used to rule out the menu bar UI and sleep
automation. Both shipped. The menu bar app wraps the engine, and automatic
parking on sleep, display-off and screen lock landed in v0.2.

## 7. Verification principle (the product)

Never report success from a callback. Every claim the tool makes is a fresh
read of system state. This is the differentiator: on the day of the diagnosis,
both `diskutil` and a paid ejection utility reported "ejected" while all three
disks stayed attached.

## 8. Test plan (this hardware is the test bench)

- T1 park while idle (baseline; today's conditions).
- T2 park while Plex is actively serving a file (blocker naming).
- T3 park during a Finder copy onto Bottom Drawer (busy dissent + retry).
- T4 while parked, try to mount from Disk Utility (veto must dissent).
- T5 park, power tower off, power on, unpark (rediscovery by serial).
- T6 fourteen consecutive days of daily use with a one-line log per run.
Exit criterion for v1: 14/14 clean parks with truthful reporting.

## 9. Tech

Swift 6, SwiftPM executable, macOS 14+. DiskArbitration + IOKit + libproc.
v0 discovery parses `diskutil list -plist` / `diskutil info -plist` (stable,
read-only); all mutating operations go through Disk Arbitration natively.
Reference implementation for DA patterns: nielsmouthaan/ejectify-macos (MIT),
consulted but not copied.

## 10. Backlog from field tests

- T2 (2026-08-31, passed): blocker naming worked; IINA correctly identified.
  Two improvements surfaced:
  1. Translate DA status codes to plain words ("volume is busy") instead of
     raw hex like `DA status 0xc010`.
  2. Partial park should still hold: when 2 of 3 disks park, `--hold` should
     veto remounts for the parked subset instead of exiting. Today it exits 1
     before the hold engages.
  3. Consider naming the file(s) the blocker has open, not just the process.
- T4 (2026-08-31, passed): with `--hold` active, `diskutil mount disk9s1`
  failed with the veto's own message: Parked by park. Release restored 3/3.
  Improvement surfaced:
  4. Flush stdout after each print (setvbuf/FileHandle) so `--hold` progress
     is visible when stdout is a pipe, not only a terminal.
- Sleep acknowledgement, a v0.2 design rule. kIOMessageSystemWillSleep holds
  sleep open until IOAllowPowerChange answers, and macOS waits roughly 30 s
  before it stops caring. The retry ladder alone can burn 17 s in sleeps before
  any unmount work happens, so a sleep-triggered park runs against a 20 s
  deadline, and a backstop acknowledges at 22 s whatever the park managed.
  Sleep is never vetoed. A drive tool that keeps your Mac awake is a worse bug
  than an unparked drive.
- Enclosure stall (2026-08-31, found by accident, fixed the same night). The
  TDAS bridge stopped answering `diskutil info` on all three bays while
  `diskutil list`, `df`, and `diskutil info` on the internal disk kept working.
  Every diskutil call the tool made blocked in read() with no timeout, so the
  CLI hung forever and the menu bar app's 30-second refresh timer stacked up a
  new hung child process every cycle, in silence, six of them before anyone
  looked. A tool that promises the truth about stuck drives cannot hang on one.
  Fixed: a 10 s timeout on every diskutil call, both pipes drained because an
  undrained stderr is its own deadlock, a timed-out disk reported as NOT
  ANSWERING instead of with "?" in every field, and a refresh timer that
  refuses to overlap itself. Verified against the live stall: 30 s to a full
  honest report, where the previous build never returned at all.
- Non-APFS support shipped (2026-08-31): discovery now includes direct
  partitions (exFAT, FAT32, NTFS, HFS+); proven against a software exFAT
  drive that DrivePark unmounted, ejected, and fully detached. `--only diskN`
  scopes park/release to one disk. Remaining edge cases: partitionless
  "superfloppy" volumes, and APFS containers spanning multiple physical
  stores (Fusion-style).
