// park — CLI front end over DriveParkKit. Truth comes from fresh state reads.

import Foundation
import DriveParkKit

setvbuf(stdout, nil, _IONBF, 0)

/// Every line this tool prints passes through here.
///
/// Outside text is escaped where it is built (see printable), so a newline in
/// a volume name cannot forge a line of its own. This is the second net, for
/// a terminal escape sequence from anywhere that was missed: only the line
/// breaks this file wrote itself survive.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let text = items.map { "\($0)" }.joined(separator: separator)
    let safe = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { printable(String($0)) }
        .joined(separator: "\n")
    Swift.print(safe, terminator: terminator)
}

/// The disks, for commands that only need names and UUIDs. A read that did
/// not finish still knows what diskutil listed, and that is enough to find a
/// volume by name; it is never enough to say anything is safe.
func disksForLookup() -> [PhysicalDisk] {
    do { return try discoverExternalDisks().disks } catch let failure as DiscoveryFailure {
        print("Note: the disk read did not finish (\(failure.reason)). Using what it did list.")
        return failure.partial
    } catch {
        print("Note: the disk read failed (\(error)).")
        return []
    }
}

func printStatus() {
    var snapshot: DiskSnapshot?
    var failure: DiscoveryFailure?
    do { snapshot = try discoverExternalDisks() } catch let thrown as DiscoveryFailure {
        failure = thrown
    } catch {
        failure = DiscoveryFailure(reason: "\(error)")
    }
    let disks = snapshot?.disks ?? failure?.partial ?? []
    let unaccounted = snapshot?.unaccountedMounts ?? []
    guard !disks.isEmpty || !unaccounted.isEmpty || failure != nil else {
        print("No external physical disks found.")
        return
    }
    var mounted = 0
    var total = 0
    print("PARK STATUS — \(disks.count) external disk(s)")
    if !Preferences.appLooksAlive { print(appLivenessLine()) }
    for holder in VetoBroker.holders {
        print("Remount veto held by \(printable(holder.name)) (pid \(holder.pid)), \(holder.uuids.count) volume(s).")
        print(holder.canAnswer
              ? "`park mount` will ask it to let go."
              : "Press Ctrl-C in that process to drop it.")
    }
    print("")
    for disk in disks {
        if disk.infoAnswered {
            let media = disk.removableMedia ? "removable" : "FIXED (eject cannot detach)"
            print("\(disk.device)  \(printable(disk.mediaName))  \(formatSize(disk.sizeBytes))  \(printable(disk.busProtocol))  media: \(media)")
        } else {
            print("\(disk.device)  NOT ANSWERING (diskutil info timed out; volumes below come from diskutil list)")
        }
        for container in disk.containers {
            print("  container \(container.device) (store \(container.physicalStore))")
            for volume in container.volumes {
                total += 1
                if volume.isMounted { mounted += 1 }
                let state = volume.isMounted ? "MOUNTED at \(volume.displayMountPoint ?? "?")" : "unmounted"
                let tag = Preferences.isIgnored(volume.uuid) ? "  [IGNORED, DrivePark leaves this alone]"
                    : volume.uuid == nil ? "  [no volume UUID: a park unmounts it but cannot keep it unmounted]" : ""
                print("    volume \"\(printable(volume.name))\" (\(volume.device)) — \(state)\(tag)")
            }
        }
        for volume in disk.directVolumes {
            total += 1
            if volume.isMounted { mounted += 1 }
            let state = volume.isMounted ? "MOUNTED at \(volume.displayMountPoint ?? "?")" : "unmounted"
            let tag = Preferences.isIgnored(volume.uuid) ? "  [IGNORED, DrivePark leaves this alone]"
                : volume.uuid == nil ? "  [no volume UUID: a park unmounts it but cannot keep it unmounted]" : ""
            print("    volume \"\(printable(volume.name))\" (\(volume.device), non-APFS) — \(state)\(tag)")
        }
        print("")
    }

    if !unaccounted.isEmpty {
        print("Mounted, and not in the listing above:")
        for mount in unaccounted { print("  \(mount.sentence)") }
        print("")
    }

    if let failure {
        print("WARNING: the disk read did not finish: \(failure.reason).")
        if failure.timedOut {
            print("The enclosure is not answering. The listing above is what")
            print("diskutil managed to say, and it cannot be verified. Power-cycling")
            print("the enclosure is usually what clears this.")
        }
        print("")
    }

    if Preferences.includeDiskImages {
        print("Disk images are included in this listing (park images off to exclude).")
        print("")
    }

    // An image backed by a file on one of these volumes will dissent its
    // unmount. Saying so here means a park failure is predicted instead of
    // discovered. Park detaches these itself; status only reports.
    if let images = readAttachedImages(), !images.isEmpty {
        var inTheWay: [(String, String)] = []
        for disk in disks {
            for volume in disk.allVolumes where volume.isMounted {
                guard let mountPoint = volume.mountPoint else { continue }
                if Preferences.isIgnored(volume.uuid) { continue }
                for image in imagesBacked(byVolumeAt: resolvedPath(mountPoint), in: images) {
                    inTheWay.append((image.displayPath, volume.displayName))
                }
            }
        }
        if !inTheWay.isEmpty {
            print("Disk image(s) in the way:")
            for (path, volume) in inTheWay {
                print("  \(path)")
                print("    backed by a file on \"\(volume)\". A park will detach it first.")
            }
            print("")
        }
    }
    guard let snapshot else {
        print("Overall: COULD NOT VERIFY. Do not power off the enclosure on this reading.")
        exit(2)
    }
    let verdict = snapshot.verdict
    if verdict.safeToPowerOff {
        print(total == 0
              ? "Overall: no volumes discovered, and nothing on an external disk is mounted."
              : "Overall: all \(total) volume(s) unmounted. Safe to power off the enclosure.")
    } else {
        print("Overall: \(mounted) of \(total) volume(s) still mounted. NOT safe to power off.")
        if let reason = verdict.reason(isIgnored: Preferences.isIgnored) { print("  \(reason).") }
    }
}


