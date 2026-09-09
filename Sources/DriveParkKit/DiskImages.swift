// DiskImages.swift — attached disk images, and which of them pin a managed volume.
//
// A .dmg attached from a file that lives on a managed volume holds that volume
// open. Measured on the tower 2026-09-09 with a scratch image on /Volumes/Backup:
//
//   diskutil unmount /Volumes/Backup
//   -> failed to unmount: dissented by PID 29138 (diskimages-helper)
//
// The dissent arrives in 0.28s, so nothing hangs, but no amount of waiting
// clears it either. The retry ladder would spend its full 17s learning that,
// and `lsof -Fpc`, which is all Blockers.swift asks for, can only answer
// "diskimages-helper (pid 29138)". Nobody can act on that sentence. The
// actionable fact is the backing path, and it is one hdiutil call away.
//
// This is deliberately NOT gated on Preferences.includeDiskImages. That
// setting decides whether a mounted .dmg counts as a parkable drive, and the
// answer is still no by default. This decides whether an image stands between
// a managed drive and being safe to unplug, which is a different question.
// Gating the two together would turn an off-by-default setting into a way to
// make parks fail.

import Foundation

/// One image attached through DiskImages.framework, as `hdiutil info -plist`
/// reports it.
public struct AttachedImage: Equatable {
    /// The backing file as hdiutil reports it. This is what gets printed,
    /// because it is the sentence a human can act on.
    public let imagePath: String
    /// The same path with symlinks resolved. Matching happens on this: a
    /// backing file reached through a link still pins the volume it actually
    /// lives on.
    public let resolvedImagePath: String
    /// BSD name of the outermost whole disk, e.g. "disk12". Ejecting this
    /// detaches the image. Verified 2026-09-09: `diskutil eject /dev/disk12`
    /// returned "Disk /dev/disk12 ejected" in 0.49s and the image left
    /// `hdiutil info`.
    public let wholeDisk: String
    /// BSD names of this image's own mounted volumes, e.g. ["disk13s1"].
    /// These are unmounted before the eject: measured 2026-09-09, DADiskEject
    /// on the whole disk with the image's volume still mounted comes back
    /// busy (DA status 0xc010). `diskutil eject` looks like it detaches in one
    /// step only because it unmounts the volumes first, and so must this.
    public let mountedVolumes: [String]
    /// Where those volumes are mounted, so a refusal can name what is open
    /// inside the image instead of reporting a status code.
    public let mountPoints: [String]

    public init(imagePath: String, resolvedImagePath: String,
                wholeDisk: String, mountedVolumes: [String],
                mountPoints: [String] = []) {
        self.imagePath = imagePath
        self.resolvedImagePath = resolvedImagePath
        self.wholeDisk = wholeDisk
        self.mountedVolumes = mountedVolumes
        self.mountPoints = mountPoints
    }
}

/// Parses `hdiutil info -plist`. Pure function of the plist, so it is tested
/// against a captured fixture rather than against whatever happens to be
/// attached to this Mac.
///
/// Shape captured on the tower 2026-09-09: `images` is an array, each entry
/// carrying `image-path` and a `system-entities` array whose members have a
/// `dev-entry` and, for the mounted one, a `mount-point`. A single image
/// reported four entities: /dev/disk12, /dev/disk12s1, /dev/disk13 and
/// /dev/disk13s1 at /Volumes/ParkScratch.
public func parseAttachedImages(_ plist: [String: Any],
                                resolve: (String) -> String = { $0 }) -> [AttachedImage] {
    guard let images = plist["images"] as? [[String: Any]] else { return [] }
    var parsed: [AttachedImage] = []
    for image in images {
        guard let path = image["image-path"] as? String,
              let entities = image["system-entities"] as? [[String: Any]] else { continue }
        var wholeDisks: [String] = []
        var mounted: [String] = []
        var mountPoints: [String] = []
        for entity in entities {
            guard let entry = entity["dev-entry"] as? String else { continue }
            let bsd = entry.hasPrefix("/dev/") ? String(entry.dropFirst(5)) : entry
            if bsd.range(of: "^disk[0-9]+$", options: .regularExpression) != nil {
                wholeDisks.append(bsd)
            }
            if let point = entity["mount-point"] as? String {
                mounted.append(bsd)
                mountPoints.append(point)
            }
        }
        // Two entries match ^disk[0-9]+$ for an APFS image: the outer disk and
        // the synthesized container inside it. Eject the outer one. hdiutil
        // lists entities outermost first and the container always gets a
        // higher number, so lowest index is the outer disk either way.
        guard let outer = wholeDisks.min(by: { diskIndex($0) < diskIndex($1) }) else { continue }
        parsed.append(AttachedImage(imagePath: path,
                                    resolvedImagePath: resolve(path),
                                    wholeDisk: outer,
                                    mountedVolumes: mounted,
                                    mountPoints: mountPoints))
    }
    return parsed
}

private func diskIndex(_ bsd: String) -> Int {
    Int(bsd.dropFirst(4)) ?? Int.max
}

/// The images whose backing file lives on the volume mounted at
/// `resolvedMountPoint`.
///
/// Prefix plus a separator, so /Volumes/Backup does not swallow
/// /Volumes/Backup2. Both sides are expected already resolved; keeping the
/// resolution outside makes this testable without a filesystem.
public func imagesBacked(byVolumeAt resolvedMountPoint: String,
                         in images: [AttachedImage]) -> [AttachedImage] {
    guard !resolvedMountPoint.isEmpty else { return [] }
    let prefix = resolvedMountPoint.hasSuffix("/") ? resolvedMountPoint : resolvedMountPoint + "/"
    return images.filter { $0.resolvedImagePath.hasPrefix(prefix) }
}

/// Reads the attached images from hdiutil.
///
/// Returns nil when hdiutil did not answer, which is not the same as "no
/// images attached" and must not be reported as if it were. A park can still
/// proceed on nil: an image nobody knew about simply dissents the unmount the
/// way it does today.
public func readAttachedImages(timeout: TimeInterval = 10) -> [AttachedImage]? {
    guard let plist = runPlistTool("/usr/bin/hdiutil", ["info", "-plist"], timeout: timeout)
    else { return nil }
    return parseAttachedImages(plist) { path in
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// A mount point with symlinks resolved, for matching against a backing path.
public func resolvedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}
