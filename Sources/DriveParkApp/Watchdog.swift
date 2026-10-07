// Watchdog.swift — the mode that keeps DrivePark running, so that the menu bar
// app never has to be launchd's own child.
//
// THE BUG THIS FIXES, 2026-09-03. The LaunchAgent runs this binary, and it used
// to run it as the app. That made the running app the job itself, so
// SMAppService.unregister(), which is what "Keep DrivePark running" calls when
// you switch it OFF, removed the job, and launchd removes a job by killing its
// process:
//
//   12:19:16.419  DrivePark[61239] (AppKit) perform action for menu item
//   12:19:16.439  agent [61239]  removing job: caller = smd
//   12:19:16.443  agent [61239]  exited due to SIGTERM | sent by launchd[1]
//
// Twenty-four milliseconds from the click to a dead app, and no crash report,
// because nothing crashed. Switching the watchdog off killed the thing it was
// watching, every time, and no code could have saved it: the code that would
// have noticed was inside the process being killed.
//
// ONE BINARY, TWO MODES, AND WHY NOT TWO BINARIES. The first fix was a separate
// DriveParkWatchdog executable in Contents/MacOS with the agent pointed at it.
// It compiled, ran correctly by hand, and launchd refused to spawn it:
//
//   Service could not initialize: copy_bundle_path(...), error 0x6f
//   last exit reason = OS_REASON_CODESIGNING
//
// The job carries a launch requirement generated from the registering app:
//
//   LWCR = { signing-identifier => com.wiltonblake.drivepark,
//            team-identifier => 4G2DZU69L8, validation-category => 6 }
//
// A nested helper signed under its own identifier fails that, and one signed
// under the app's identifier fails code-signing validation instead. Running the
// app's own binary satisfies it by construction, needs no nested signing, and
// leaves BundleProgram exactly as it already is, so no installed copy has to be
// re-registered to get the fix.
//
// launchd sets XPC_SERVICE_NAME to the job label for jobs it manages, verified
// on this hardware: the agent-started copy carries
// XPC_SERVICE_NAME=com.wiltonblake.drivepark.agent and a hand-started one
// carries nothing. That is the whole discriminator.
//
// Four things this mode deliberately will not do:
//
//   - Relaunch after Quit. The app stamps quitRequestedAt on its way out, and a
//     stamp under ten seconds old means a human meant it. An app that comes
//     back after you quit it is malware behaviour. The stamp expires, so a
//     stale one can never suppress a real rescue.
//
//   - Relaunch during a build. build-app.sh deletes and rewrites the bundle,
//     and launching a half-written bundle is how the app vanished with no crash
//     report on 2026-09-01. The script sets watchdogPausedUntil for the
//     duration, and this checks the executable is really there besides.
//
//   - Relaunch forever. Five deaths inside ten minutes is a crash loop, not a
//     rescue. It used to back off for a minute and start again, which was
//     five relaunches a minute for as long as the Mac stayed up (audit, Low).
//     Now it stops, records why, and the app says so the next time a person
//     starts it (RelaunchBudget).
//
//   - Claim to be working when it is not. It writes a heartbeat every cycle and
//     the menu reads it, so "on" in the menu means watched, not merely
//     registered. A watchdog nobody can check is a promise, not a mechanism.

import AppKit
import DriveParkKit
import Foundation

enum AgentMode {
    static let agentLabel = "com.wiltonblake.drivepark.agent"

    /// True when launchd started this process from the watchdog agent.
    static var isWatchdog: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel
    }
}

final class Watchdog {
    /// One instance, held for the life of the process.
    ///
    /// Not decoration. Built as a temporary, this object is deallocated the
    /// moment run() is called, every [weak self] capture in the observer and
    /// the timer resolves to nil, and the watchdog ticks forever doing
    /// nothing: a watchdog that reports for duty and then watches nothing at
    /// all. The compiler caught it on 2026-09-03, which is the only reason it
    /// was caught, because the failure is completely silent at runtime.
    static let shared = Watchdog()

    /// The crash-loop guard.
    private var budget = RelaunchBudget()
    /// The fast path and the poll can both see one death before the
    /// relaunch has landed; this keeps that from counting as two.
    private var relaunchInFlightUntil: Date?

