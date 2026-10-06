// Tools.swift: every external tool DrivePark runs, run the same way.
//
// Observed on the TerraMaster DAS on 2026-08-31: the bridge stopped answering
// `diskutil info` on all three bays while `diskutil list` and `df` kept
// working. Every caller blocked in read() forever. A tool whose whole promise
// is telling the truth about stuck drives must not itself hang on one, so
// every child process gets a timeout and both of its pipes drained. Reading
// stdout while leaving stderr undrained deadlocks as soon as a command is
// verbose enough to fill that buffer.

import Foundation

/// What came back from running a tool.
enum ToolRun {
    case finished(status: Int32, output: Data)
    case timedOut
    case couldNotLaunch(String)
}

func runTool(_ executable: String, _ args: [String], timeout: TimeInterval) -> ToolRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return .couldNotLaunch(error.localizedDescription) }

    let readers = DispatchQueue(label: "drivepark.tool.read", attributes: .concurrent)
    let group = DispatchGroup()
    let box = DataBox()
    readers.async(group: group) {
        box.set(out.fileHandleForReading.readDataToEndOfFile())
    }
    readers.async(group: group) {
        _ = err.fileHandleForReading.readDataToEndOfFile()
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if group.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
            // A process blocked in the kernel on an unresponsive USB bridge
            // does not always answer SIGTERM.
            kill(process.processIdentifier, SIGKILL)
        }
        return .timedOut
    }

    process.waitUntilExit()
    return .finished(status: process.terminationStatus, output: box.get())
}

/// A plist, or the reason there is none, in words a person can act on.
///
/// The reason matters. "Nothing came back" and "nothing is there" read the
/// same once they are both an empty array, and on 2026-10-05 the audit traced
/// exactly that confusion to a park reported as safe while three volumes were
/// still mounted.
enum PlistRead {
    case plist([String: Any])
    case failed(reason: String, timedOut: Bool)

    var plist: [String: Any]? {
        if case .plist(let value) = self { return value }
        return nil
    }
}

func readPlist(_ executable: String, _ args: [String],
               timeout: TimeInterval = 10) -> PlistRead {
    let command = ([URL(fileURLWithPath: executable).lastPathComponent] + args)
        .joined(separator: " ")
    switch runTool(executable, args, timeout: timeout) {
    case .couldNotLaunch(let why):
        return .failed(reason: "\(command) could not start: \(why)", timedOut: false)
    case .timedOut:
        return .failed(reason: "\(command) did not answer in \(Int(timeout))s", timedOut: true)
    case .finished(let status, let data):
        guard status == 0 else {
            return .failed(reason: "\(command) exited with status \(status)", timedOut: false)
        }
        guard let plist = (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any] else {
            return .failed(reason: "\(command) answered with something that is not a plist",
                           timedOut: false)
        }
        return .plist(plist)
    }
}

/// For callers that can only use a plist and have their own fallback.
func runPlistTool(_ executable: String, _ args: [String],
                  timeout: TimeInterval = 10) -> [String: Any]? {
    readPlist(executable, args, timeout: timeout).plist
}

func diskutil(_ args: [String], timeout: TimeInterval = 10) -> PlistRead {
    readPlist("/usr/sbin/diskutil", args, timeout: timeout)
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
