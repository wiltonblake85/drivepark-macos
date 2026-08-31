// Discovery.swift — read-only discovery of external disks via diskutil plists.

import Foundation

func runDiskutil(_ args: [String]) -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let plist = try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil) else { return nil }
    return plist as? [String: Any]
}

func volumeUUID(of device: String) -> String? {
    runDiskutil(["info", "-plist", device])?["VolumeUUID"] as? String
}

func wholeDiskName(of device: String) -> String {
    guard let match = device.range(of: "^disk[0-9]+", options: .regularExpression)
    else { return device }
    return String(device[match])
}

public struct Volume {
    public let device: String
    public let name: String
    public let mountPoint: String?
    public var isMounted: Bool { mountPoint != nil }
    public var displayName: String { name.trimmingCharacters(in: .whitespaces) }
}

public struct Container {
    public let device: String
    public let physicalStore: String
    public var volumes: [Volume]
}

public struct PhysicalDisk {
    public let device: String
    public var mediaName = "?"
    public var busProtocol = "?"
    public var sizeBytes: Int64 = 0
    public var removableMedia = false
    public var ejectable = false
    public var containers: [Container] = []
}

public func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    return formatter.string(fromByteCount: bytes)
}

public func discoverExternalDisks() -> [PhysicalDisk] {
    guard let externalList = runDiskutil(["list", "-plist", "external", "physical"]),
          let externalWhole = externalList["WholeDisks"] as? [String] else {
        return []
    }
    let externalSet = Set(externalWhole)

    guard let fullList = runDiskutil(["list", "-plist"]),
          let allEntries = fullList["AllDisksAndPartitions"] as? [[String: Any]]
    else { return [] }

    var disks: [String: PhysicalDisk] = [:]
    for device in externalSet.sorted() {
        var disk = PhysicalDisk(device: device)
        if let info = runDiskutil(["info", "-plist", device]) {
            disk.mediaName = info["MediaName"] as? String ?? "?"
            disk.busProtocol = info["BusProtocol"] as? String ?? "?"
            if let size = info["TotalSize"] as? Int64 { disk.sizeBytes = size }
            else if let size = info["TotalSize"] as? Int { disk.sizeBytes = Int64(size) }
            disk.removableMedia = info["RemovableMedia"] as? Bool
                ?? info["Removable"] as? Bool ?? false
            disk.ejectable = info["Ejectable"] as? Bool ?? false
        }
        disks[device] = disk
    }

    for entry in allEntries {
        guard let containerDevice = entry["DeviceIdentifier"] as? String,
              let stores = entry["APFSPhysicalStores"] as? [[String: Any]],
              let firstStore = stores.first?["DeviceIdentifier"] as? String
        else { continue }
        let physicalDisk = wholeDiskName(of: firstStore)
        guard disks[physicalDisk] != nil else { continue }

        var volumes: [Volume] = []
        if let apfsVolumes = entry["APFSVolumes"] as? [[String: Any]] {
            for volumeEntry in apfsVolumes {
                guard let volumeDevice = volumeEntry["DeviceIdentifier"] as? String
                else { continue }
                volumes.append(Volume(
                    device: volumeDevice,
                    name: volumeEntry["VolumeName"] as? String ?? "(unnamed)",
                    mountPoint: volumeEntry["MountPoint"] as? String))
            }
        }
        disks[physicalDisk]?.containers.append(Container(
            device: containerDevice,
            physicalStore: firstStore,
            volumes: volumes))
    }
    return disks.keys.sorted().compactMap { disks[$0] }
}