/// The app being alive is a precondition for every automatic park, so the CLI
/// says so plainly rather than leaving it to be noticed.
func appLivenessLine() -> String {
    guard let age = Preferences.heartbeatAge else {
        return "DrivePark app: has never run on this Mac. No automatic parking."
    }
    if Preferences.appLooksAlive {
        return "DrivePark app: running."
    }
    let minutes = Int(age / 60)
    let howLong: String
    switch minutes {
    case ..<60:      howLong = "\(minutes) minute(s) ago"
    case ..<(60*48): howLong = "\(minutes / 60) hour(s) ago"
    default:         howLong = "\(minutes / 1440) day(s) ago"
    }
    var line = "DrivePark app: NOT RUNNING. Last check-in \(howLong). "
        + "Auto-park triggers and the global shortcut are all dead until it starts."
    if Preferences.watchdogGaveUpAt != nil {
        line += " It crashed \(RelaunchBudget.limit) times in \(Int(RelaunchBudget.window / 60)) minutes, "
            + "so the watchdog stopped restarting it."
    }
    return line
}


/// A card in the notch, for the runs nobody is watching.
///
/// When stdout is a terminal the person is already reading the result, and a
/// second copy in the notch is noise. When it is a pipe, a log, a cron job or
/// a launchd plist, the terminal output goes nowhere anyone will see, and the
/// card is the only report that reaches a human. Silent when Transom is not
/// installed or the token is missing; a card must never change what a park
/// does or what it exits with.
func postCardIfUnattended(_ outcome: ParkOutcome, scoped: Bool) {
    guard isatty(STDOUT_FILENO) == 0 else { return }
    if outcome.parked && outcome.safeToPowerOff {
        Transom.postAndWait(
            title: "Safe to undock",
            message: "Nothing on any external disk is mounted, verified on a fresh read. Pull the cable.",
            symbol: "externaldrive.badge.checkmark",
            duration: 10)
        return
    }
    if outcome.parked {
        if scoped {
            Transom.postAndWait(
                title: "Selected drive parked",
                message: "Not safe to undock: \(outcome.cardSafetyReason).",
                symbol: "externaldrive",
                duration: 10)
        } else {
            // Persistent: this one looks like success and is not.
            Transom.postAndWait(
                title: "Parked, but do NOT undock",
                message: "\(outcome.cardSafetyReason).",
                symbol: "exclamationmark.triangle.fill",
                persistent: true,
                urgent: true)
        }
        return
    }
    Transom.postAndWait(title: "Park failed, do not undock",
                        message: outcome.cardProblem,
                        symbol: "externaldrive.trianglebadge.exclamationmark",
                        persistent: true,
                        urgent: true)
}