    /// Latched when a quit is seen, cleared when the app is seen running again.
    ///
    /// A timestamp alone is not enough, and the regression test caught it. The
    /// stamp was read once, honoured, and cleared, and five seconds later the
    /// poll found no stamp and relaunched the app anyway. Quit is not a ten
    /// second window, it is a state: stay down until a human opens it again.
    /// The stamp still expires so a stale one cannot wedge a fresh watchdog
    /// after a reboot, where launching the app is the correct thing to do.
    private var standDown = false

    /// This process is the app's own binary, so the bundle to relaunch is
    /// simply the one it is running out of.
    private let appURL = Bundle.main.bundleURL

    private var appIsRunning: Bool {
        let me = NSRunningApplication.current.processIdentifier
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != me }
    }

    /// Never returns. Called before SwiftUI builds a scene, so this process
    /// puts nothing in the menu bar.
    func run() -> Never {
        Preferences.recordDiagnostic("watchdog", "watching \(appURL.path)")

        // Fast path. Fires within milliseconds of the app going away.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            self?.considerRelaunch(reason: "termination notice")
        }

        // Backstop, and the one that cannot be missed. It covers a dropped
        // notification, and the case where the app was already gone before this
        // watchdog started.
        // Every 15 s with 5 s of slack: the termination notice above is the
        // fast path, so this only has to be sure, not quick.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        tick()

        RunLoop.main.run()
        exit(0)
    }

    private func tick() {
        Preferences.recordWatchdogHeartbeat()
        if appIsRunning {
            // Seeing it running is what ends a stand-down. The user opened it
            // again, so the watch resumes.
            if standDown || budget.exhausted {
                standDown = false
                budget.reset()
                Preferences.recordDiagnostic("watchdog", "app is back, watching again")
            }
            return
        }
        considerRelaunch(reason: "poll")
    }

    private func considerRelaunch(reason: String) {
        guard !appIsRunning else { return }

        if let until = Preferences.watchdogPausedUntil, until > Date() { return }

        if Preferences.quitWasRequested {
            standDown = true
            Preferences.clearQuitRequest()
            Preferences.recordDiagnostic("watchdog", "quit was deliberate, staying down")
            return
        }

        // Still down because a human closed it. Not a failure, so it is not
        // reported again on every poll.
        if standDown { return }

        // Gave up on a crash loop. Said once, when it happened.
        if budget.exhausted { return }

        if let until = relaunchInFlightUntil, until > Date() { return }

        // A half-written bundle is worse than no app at all. macOS kills it a
        // moment later with no crash report, which is the failure this whole
        // mode exists to catch.
        let exe = appURL.appendingPathComponent("Contents/MacOS/DrivePark")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            Preferences.recordDiagnostic("watchdog", "bundle incomplete, waiting")
            return
        }

        let now = Date()
        guard budget.noteDeath(at: now) else {
            giveUp(at: now)
            return
        }
        relaunchInFlightUntil = now.addingTimeInterval(10)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                Preferences.recordDiagnostic(
                    "watchdog", "relaunch failed: \(error.localizedDescription)")
            } else {
                Preferences.recordDiagnostic("watchdog", "relaunched after \(reason)")
            }
        }
    }

    /// Stops relaunching and leaves word for the person. The app shows it the
    /// next time it starts, `park status` shows it until then, and if notch
    /// cards are on, one goes up now, because this process has no menu.
    private func giveUp(at date: Date) {
        Preferences.watchdogGaveUpAt = date
        Preferences.recordDiagnostic(
            "watchdog", "\(RelaunchBudget.limit) crashes in \(Int(RelaunchBudget.window / 60)) minutes, stopped restarting")
        Transom.postAndWait(
            title: "DrivePark keeps crashing",
            message: "The watchdog stopped restarting it. Automatic parking is off until you open DrivePark again.",
            symbol: "exclamationmark.triangle.fill",
            persistent: true)
    }

    /// The sentence for the menu and the CLI.
    static func gaveUpSentence(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "DrivePark crashed \(RelaunchBudget.limit) times in \(Int(RelaunchBudget.window / 60)) minutes "
            + "and the watchdog stopped restarting it at \(formatter.string(from: date)). "
            + "It is watching again now."
    }
}
