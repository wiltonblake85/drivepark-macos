// Blockers.swift — names the processes holding open files on a mount point.

import Foundation

func lsofBlockers(mountPoint: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-Fpc", "+f", "--", mountPoint]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    var names: Set<String> = []
    var currentPid = ""
    for line in text.split(separator: "\n") {
        if line.hasPrefix("p") {
            currentPid = String(line.dropFirst())
        } else if line.hasPrefix("c") {
            names.insert("\(String(line.dropFirst())) (pid \(currentPid))")
        }
    }
    return names.sorted()
}
