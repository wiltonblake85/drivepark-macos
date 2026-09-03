// park — CLI front end over DriveParkKit. Truth comes from fresh state reads.

import Foundation
import DriveParkKit

setvbuf(stdout, nil, _IONBF, 0)

func printStatus() {
    let disks = discoverExternalDisks()
    guard !disks.isEmpty else {
        print("No external physical disks found.")
        return
    }
    var mounted = 0
    var total = 0
    print("PARK STATUS — \(disks.count) external disk(s)")
    if !Preferences.appLooksAlive { print(appLivenessLine()) }
    print("")
    for disk in disks {
        if disk.infoAnswered {
            let media = disk.removableMedia ? "removable" : "FIXED (eject cannot detach)"
            print("\(disk.device)  \(disk.mediaName)  \(formatSize(disk.sizeBytes))  \(disk.busProtocol)  media: \(media)")
        } else {
            print("\(disk.device)  NOT ANSWERING (diskutil info timed out; volumes below come from diskutil list)")
        }
        for container in disk.containers {
            print("  container \(container.device) (store \(container.physicalStore))")
            for volume in container.volumes {
                total += 1
                if volume.isMounted { mounted += 1 }
                let state = volume.isMounted ? "MOUNTED at \(volume.mountPoint ?? "?")" : "unmounted"
                let tag = Preferences.isIgnored(volume.uuid) ? "  [IGNORED, DrivePark leaves this alone]" : ""
                print("    volume \"\(volume.name)\" (\(volume.device)) — \(state)\(tag)")
            }
        }
        for volume in disk.directVolumes {
            total += 1
            if volume.isMounted { mounted += 1 }
            let state = volume.isMounted ? "MOUNTED at \(volume.mountPoint ?? "?")" : "unmounted"
            let tag = Preferences.isIgnored(volume.uuid) ? "  [IGNORED, DrivePark leaves this alone]" : ""
            print("    volume \"\(volume.name)\" (\(volume.device), non-APFS) — \(state)\(tag)")
        }
        print("")
    }

    if DiskutilTimeout.occurred {
        print("WARNING: \(DiskutilTimeout.total) diskutil call(s) timed out.")
        print("The enclosure is not answering detail queries. Volume state below")
        print("is still accurate; disk details are not. Power-cycling the")
        print("enclosure is usually what clears this.")
        print("")
    }

    if total == 0 {
        print("Overall: no volumes discovered.")
    } else if mounted == 0 {
        print("Overall: all \(total) volume(s) unmounted. Safe to power off the enclosure.")
    } else {
        print("Overall: \(mounted) of \(total) volume(s) still mounted. NOT safe to power off.")
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
    return "DrivePark app: NOT RUNNING. Last check-in \(howLong). "
        + "Auto-park triggers and the global shortcut are all dead until it starts."
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first ?? "status" {
case "status":
    printStatus()
case "now":
    let engine = Engine()
    var onlyDisks: Set<String>? = nil
    if let flagIndex = arguments.firstIndex(of: "--only") {
        let valueIndex = arguments.index(after: flagIndex)
        if arguments.indices.contains(valueIndex) { onlyDisks = [arguments[valueIndex]] }
    }
    let force = arguments.contains("--force")
    if force {
        print("FORCE: open files will be torn down and unwritten data in them is lost.")
        print("No retries, no waiting for the blocker to finish.\n")
    }
    let outcome = engine.park(onlyDisks: onlyDisks, force: force) { print($0) }
    for note in outcome.notes { print(note) }
    for result in outcome.results {
        let verdict = result.success ? "unmounted" : "FAILED"
        print(String(format: "  %@: %@ in %.2fs, %d attempt(s)",
                     result.volume.displayName, verdict, result.duration, result.attempts))
    }
    if outcome.didWork { print("Timing: " + outcome.timing.summary) }
    if outcome.parked && !outcome.didWork {
        // Everything was ignored or already unmounted. This run verified
        // nothing, so it claims nothing.
        print("\nNo action taken. Nothing this run manages was mounted.")
        exit(0)
    }
    if outcome.parked {
        if onlyDisks == nil {
            print("\nPARKED. All volumes verified unmounted. Safe to power off the enclosure.")
        } else {
            print("\nPARKED. Selected drive verified unmounted. Other drives in the enclosure may still be mounted.")
        }
        if arguments.contains("--hold") {
            print("Holding park: remount attempts will be refused. Ctrl-C to stop holding.")
            signal(SIGINT, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigint.setEventHandler {
                print("\nVeto released. Volumes remain unmounted; run `park release` to remount.")
                exit(0)
            }
            sigint.resume()
            dispatchMain()
        }

    } else {
        let names = outcome.stillMounted.map { "\"\($0.name)\"" }.joined(separator: ", ")
        print("\nNOT PARKED. Still mounted: \(names)")
        if let blockers = outcome.blockerSummary { print("Blockers: \(blockers)") }
        exit(1)
    }
case "release":
    let engine = Engine()
    var releaseOnly: Set<String>? = nil
    if let flagIndex = arguments.firstIndex(of: "--only") {
        let valueIndex = arguments.index(after: flagIndex)
        if arguments.indices.contains(valueIndex) { releaseOnly = [arguments[valueIndex]] }
    }
    let (mounted, total) = engine.release(onlyDisks: releaseOnly) { print($0) }
    print("\(mounted) of \(total) external volume(s) mounted.")
    if mounted < total { exit(1) }
case "ignore", "manage":
    // park ignore "Plex"   -> never touch it
    // park manage "Plex"   -> touch it again
    let wantIgnored = (arguments.first == "ignore")
    let target = arguments.dropFirst().first
    guard let target else {
        print("usage: park \(wantIgnored ? "ignore" : "manage") <volume name or UUID>")
        exit(64)
    }
    let volumes = discoverExternalDisks().flatMap { $0.allVolumes }
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
case "ignored":
    let volumes = discoverExternalDisks().flatMap { $0.allVolumes }
    let ignored = volumes.filter { Preferences.isIgnored($0.uuid) }
    if ignored.isEmpty {
        print("Nothing is ignored. DrivePark manages every external volume.")
    } else {
        print("Ignored, never touched by DrivePark:")
        for volume in ignored { print("  \(volume.displayName)  (\(volume.uuid ?? "?"))") }
    }
default:
    print("usage: park [status | now [--hold] [--force] [--only diskN] | release [--only diskN]")
    print("            | ignore <volume> | manage <volume> | ignored | triggers]")
    exit(64)
}
