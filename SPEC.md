# DrivePark: v1 Engine Spec

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
- Notifications refused at registration (2026-09-01, OPEN).
  UNUserNotificationCenter reports authorizationStatus denied with
  "Notifications are not allowed for this application", and no prompt is ever
  shown. The app never appears in ncprefs at all, so macOS refuses before any
  of our code runs. Chimes are unaffected, because NSSound carries no such
  requirement, and that is the only reason the undock signal survives this.

  Ruled out by test rather than by reasoning, each one its own build and
  relaunch. Ad-hoc signing: re-signed with Developer ID, hardened runtime,
  timestamped, still denied. A stale daemon: usernoted killed and restarted,
  still denied. Install location: run from /Applications rather than the home
  folder, still denied. Notarization: submitted, Accepted by Apple, ticket
  stapled, installed by mounting the disk image and copying across the way a
  buyer would, still denied. An incomplete bundle: NSPrincipalClass, PkgInfo,
  a Resources directory, CFBundleInfoDictionaryVersion and the other keys
  Xcode always writes, all added, still denied.

  Untested and worth a fresh look. Whether LSUIElement is the blocker, though
  many menu bar apps post notifications happily. Whether this is macOS 27
  behaviour on build 26A5406e rather than anything about this app, which is
  the one hypothesis nothing here can rule out from inside. The diagnostics
  that produced every answer above live in the app and read back with
  `defaults read com.wiltonblake.drivepark`.
- Notch cards through Transom (2026-09-03, passed on hardware). The way
  around the banner refusal above, and the first working visual signal this
  app has had. Transom is a notch app on this Mac with a token-secured HTTP
  API on 127.0.0.1 and a transom:// URL scheme; DrivePark posts the same three
  sentences the notifier writes. Verified end to end: a real park of the three
  TDAS bays posted "Safe to undock" at 16:19:21, and a scoped park of Plex
  against a held file posted "Park failed, do not undock. Still mounted: Plex.
  Blocked by Plex: sleep (pid 61786)", persistent. Both confirmed in Transom's
  own history file, not inferred from an exit code.

  Two doors. The HTTP one needs a token and returns a real 200, which is the
  only channel that can tell delivered from swallowed. The transom:// one
  needs nothing, which is why it is the default: the notch works the moment
  DrivePark is installed. Transom's Keychain item is not readable from another
  process here (errSecItemNotFound, recorded as diag_transomKeychain), so the
  token is pasted in once through Set Transom token…, and the Keychain read is
  kept only as a first attempt in case that ever changes.

  Known limit, and it matters for this particular signal: Transom holds
  automation posts while a Focus mode is on, and shows them in the digest
  afterwards. Both verified cards came back with held: true. A card that says
  do not unplug is not the same kind of message as a build notification, and
  there is no field in schema v1 to say so. Raised as a Transom question, not
  a DrivePark one.

- Global shortcut (2026-09-01, passed on hardware). Control Option Command P
  registered through Carbon RegisterEventHotKey with no Accessibility
  permission requested, fired from outside the app, and toggled correctly in
  both directions: one press parked the tower, a second press released it, with
  all three volumes verified mounted afterward on a fresh read. This is the
  trigger that matters on a machine where idle sleep is held off by a power
  assertion, because it is the only one the user drives deliberately.
- Park timing, measured (2026-09-01). Six scoped parks across two TDAS bays,
  each followed by a release. Unmount durations in order: 11.26, 0.59, 0.79,
  0.51, 0.91, 10.83 seconds. Median sits under a second, and end to end a park
  runs about two seconds including discovery and the verify re-read.

  The distribution is bimodal rather than an average with noise around it. Four
  runs finished under a second, two took roughly eleven, and nothing in
  between. Both slow runs completed on a single solicitation instead of
  climbing the retry ladder, so the Disk Arbitration unmount call itself
  blocked for eleven seconds, and neither named a blocking process. The eleven
  seconds in the founding diagnostic came from three solicitations spread over
  a similar span, which is a different mechanism landing on the same number.
  What imposes the eleven is not yet known and is worth chasing.

  For the sleep path the tail matters and the median does not. Three volumes
  each drawing the slow case is thirty-three seconds against a twenty second
  budget, inside a macOS grace window of roughly thirty, so a sleep-triggered
  park of a full enclosure can genuinely run out of time. That is what the
  deadline is for. The report then has to say two of three parked and name the
  one it did not reach.
