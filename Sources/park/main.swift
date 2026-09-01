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
    print("PARK STATUS — \(disks.count) external disk(s)\n")
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
    let outcome = engine.park(onlyDisks: onlyDisks) { print($0) }
    for note in outcome.notes { print(note) }
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
    print("usage: park [status | now [--hold] [--only diskN] | release [--only diskN]")
    print("            | ignore <volume> | manage <volume> | ignored]")
    exit(64)
}
