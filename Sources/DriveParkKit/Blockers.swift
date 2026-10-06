// Blockers.swift: names the processes holding open files on a mount point.

import Foundation

/// Ten seconds, the same as every other tool here. lsof walks every open file
/// on the machine, and during an enclosure stall a stat on the stuck mount can
/// block; before this it ran with no timeout and an undrained stderr, so one
/// stall could hang a park and leave the app busy until it was relaunched.
func lsofBlockers(mountPoint: String, timeout: TimeInterval = 10) -> [String] {
    guard case .finished(_, let data) = runTool(
        "/usr/sbin/lsof", ["-Fpc", "+f", "--", mountPoint], timeout: timeout),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return parseLsofBlockers(text)
}

/// lsof exits 1 when it finds nothing, so the status says nothing useful and
/// only the output is read.
func parseLsofBlockers(_ text: String) -> [String] {
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