- Manage list, and a false assurance (2026-09-01). Volumes DrivePark must
  never touch, keyed on volume UUID. Disk-level identity is not reachable on
  this hardware: all three TDAS bays report the same IORegistryEntryName, the
  same MediaName and the same DeviceTreePath, and two of them the same byte
  size. There is no whole-disk serial to key on. `diskutil list -plist`
  already carries VolumeUUID for APFS volumes and for plain partitions, so the
  key costs no extra process launch and no extra place to hang. Ignored is
  absolute. Park Tower does not override it, naming the drive does not override
  it, and a disk carrying a mounted ignored volume is never spun down, because
  spinning the disk down under that volume breaks the same promise by another
  route.

  Building it produced a lie of the exact kind this project exists to prevent.
  `UserDefaults.standard` resolves per process, so `park ignore T7` wrote to a
  domain named after the CLI executable while the app read its own bundle
  domain and saw an empty set. The CLI printed "DrivePark will not unmount it"
  anyway, about a drive that was mid-copy at the time. Both processes now share
  one explicit suite. The general form is worth keeping: a setting is not saved
  until the process that acts on it has read it back.
- Veto ownership (2026-09-01, two defects out of one incident). The menu bar
  app was holding a mount veto over Plex and Backup. It survived a full power
  cycle of the enclosure and refused every remount attempt afterward, which is
  the standing-park-rule differentiator working correctly on real hardware, and
  it is also how the two defects surfaced. Killing the app cleared it and both
  volumes mounted on the next attempt. Scope note, because the first draft of
  this entry overreached: Bottom Drawer was never part of the test, so nothing
  here establishes whether the veto covered it. Wekesa mounted that one
  himself.
  1. `park release` cannot clear a veto the app holds. `parkedVolumeUUIDs`
     lives in process memory, so the CLI clears its own empty copy, reports the
     app's dissent string back to the user, and stops there. No remedy short of
     quitting the app. Telling the truth and offering no way out is half a
     product. The CLI needs to reach the app, or at minimum name the app as the
     holder and point at the menu.
  2. A park that unmounts nothing still arms the veto. After a run that
     verified three unmounts, `stillMounted.isEmpty` is true. When nothing was
     mounted in the first place it is true as well, and the code has no way to
     tell those two events apart, so a stray park against already-unmounted
     drives arms a standing veto over them and says nothing about it. Parked
     has to mean this run verified these volumes unmounted.
- Attributing a state change to your own fix (2026-09-01, the reasoning error
  behind the entry above). That draft claimed all three volumes mounted on
  their own once the veto died, and leaned on Bottom Drawer as the proof.
  Bottom Drawer was never in the experiment. A person unparked it by hand while
  the session was reading status. A fresh read tells you what is true and never
  tells you who did it, so an isolation test covers exactly what it toggled and
  nothing else, and on a machine with someone sitting at it that gap is where
  false causes get written down.
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

### Turning the watchdog off killed the app, 2026-09-03

Wekesa flipped "Keep DrivePark running" and the menu bar icon disappeared. It
never came back, and there was no crash report, because nothing crashed.

The log is unambiguous:

```
12:18:19.681  agent [61239]  xpcproxy spawned with pid 61239
12:19:16.419  DrivePark[61239] (AppKit) perform action for menu item
12:19:16.439  agent [61239]  removing job: caller = smd
12:19:16.443  agent [61239]  exited due to SIGTERM | sent by launchd[1]
12:19:16.443  gui/501        removing service: com.wiltonblake.drivepark.agent
```

Twenty milliseconds from the click to `caller = smd`, which is
`SMAppService.unregister()`. Four more to a dead process. The LaunchAgent's
`BundleProgram` pointed at `Contents/MacOS/DrivePark`, so the running app was the
job, and launchd removes a job by killing it. Switching the watchdog off killed
the thing it was watching, every time, and no code could have caught it: the code
that would have noticed was inside the process being killed.

Two smaller defects rode along. The status verification in `setEnabled` sits after
the `unregister()` call and was unreachable on that path, so a function whose own
comment says never swallow the failure swallowed it by ending mid-body. And
`SingleInstance.claim()` would have killed any replacement copy launched before
the unregister, because that copy was unsupervised and saw the old one still
alive.

DrivePark also appears in `JetsamEvent-2026-09-03-121822.ips`, at 1930 resident
pages, state active. That report snapshots all 777 live processes. Reading its
presence there as the cause would repeat the 2026-09-01 error of asking what
changed and answering with who changed it.

**The fix, and the two versions of it that did not work.**

First attempt: a separate `DriveParkWatchdog` executable in `Contents/MacOS`, with
the agent pointed at it. It compiled, and run by hand it worked, printing
`watching /Users/blake/Applications/DrivePark.app`. launchd refused to spawn it:

