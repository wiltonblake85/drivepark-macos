// DriveParkApp — menu bar app over DriveParkKit. While this app runs after a
// full park, the remount veto stays armed; Release drops it and remounts.

import SwiftUI
import AppKit
import DriveParkKit

@main
struct DriveParkApp: App {
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
    @Published var lastVerifiedAt: Date?
    @Published var enclosureStalled = false
    /// Guards the 30-second timer. Before diskutil calls had a timeout, a
    /// stalled enclosure made this timer stack a new hung child process every
    /// 30 seconds, forever, in silence.
    private var refreshing = false

    // Mirrors of persisted preferences, so SwiftUI sees the changes.
    @Published var enabledTriggers: Set<ParkTrigger> = Preferences.enabledTriggers
    @Published var autoReleaseOnWake: Bool = Preferences.autoReleaseOnWake
    @Published var launchAtLogin: Bool = LoginItem.isEnabled

    let engine = Engine()
    private let triggers = TriggerCoordinator()
    private var timer: Timer?

    init() {
        refresh()
        triggers.state = self
        triggers.start()
        if let failure = triggers.powerWatchFailure { message = failure }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var volumes: [Volume] { disks.flatMap { $0.allVolumes } }
    var mountedCount: Int { volumes.filter { $0.isMounted }.count }
    var isParked: Bool { !volumes.isEmpty && mountedCount == 0 }

    var iconName: String {
        if enclosureStalled { return "externaldrive.badge.exclamationmark" }
        if volumes.isEmpty { return "externaldrive.badge.questionmark" }
        if isParked { return "externaldrive.badge.checkmark" }
        return "externaldrive"
    }

    var statusLine: String {
        if volumes.isEmpty { return "No external disks found" }
        if enclosureStalled { return "Enclosure not fully answering" }
        if isParked { return "Parked, safe to power off" }
        return "\(mountedCount) of \(volumes.count) volumes mounted"
    }

    /// The receipt. Every claim in this app traces to a fresh state read, and
    /// this is when the last one happened.
    var verifiedLine: String? {
        guard let lastVerifiedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "Verified \(formatter.string(from: lastVerifiedAt))"
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let engine = self.engine
        Task.detached {
            let found = engine.discover()
            let stalled = DiskutilTimeout.occurred
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.lastVerifiedAt = Date()
                self.enclosureStalled = stalled
                self.refreshing = false
                if stalled, self.message.isEmpty || self.message.hasPrefix("Enclosure") {
                    self.message = "Enclosure not answering detail queries. Volume state is still accurate."
                }
            }
        }
    }

    // MARK: - Manual actions

    func park(only: Set<String>? = nil, label: String? = nil) {
        triggers.noteManualPark()
        runPark(only: only, deadline: nil, label: label, completion: nil)
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
                self.lastVerifiedAt = Date()
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

    // MARK: - Trigger-driven actions

    /// - Parameter completion: receives nil when no park was attempted, so a
    ///   caller holding sleep open can tell "done" from "never ran".
    func park(trigger: ParkTrigger, deadline: Date?,
              completion: ((ParkOutcome?) -> Void)?) {
        runPark(only: nil, deadline: deadline, label: nil,
                triggerLabel: trigger.reason, completion: completion)
    }

    func release(reason: String) {
        release(only: nil, label: nil)
        message = "Remounted after \(reason)."
    }

    private func runPark(only: Set<String>?, deadline: Date?, label: String?,
                         triggerLabel: String? = nil,
                         completion: ((ParkOutcome?) -> Void)?) {
        guard !busy else {
            // Nothing was attempted. Report that, rather than an empty park
            // that would read as success.
            completion?(nil)
            return
        }
        busy = true
        message = triggerLabel.map { "Parking because \($0)…" } ?? "Parking…"
        let engine = self.engine
        Task.detached {
            let outcome = engine.park(onlyDisks: only, deadline: deadline)
            let found = engine.discover()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.lastVerifiedAt = Date()
                self.busy = false
                self.message = Self.describe(outcome, label: label, trigger: triggerLabel)
            }
            completion?(outcome)
        }
    }

    private static func describe(_ outcome: ParkOutcome, label: String?,
                                 trigger: String?) -> String {
        if outcome.parked {
            if let label { return "\(label) parked." }
            if let trigger { return "Parked because \(trigger). Safe to power off." }
            return "Parked. Safe to power off the tower."
        }
        let names = outcome.stillMounted.map { $0.displayName }.joined(separator: ", ")
        var text = "Not parked. Still mounted: \(names)."
        if let blockers = outcome.blockerSummary { text += " Blocked by \(blockers)." }
        return text
    }

    // MARK: - Settings

    func setTrigger(_ trigger: ParkTrigger, _ on: Bool) {
        Preferences.setEnabled(trigger, on)
        enabledTriggers = Preferences.enabledTriggers
    }

    func setAutoRelease(_ on: Bool) {
        Preferences.autoReleaseOnWake = on
        autoReleaseOnWake = on
    }

    func setLaunchAtLogin(_ on: Bool) {
        if let failure = LoginItem.setEnabled(on) {
            message = failure
        } else {
            message = on ? "DrivePark will start at login." : "DrivePark will not start at login."
        }
        launchAtLogin = LoginItem.isEnabled
    }
}

private extension ParkTrigger {
    var reason: String {
        switch self {
        case .systemSleep: return "the Mac is going to sleep"
        case .displaySleep: return "the displays turned off"
        case .screenLock: return "the screen locked"
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.statusLine)
        if let verified = state.verifiedLine {
            Text(verified)
        }
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

        Divider()
        Menu("Automation") {
            ForEach(ParkTrigger.allCases, id: \.self) { trigger in
                Toggle(trigger.label, isOn: Binding(
                    get: { state.enabledTriggers.contains(trigger) },
                    set: { state.setTrigger(trigger, $0) }))
            }
            Divider()
            Toggle("Remount automatically on wake", isOn: Binding(
                get: { state.autoReleaseOnWake },
                set: { state.setAutoRelease($0) }))
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }))
        }

        if !state.message.isEmpty {
            Divider()
            Text(state.message)
        }
        Divider()
        Button("Refresh") { state.refresh() }
        Button("Quit DrivePark") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
