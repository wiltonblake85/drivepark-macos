// HotKey.swift — one keystroke to park, from anywhere.
//
// Carbon's RegisterEventHotKey rather than NSEvent.addGlobalMonitorForEvents.
// The NSEvent route needs Accessibility permission, sees every keystroke you
// type all day, and cannot consume the event. RegisterEventHotKey needs no
// permission, sees only its own combination, and is what menu bar apps have
// used for twenty years. Deprecated-looking, entirely functional, and the
// honest trade.
//
// Registration can fail because another app already owns the combination.
// That failure is reported, never swallowed: a hotkey you believe in and that
// does not exist is worse than no hotkey, because you press it on your way out
// the door and walk off with the drives still mounted.

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 'DPRK'. Identifies our hot key in the Carbon event stream.
    private static let signature: OSType = 0x4450_524B
    private static let identifier: UInt32 = 1

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Runs on the main thread when the combination is pressed.
    var action: (() -> Void)?

    /// Control + Option + Command + P. Four-finger combinations are chosen to
    /// be hard to hit by accident, since this one unmounts drives.
    static let defaultKeyCode = UInt32(kVK_ANSI_P)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    /// Human-readable, for the menu. If the menu says a shortcut exists, the
    /// shortcut has to exist.
    static let displayName = "⌃⌥⌘P"

    private(set) var isRegistered = false
    private(set) var failure: String?

    private init() {}

    @discardableResult
    func register() -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let got = GetEventParameter(event,
                                            EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard got == noErr, pressed.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { HotKeyCenter.shared.action?() }
                }
                return noErr
            }, 1, &eventType, nil, &handler)
            guard status == noErr else {
                failure = "Could not install the keyboard handler (error \(status))."
                isRegistered = false
                return false
            }
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        var created: EventHotKeyRef?
        let status = RegisterEventHotKey(Self.defaultKeyCode, Self.defaultModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &created)
        guard status == noErr, created != nil else {
            failure = "\(Self.displayName) is already taken by another app."
            isRegistered = false
            return false
        }
        ref = created
        isRegistered = true
        failure = nil
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        isRegistered = false
    }
}
