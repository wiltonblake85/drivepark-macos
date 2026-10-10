// Wake.swift: spin a drive up before asking macOS to unmount it.
//
// Traced 2026-10-10 (SPEC section 10, "A slow park is the drives waking up"):
// the tower's drives go idle within about a minute, and a park that lands on
// idle drives waits for them one after another. Whatever has to touch the
// disk waits for spin-up, an approval client that looks at the volume can
// miss Disk Arbitration's 10 s window, and the waits queue. Worst measured:
// 25.03 s, past the 20 s a sleep park is allowed.
//
// Reading from every drive at once, before the first unmount request, makes
// the spin-ups overlap. Read only: nothing on the drive is written, opened
// for writing, or left open.

import Foundation

/// What waking one drive came to.
public enum WakeResult: Equatable, Sendable {
    /// A read came back, after this long. Several seconds means the drive had
    /// spun down; a few hundredths means it was already awake.
    case woke(seconds: TimeInterval)
    /// No read came back in time. The park goes on without waiting further.
    case timedOut
    /// Nothing under the mount point could be read: no regular file, or none
    /// this user may open.
    case nothingToRead
}

/// Reads 64 KB from one file under `root`, past every cache, so the disk
/// itself has to answer. Returns whether a read came back.
///
/// The file is the largest regular one found in a short breadth-first look:
/// hidden entries and symbolic links are skipped, at most `maxEntries` names
/// are looked at, and the look stops at the first file of a megabyte or
/// more. The read is at a random 4 KB-aligned offset inside it with
/// F_NOCACHE, so neither the unified buffer cache nor the drive's own cache
/// is likely to hold it. Only the read's success is used; the bytes are
/// discarded and nothing about the file is logged.
func uncachedProbeRead(under root: String, maxEntries: Int = 400) -> Bool {
    var queue = [root]
    var looked = 0
    var candidates: [(path: String, size: Int64)] = []
    let fileManager = FileManager.default
    search: while !queue.isEmpty {
        let directory = queue.removeFirst()
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
        for name in names where !name.hasPrefix(".") {
            looked += 1
            if looked > maxEntries { break search }
            let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                if queue.count < 64 { queue.append(path) }
            case S_IFREG:
                if info.st_size >= 4096 { candidates.append((path, Int64(info.st_size))) }
            default:
                continue
            }
        }
        if candidates.contains(where: { $0.size >= 1 << 20 }) { break }
    }
    for candidate in candidates.sorted(by: { $0.size > $1.size }).prefix(3) {
        // O_NONBLOCK so a name swapped for a FIFO since the lstat cannot hang
        // the open; the fstat below then refuses anything but a regular file.
        let fd = open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { continue }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
        _ = fcntl(fd, F_NOCACHE, 1)
        let span = max(Int64(0), Int64(info.st_size) - 65536)
        let offset = span > 0 ? Int64.random(in: 0...span) & ~Int64(4095) : 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 65536, off_t(offset)) }
        if got > 0 { return true }
    }
    return false
}

/// One wake's answer, handed from the reading thread to the waiting one.
final class WakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: WakeResult?

    func finish(_ value: WakeResult) {
        lock.lock(); result = value; lock.unlock()
        done.signal()
    }

    /// The answer, or nil when none came within `timeout`.
    func wait(timeout: TimeInterval) -> WakeResult? {
        guard done.wait(timeout: .now() + max(0, timeout)) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
