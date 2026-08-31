// park — CLI front end over ParkKit. Truth comes from fresh state reads.

import Foundation
import ParkKit

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
        let media = disk.removableMedia ? "removable" : "FIXED (eject cannot detach)"
        print("\(disk.device)  \(disk.mediaName)  \(formatSize(disk.sizeBytes))  \(disk.busProtocol)  media: \(media)")
        for container in disk.containers {
            print("  container \(container.device) (store \(container.physicalStore))")
            for volume in container.volumes {
                total += 1
                if volume.isMounted { mounted += 1 }
                let state = volume.isMounted ? "MOUNTED at \(volume.mountPoint ?? "?")" : "unmounted"
                print("    volume \"\(volume.name)\" (\(volume.device)) — \(state)")
            }
        }
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
    let outcome = engine.park { print($0) }
    for note in outcome.notes { print(note) }
    if outcome.parked {
        print("\nPARKED. All volumes verified unmounted. Safe to power off the enclosure.")
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
    let (mounted, total) = engine.release { print($0) }
    print("\(mounted) of \(total) external volume(s) mounted.")
    if mounted < total { exit(1) }
default:
    print("usage: park [status | now [--hold] | release]")
    exit(64)
}