/// The value after `--only`. A bare `--only` used to fall through to "every
/// disk", which with `--force` meant force-unmounting the whole tower.
func onlyDisksArgument() -> Set<String>? {
    guard let flagIndex = arguments.firstIndex(of: "--only") else { return nil }
    let valueIndex = arguments.index(after: flagIndex)
    guard arguments.indices.contains(valueIndex), !arguments[valueIndex].hasPrefix("-") else {
        print("usage: --only needs a disk, e.g. --only disk4 (see `park status`)")
        exit(64)
    }
    return [arguments[valueIndex]]
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first ?? "status" {
case "status":
    printStatus()
case "now":
    let onlyDisks = onlyDisksArgument()
    let engine = Engine()
    let force = arguments.contains("--force")
    if force {
        print("FORCE: open files will be torn down and unwritten data in them is lost.")
        print("No retries, no waiting for the blocker to finish.\n")
    }
    var outcome = engine.park(onlyDisks: onlyDisks, force: force,
                              backup: arguments.contains("--stop-backup")
                                  ? .stopBackupIfRunning : .refuseWhileBackingUp) { print($0) }
    // Time Machine is writing to a drive this park would unmount, and nothing
    // has been touched. Ask at a terminal; anywhere else, nobody can answer,
    // so the backup wins.
    if !outcome.backupInProgress.isEmpty {
        let names = outcome.backupInProgress.map(\.displayName).joined(separator: ", ")
        print("Time Machine is backing up to \(names). Parking stops that backup.")
        guard isatty(STDIN_FILENO) != 0 else {
            print("NOT PARKED. Run again when the backup finishes, or add --stop-backup.")
            exit(1)
        }
        Swift.print("Stop the backup and park? [y/N] ", terminator: "")
        guard (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y") else {
            print("NOT PARKED. Left mounted while Time Machine finishes.")
            exit(1)
        }
        outcome = engine.park(onlyDisks: onlyDisks, force: force,
                              backup: .stopBackupIfRunning) { print($0) }
    }
    for note in outcome.notes { print(note) }
    for result in outcome.results {
        let verdict = result.success ? "unmounted" : "FAILED"
        print(String(format: "  %@: %@ in %.2fs, %d attempt(s)",
                     result.volume.displayName, verdict, result.duration, result.attempts))
    }
    if outcome.didWork { print("Timing: " + outcome.timing.summary) }
    // Exit codes. 0: what was asked is verified, and for a tower park that
    // means safe to power off. 1: partial, including a tower park that left
    // an ignored volume mounted, because `park now && unplug` must not
    // unplug that. 2: nothing could be verified.
    if let failure = outcome.failure {
        print("\nNOT PARKED. \(failure)")
        if outcome.didWork { postCardIfUnattended(outcome, scoped: onlyDisks != nil) }
        exit(2)
    }
    if outcome.parked && !outcome.didWork {
        // Everything was ignored or already unmounted. This run unmounted
        // nothing, so it claims nothing beyond what the fresh read says.
        print("\nNo action taken. Nothing this run manages was mounted.")
        if outcome.safeToPowerOff {
            print("Nothing on any external disk is mounted. Safe to power off the enclosure.")
            exit(0)
        }
        print("NOT safe to power off: \(outcome.safetyReason ?? "something is still mounted").")
        exit(onlyDisks == nil ? 1 : 0)
    }
    postCardIfUnattended(outcome, scoped: onlyDisks != nil)
    if outcome.parked {
        if outcome.safeToPowerOff {
            print(onlyDisks == nil
                  ? "\nPARKED. Every volume on every external disk verified unmounted. Safe to power off the enclosure."
                  : "\nPARKED. Selected drive verified unmounted, and nothing else is mounted. Safe to power off the enclosure.")
        } else if onlyDisks == nil {
            print("\nPARKED everything DrivePark manages, but NOT safe to power off: \(outcome.safetyReason ?? "something is still mounted").")
        } else {
            print("\nPARKED. Selected drive verified unmounted. NOT safe to power off: \(outcome.safetyReason ?? "something is still mounted").")
        }
        let exitCode: Int32 = (onlyDisks == nil && !outcome.safeToPowerOff) ? 1 : 0
        if arguments.contains("--hold") {
            print("Holding park: remount attempts will be refused. Ctrl-C to stop holding.")
            signal(SIGINT, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigint.setEventHandler {
                // The liveness check in VetoBroker.holder would clear this
                // record on the next read anyway, since the veto dies with
                // this process. Clearing it here means `park status` in
                // another terminal is right immediately rather than right on
                // the next sweep.
                VetoBroker.clearHold()
                print("\nVeto dropped. Volumes remain unmounted; run `park mount` to mount them.")
                exit(0)
            }
            sigint.resume()
            dispatchMain()
        }
        exit(exitCode)
    } else {
        print("\nNOT PARKED. \(outcome.problem ?? "The park did not verify.")")
        exit(1)
    }
case "mount":
    let mountOnly = onlyDisksArgument()

    // A veto belongs to the process that registered the Disk Arbitration
    // callback, and no other process can lift it. Mounting locally while the
    // app holds one produces the app's own dissent string and no remount,
    // which is what this command used to do (SPEC section 10, 2026-09-03,
    // when it was still named `park release`).
    let holders = VetoBroker.holders
    // A `park now --hold` in another terminal holds a real veto and listens
    // for nothing, so asking the app to let go would leave that one standing.
    // With a record per holder, both can be seen at once.
    if let terminal = holders.first(where: { !$0.canAnswer }) {
        print("\(printable(terminal.name)) (pid \(terminal.pid)) is holding a remount veto and cannot be asked.")
        print("Press Ctrl-C in that terminal, then run `park mount` again.")
        exit(1)
    }
    if let holder = holders.first {
        if holder.canAnswer {
            print("DrivePark (pid \(holder.pid)) is holding the remount veto. Asking it to mount.")
            let nonce = VetoBroker.requestMount(disks: mountOnly)

            // Two waits, because there are two different questions. The first
            // asks whether anyone is listening, and five seconds is generous
            // for picking up a notification. The second waits for real work: a
            // mount is bimodal at roughly half a second or eleven per volume,
            // and a fresh diskutil read follows it, so a whole tower can take
            // well past a minute on a slow enclosure.
            guard VetoBroker.awaitAck(nonce: nonce, timeout: 5) else {
                // Not heard is not mounted. Say so, and say what to do
                // instead, rather than falling through to a local remount the
                // veto will refuse and calling the refusal a result.
                print("DrivePark did not pick up the request. The veto is still up.")
                print("Use Mount Tower in the DrivePark menu, or quit DrivePark and run this again.")
                exit(1)
            }
            print("DrivePark has it. Waiting for the remount to finish and verify.")
            switch VetoBroker.awaitAnswer(nonce: nonce, timeout: 180) {
            case .mounted(let mounted, let total):
                print("\(mounted) of \(total) external volume(s) mounted.")
                exit(mounted < total ? 1 : 0)
            case .busy:
                print("DrivePark is in the middle of a park or a mount and did nothing.")
                print("Run this again when it finishes. The veto is still up.")
                exit(1)
            case .failed(let reason):
                print("DrivePark could not finish: \(reason)")
                exit(2)
            case nil:
                break
            }
            // It picked the request up and never finished. Do not guess which
            // way that went: `park status` reads the disks rather than this
            // conversation.
            print("DrivePark took the request but has not finished after 3 minutes.")
            print("Run `park status` to see where the volumes actually stand.")
            exit(1)
        }
        // A `park now --hold` in another terminal holds a real veto and
        // listens for nothing. Point at it by name.
        print("\(holder.name) (pid \(holder.pid)) is holding the remount veto and cannot be asked.")
        print("Press Ctrl-C in that terminal, then run `park mount` again.")
        exit(1)
    }

    let engine = Engine()
    let outcome = engine.mount(onlyDisks: mountOnly) { print($0) }
    for result in outcome.results {
        print(String(format: "  %@: %@ in %.2fs", result.volume.displayName,
                     result.success ? "mounted" : "FAILED", result.duration))
    }
    if !outcome.results.isEmpty { print("Timing: " + outcome.summary) }
    if let failure = outcome.failure {
        print(failure)
        exit(2)
    }
    print("\(outcome.mountedCount) of \(outcome.total) external volume(s) mounted.")
    if outcome.mountedCount < outcome.total { exit(1) }
case "ignore", "manage":
    // park ignore "Plex"   -> never touch it
    // park manage "Plex"   -> touch it again
    let wantIgnored = (arguments.first == "ignore")
    let target = arguments.dropFirst().first
    guard let target else {
        print("usage: park \(wantIgnored ? "ignore" : "manage") <volume name or UUID>")
        exit(64)
    }
    let volumes = disksForLookup().flatMap { $0.allVolumes }
    let match = volumes.first {
        $0.displayName.caseInsensitiveCompare(target) == .orderedSame
            || $0.uuid?.caseInsensitiveCompare(target) == .orderedSame
    }
    guard let match, let uuid = match.uuid else {
        print("No external volume matched \"\(target)\".")
        print("Known: " + volumes.map { $0.displayName }.joined(separator: ", "))
        exit(1)
    }
    Preferences.setIgnored(uuid, wantIgnored)
    // Verify against a fresh read of the stored set, not the call.
    let nowIgnored = Preferences.isIgnored(uuid)
    guard nowIgnored == wantIgnored else {
        print("Failed to update the ignore list for \"\(match.displayName)\".")
        exit(2)
    }
    print(wantIgnored
        ? "\"\(match.displayName)\" is now IGNORED. DrivePark will not unmount it, including on Park Tower."
        : "\"\(match.displayName)\" is managed again.")
case "images":
    // park images            -> show
    // park images on | s.f   -> set
    let want = arguments.dropFirst().first?.lowercased()
    if let want {
        guard want == "on" || want == "off" else {
            print("usage: park images [on|off]")
            exit(64)
        }
        Preferences.includeDiskImages = (want == "on")
    }
    if Preferences.includeDiskImages {
        print("Disk images: INCLUDED. A mounted .dmg counts as a parkable drive,")
        print("so Park Tower unmounts it and the safe-to-unplug answer waits for it.")
    } else {
        print("Disk images: excluded. A mounted .dmg is left alone and does not")
        print("change the safe-to-unplug answer. This is the default.")
    }
    if ProcessInfo.processInfo.environment["PARK_INCLUDE_VIRTUAL"] == "1" {
        print("")
        print("NOTE: PARK_INCLUDE_VIRTUAL=1 is set in this environment and forces")
        print("them in regardless of the setting above.")
    }

case "triggers":
    print("AUTOMATIC PARKING\n")
    print(appLivenessLine())
    print("")
    for status in TriggerHealth.allStatuses() {
        let armed = Preferences.isEnabled(status.trigger) ? "ARMED " : "off   "
        let health = status.canFire ? "" : "  <- CANNOT FIRE"
        print("\(armed) \(status.trigger.label)\(health)")
        if let reason = status.reason { print("        \(reason)") }
    }
    // The undo side of the triggers above. Shown here because it is the one
    // wake-related setting with no other read-out outside the menu.
    let wake = Preferences.autoMountOnWake ? "ARMED " : "off   "
    print("\(wake) Mount automatically on wake (\(Int(Preferences.wakeMountDelay))s after wake)")
    let dead = TriggerHealth.armedButDead()
    print("")
    if !Preferences.appLooksAlive && !Preferences.enabledTriggers.isEmpty {
        print("WARNING: triggers are armed but the app is not running, so none")
        print("of them can fire. Start DrivePark.")
        exit(1)
    }
    if dead.isEmpty {
        print("Every armed trigger can fire.")
    } else {
        print("WARNING: \(dead.count) armed trigger(s) cannot fire on this Mac right now.")
        print("They are switched on and they will never run. That is not a")
        print("setting problem, it is the machine's current power state.")
        exit(1)
    }
case "transom" where arguments.dropFirst().first == "token":
    // Read rather than taken as an argument, so the token never lands in
    // shell history or in the process list.
    print("Transom → Preferences → Advanced → Local API. Paste the token, then Return.")
    print("Empty line clears the stored token.")
    let typed = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard Preferences.saveTransomToken(typed) else {
        print("The Keychain would not store the token. Nothing was saved.")
        exit(2)
    }
    Transom.forgetCachedToken()
    if typed.isEmpty {
        print("Cleared from the Keychain.")
        exit(0)
    }
    if !Preferences.transomEnabled {
        // Saving a token is asking for cards, and they are off by default.
        Preferences.transomEnabled = true
        print("Notch cards switched on.")
    }
    if Transom.postAndWait(title: "DrivePark token saved",
                           message: "Park results will land here.",
                           symbol: "externaldrive.badge.checkmark",
                           duration: 6) {
        print("Saved, and a card was delivered. Look at the notch.")
    } else {
        print("Saved, but the card was refused: \(Transom.lastFailure ?? "unknown")")
        exit(1)
    }
case "transom":
    // Proves the channel by using it. Anything less reports on configuration
    // rather than on whether a card actually arrives.
    print("Endpoint: \(Transom.endpoint.absoluteString)")
    print("Enabled:  \(Preferences.transomEnabled ? "yes" : "no (park transom on)")")
    if arguments.dropFirst().first == "on" {
        Preferences.transomEnabled = true
        print("Notch cards switched on.")
    } else if arguments.dropFirst().first == "off" {
        Preferences.transomEnabled = false
        print("Notch cards switched off. Nothing else changes.")
        exit(0)
    }
    let hasToken = Transom.resolveToken() != nil
    print("Token:    \(hasToken ? "found, posting to the local API" : "none, posting by transom:// link")")
    let delivered = Transom.postAndWait(
        title: "DrivePark test card",
        message: "Posted by `park transom`.",
        symbol: "externaldrive.badge.checkmark",
        duration: 6)
    if delivered {
        print(hasToken
            ? "Card delivered, Transom answered 200. Look at the notch."
            : "Link handed to Transom. Look at the notch; without a token there is no receipt.")
    } else {
        print("NOT DELIVERED: \(Transom.lastFailure ?? "unknown")")
        exit(1)
    }
case "ignored":
    let volumes = disksForLookup().flatMap { $0.allVolumes }
    let ignored = volumes.filter { Preferences.isIgnored($0.uuid) }
    if ignored.isEmpty {
        print("Nothing is ignored. DrivePark manages every external volume.")
    } else {
        print("Ignored, never touched by DrivePark:")
        for volume in ignored { print("  \(volume.displayName)  (\(volume.uuid ?? "?"))") }
    }
default:
    print("usage: park [status | now [--hold] [--force] [--stop-backup] [--only diskN]")
    print("            | mount [--only diskN]")
    print("            | ignore <volume> | manage <volume> | ignored | triggers")
    print("            | transom [on|off|token]]")
    exit(64)
}
