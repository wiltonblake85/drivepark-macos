// Chime.swift — the signal that reaches you with the screen off.
//
// A notification banner is useless at the moment it matters most: you lock the
// screen or close the lid, then reach for the cable. Audio is the only channel
// still open then, and NSSound plays regardless of notification permission,
// preview settings, or whether anyone granted anything.
//
// Three distinct sounds, never one. A single "done" tone would get you
// unplugging on a failed park, which is worse than silence.

import AppKit

enum Chime {
    /// Every managed volume verified unmounted. The cable is safe to pull.
    case safeToUnplug
    /// Some drives parked, others did not. Deliberately unfinished-sounding.
    case partial
    /// Nothing to act on, or a park that failed. Unmistakably a problem.
    case failed

    private var soundName: String {
        switch self {
        // Low and conclusive. Nothing else on the system sounds like it.
        case .safeToUnplug: return "Submarine"
        // Light and unresolved: something happened, you are not done.
        case .partial: return "Tink"
        // The macOS error tone. Decades of muscle memory say "stop."
        case .failed: return "Basso"
        }
    }

    func play() {
        NSSound(named: soundName)?.play()
    }
}