```
Could not find and/or execute program specified by service
Service could not initialize: copy_bundle_path(...), error 0x6f
last exit reason = OS_REASON_CODESIGNING
LWCR = { signing-identifier => com.wiltonblake.drivepark,
         team-identifier => 4G2DZU69L8, validation-category => 6 }
```

The job carries a launch requirement generated from the app that registered it. A
nested helper signed under its own identifier fails that requirement. Signed under
the app's identifier it fails code-signing validation instead. Both were tried.

What ships is one binary in two modes. launchd sets `XPC_SERVICE_NAME` to the job
label, so the agent-started process knows what it is and enters the watch loop
before SwiftUI builds a scene, putting nothing in the menu bar. `BundleProgram`
never changes, which means no installed copy has to be re-registered to receive
the fix. Unregistering now kills a process that owns no window and holds no veto.

**A third thing, found on the way.** The plist said `DriveParkWatchdog`,
`backgroundtaskmanagementd` had read `DriveParkWatchdog`, and launchd still
reported `program identifier = Contents/MacOS/DrivePark`. launchd keeps whatever
job definition it was handed at registration; `launchctl kickstart` runs that
stale one rather than the plist sitting on disk. `launchctl bootstrap` is no way
out, since `BundleProgram` resolves only inside the SMAppService context and the
call fails with an I/O error. So the app fingerprints its own agent plist now and
re-registers when the digest changes. That covers every future update that
touches the agent.

**And a fourth, caught by the compiler.** `Watchdog()` was built as a temporary,
so every `[weak self]` capture in the observer and the timer resolved to nil the
moment `run()` was called. It would have reported for duty and watched nothing, in
complete silence. It is a static now.

**And a fifth, caught by the test.** Quit was implemented as a ten-second stamp.
The watchdog read it, honoured it, cleared it, and five seconds later the poll
found no stamp and relaunched an app a human had just closed. Quit is not a
window, it is a state. The watchdog latches until it sees the app running again,
and the stamp still expires so a stale one cannot wedge a fresh watchdog after a
reboot, where launching the app is the right thing to do.

**Regression suite, 7 of 7 on live hardware.** One UI copy and one watchdog with
the agent running. The job removed while the app keeps its process id, which is
the defect. `kill -9` on the app answered by a relaunch. An orderly quit that
stays quit through later polls. A manual reopen that clears the stand-down and
resumes the watch. Exactly one icon throughout. Count instances with `pgrep`, not
by eye: two processes can render one visible icon while the menu bar refreshes.

### `park release` can now clear a veto the app holds, 2026-09-04

Open since 2026-09-03, and the last item in this file that broke a promise
rather than leaving one unverified.

The veto is a Disk Arbitration mount-approval callback registered on a DASession
and gated by `parkedVolumeUUIDs`. Both live in one process's memory, and that is
not an implementation detail that can be factored away: DA dissent comes from
the process that registered the callback. `park release` in a second process was
clearing its own empty copy of the set, attempting a mount, catching the app's
own dissent string, and printing it. It told the exact truth and offered no way
out.

So the holder publishes the fact that it is holding, and a release is now a
message to the holder rather than a reach into its memory. `VetoBroker` carries
the state in the shared preferences suite and rings a distributed notification
as a doorbell. Three things fall out of that:

`park status` names the holder by process and pid. A `park now --hold` in
another terminal holds a real veto and listens for nothing, so the CLI says so
and points at the Ctrl-C rather than pretending it can help.

The holder record carries a pid and is checked for liveness on every read. A
veto dies with the process that registered it, so a record left behind by a
crash describes a hold that no longer exists, and acting on it would block a
release that would otherwise have worked. Confirmed by test: after the holding
process was killed, the next `park status` stopped naming it and swept the
record.

The requester never assumes. It reads the answer back, and an unanswered request
is reported as unanswered.

**The wrong answer this produced first, and the fix for it.** The first version
had one signal doing two jobs. A remount of three volumes took longer than the
fifteen second wait, so the CLI printed "DrivePark did not answer, the veto is
still up" while the app was mid-remount, and the answer landed seconds later
reading 3 of 3 mounted. The stored answer key was the proof:

```
{ mounted = 3; nonce = "1696670A-CAE6-4975-8040-30BC6ABD0FFB"; total = 3; }
```

Being early is not the same as being ignored, and a drive tool that confuses
them tells the user the opposite of the truth. There are two acknowledgements
now. The holder writes an ack the instant it picks the request up, before it
starts work, and the CLI waits five seconds for that. Then it waits up to three
minutes for the result, saying that it is waiting. Past three minutes it refuses
to guess which way it went and sends you to `park status`, which reads the disks
instead of the conversation.

