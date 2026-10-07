// ScreenLock.swift: is the screen really locked?
//
// The screen-lock trigger listens for com.apple.screenIsLocked, a distributed
// notification, and any process on the Mac can post one. Until 2026-10-07 a
// post was enough to park every drive (audit, Low; the round-two hand test
// fired the trigger exactly that way). The login session's own record says
// whether the screen is locked, and a park now waits for it to agree.

import CoreGraphics
import Foundation

public enum ScreenLock {
    /// The window server's answer: the key is present and true while the
    /// screen is locked, and absent otherwise (read on the tower 2026-10-07).
    public static func isLocked(session: [String: Any]?) -> Bool {
        (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    public static var isLockedNow: Bool {
        isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// How long to keep asking after the notification, cumulative seconds.
    /// The notification and the session record are written by different
    /// processes, so the record may land a moment later.
    public static let checkTimes: [TimeInterval] = [0, 0.3, 1, 2.5]
}
