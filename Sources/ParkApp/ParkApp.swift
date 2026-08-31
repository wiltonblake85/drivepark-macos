// ParkApp — menu bar app over ParkKit. While this app runs after a full
// park, the remount veto stays armed; Release drops it and remounts.

import SwiftUI
import AppKit
import ParkKit

@main
struct ParkApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            Image(systemName: state.iconName)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var disks: [PhysicalDisk] = []
    @Published var busy = false
    @Published var message = ""

    let engine = Engine()
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var volumes: [Volume] { disks.flatMap { $0.allVolumes } }
    var mountedCount: Int { volumes.filter { $0.isMounted }.count }
    var isParked: Bool { !volumes.isEmpty && mountedCount == 0 }

    var iconName: String {
        if volumes.isEmpty { return "externaldrive.badge.questionmark" }
        if isParked { return "externaldrive.badge.checkmark" }
        return "externaldrive"
    }

    var statusLine: String {
        if volumes.isEmpty { return "No external disks found" }
        if isParked { return "Parked — safe to power off" }
        return "\(mountedCount) of \(volumes.count) volumes mounted"
    }

    func refresh() {
        let engine = self.engine
        Task.detached {
            let found = engine.discover()
            await MainActor.run { [weak self] in self?.disks = found }
        }
    }

    func park(only: Set<String>? = nil, label: String? = nil) {
        guard !busy else { return }
        busy = true
        message = "Parking…"
        let engine = self.engine
        Task.detached {
            let outcome = engine.park(onlyDisks: only)
            let found = engine.discover()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.busy = false
                if outcome.parked {
                    self.message = label.map { "\($0) parked." } ?? "Parked. Safe to power off the tower."
                } else {
                    let names = outcome.stillMounted.map { $0.displayName }.joined(separator: ", ")
                    var text = "Not parked. Still mounted: \(names)."
                    if let blockers = outcome.blockerSummary { text += " Blocked by \(blockers)." }
                    self.message = text
                }
            }
        }
    }

    func release(only: Set<String>? = nil, label: String? = nil) {
        guard !busy else { return }
        busy = true
        message = "Remounting…"
        let engine = self.engine
        Task.detached {
            let (mounted, total) = engine.release(onlyDisks: only)
            let found = engine.discover()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.busy = false
                if let label {
                    self.message = "\(label) back online."
                } else {
                    self.message = mounted == total
                        ? "All volumes back online."
                        : "\(mounted) of \(total) volumes mounted."
                }
            }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.statusLine)
        Divider()
        ForEach(state.disks, id: \.device) { disk in
            let mountedHere = disk.allVolumes.contains { $0.isMounted }
            let label = disk.allVolumes.map { $0.displayName }.joined(separator: ", ")
            Button(mountedHere ? "Park \(label)" : "Release \(label)") {
                if mountedHere {
                    state.park(only: [disk.device], label: label)
                } else {
                    state.release(only: [disk.device], label: label)
                }
            }
            .disabled(state.busy || disk.allVolumes.isEmpty)
        }
        Divider()
        Button(state.busy ? "Working…" : "Park Tower") {
            state.park()
        }
        .disabled(state.busy || state.isParked || state.volumes.isEmpty)
        Button("Release (remount all)") {
            state.release()
        }
        .disabled(state.busy || state.volumes.isEmpty || state.mountedCount == state.volumes.count)
        if !state.message.isEmpty {
            Divider()
            Text(state.message)
        }
        Divider()
        Button("Refresh") { state.refresh() }
        Button("Quit Park") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