**Verified on the tower, both branches.** With `park now --hold` holding, status
named `park` and its pid, `park release` refused and pointed at the Ctrl-C, and
killing the holder swept the record. With the app holding after a park driven by
its own global shortcut, status named `DrivePark` and its pid, and `park
release` printed the handover and then 3 of 3 mounted, which a fresh read
confirmed.

One rough edge left on purpose. `park now` without `--hold` publishes a holder
record and then exits, so for a moment the store names a pid that is already
gone. The liveness check is what covers it, which is the job it exists for, and
teaching the CLI to predict its own lifetime would buy nothing the check does
not already give.

### Shortcut recorder, watched working, 2026-09-04

Nobody had ever opened this panel. The code shipped, no one saw it run, and that
is the same standing as not built. Driven through the menu with System Events on
the tower:

The menu item opens a panel titled DrivePark Shortcut carrying Save, Use Default
and Cancel, and Save stays disabled until it captures something. Pressing ⌃⌥⌘K
printed ⌃⌥⌘K in the preview and lit Save. Saving stored code 40, modifiers 6400,
display ⌃⌥⌘K, and the app re-registered and reported no conflict.

Then the part that matters, because a stored shortcut isn't a working one. With
all three volumes mounted, the old ⌃⌥⌘P did nothing and status still read 3 of 3
mounted. The newly recorded ⌃⌥⌘K parked all three and left the app holding the
veto. Use Default put ⌃⌥⌘P back and re-registered it.

**One path stays unverified, and this method can't reach it.** The guard that
refuses a combination macOS already owns never fired, because System Events
can't deliver a real system combination to the app. macOS claims it first, which
is precisely the premise the guard rests on. Reaching it needs either a stubbed
SystemShortcuts table or a combination the table lists that Wekesa has switched
off in System Settings. Recorded here rather than counted as passing.

### Disk images get a real switch, 2026-09-04

Last v0.2 parity item. `PARK_INCLUDE_VIRTUAL=1` had been doing this job since
the filesystem tests, and an environment variable is not a setting.

**Dropping `physical` is not how you opt in.** Measured on the tower:
`diskutil list external physical` returns 3 whole disks and `diskutil list
external` returns 22. Only sixteen of the extra nineteen are disk images. The
other three are disk8, disk9 and disk11, the APFS synthesized containers for the
tower itself, which discovery already maps back to their physical stores.
Admitting those as whole disks would count every volume on the tower twice and
offer to eject a container.

So the wide list is a candidate list. Each candidate survives only if diskutil
calls its protocol Disk Image, which costs no extra process launch because the
info call already runs for every disk. An enclosure that won't answer an info query
doesn't get the benefit of the doubt, because an unanswered query isn't evidence
of anything.

`external` itself is never relaxed. It is the one thing keeping the boot disk
out of a tool whose whole job is unmounting volumes, and on this Mac the
internal SSD reports Device Location: Internal.

Off by default. Whether it's safe to unplug the enclosure shouldn't change
because a .dmg happens to be open. `park images [on|off]` in the CLI, a toggle
under Drives in the menu, and `park status` says so in the listing so a volume count is never unexplained. Verified: 3 disks off, 19 on, 3 off again, set from
the menu and read back by the CLI and the reverse, and the env variable still
forces it regardless of the setting.

**SD cards are not covered and were not guessed at.** A card in a USB reader is
already an external physical disk and always worked. A card in a built-in slot
reports Device Location: Internal on some Macs, so covering it means relaxing
the one guard that keeps the boot disk out, filtered on a Secure Digital
protocol string that can't be tested here: this Mac has no built-in reader,
only Apple Fabric internal and USB. Shipping that blind isn't worth it.

### The shortcut conflict guard still cannot be reached, 2026-09-04

Five combinations tried through the recorder panel, and none of them reach the alert:

`⌃←`, `⌃Space` and `⌥⌘D` are consumed by macOS before the app sees them, which
is exactly the premise the guard rests on. `⌘W` closes the panel, and `⌘Q` would
quit, because AppKit handles both as window and application commands before
keyDown reaches the capture view. So the two entries in `alwaysReserved` that
macOS doesn't consume are unreachable through the UI too, by a different
mechanism.

That last one is a small rough edge in its own right: pressing ⌘W in the
recorder closes the panel with no explanation rather than telling you the
combination is spoken for.

I read the overlay parser rather than assuming it, and it's correct: an entry
with enabled false becomes a nil override, and a nil override skips the default
entirely, so a system shortcut you've switched off is correctly freed up.

Reaching the alert needs a stubbed SystemShortcuts table, which means a test
target and moving that file into DriveParkKit. Recorded as open rather than counted as passing.
