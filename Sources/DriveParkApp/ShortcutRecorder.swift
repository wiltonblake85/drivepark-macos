// ShortcutRecorder.swift — press the combination you want, see it, save it.
//
// Two things make this correct rather than merely present.
//
// The live shortcut is unregistered for as long as the panel is open. Without
// that, pressing your intended new combination parks your drives instead of
// being recorded, which is a genuinely bad first experience for a feature
// whose whole job is capturing keystrokes.
//
// The printed form is captured at record time and stored, not derived later
// from the key code. Going from a key code back to a character means asking
// the current keyboard layout, so a shortcut recorded on one layout would
// print wrong after switching to another.

import AppKit
import Carbon.HIToolbox
import DriveParkKit

/// The view that actually listens. Everything else here is chrome.
final class ShortcutCaptureView: NSView {
    var onCapture: ((UInt32, UInt32, String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Shift alone is not enough. Shift plus a letter is something people
        // type all day, and stealing it globally would be hostile.
        let meaningful: NSEvent.ModifierFlags = [.command, .control, .option]
        guard !flags.intersection(meaningful).isEmpty else {
            NSSound.beep()
            return
        }

        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        var printed = ""
        if flags.contains(.control) { printed += "⌃" }
        if flags.contains(.option)  { printed += "⌥" }
        if flags.contains(.shift)   { printed += "⇧" }
        if flags.contains(.command) { printed += "⌘" }
        printed += Self.name(for: event)

        onCapture?(UInt32(event.keyCode), carbon, printed)
    }

    /// Prefer the character the key produces without modifiers, so an Option
    /// combination does not print the accented character it would type.
    private static func name(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩",
            UInt16(kVK_Tab): "⇥", UInt16(kVK_Escape): "⎋",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
            UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟"
        ]
        if let named = special[event.keyCode] { return named }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }
        return "Key \(event.keyCode)"
    }
}

@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    static let shared = ShortcutRecorder()

    private var panel: NSPanel?
    private var preview: NSTextField?
    private var saveButton: NSButton?
    private var captured: (code: UInt32, modifiers: UInt32, display: String)?

    /// Called after a successful save so the caller can re-register and
    /// refresh its menu.
    var onSaved: (() -> Void)?

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // The live shortcut must not fire while we are trying to capture one.
        HotKeyCenter.shared.unregister()

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "DrivePark Shortcut"
        window.isFloatingPanel = true
        window.delegate = self
        window.center()

        let content = NSView(frame: window.contentLayoutRect)

        let capture = ShortcutCaptureView(frame: content.bounds)
        capture.autoresizingMask = [.width, .height]
        capture.onCapture = { [weak self] code, modifiers, display in
            self?.captured = (code, modifiers, display)
            self?.preview?.stringValue = display
            self?.saveButton?.isEnabled = true
        }
        content.addSubview(capture)

        let instruction = NSTextField(labelWithString:
            "Press the combination you want. It needs Command, Control or Option.")
        instruction.frame = NSRect(x: 20, y: 140, width: 360, height: 20)
        instruction.alignment = .center
        instruction.font = .systemFont(ofSize: 11)
        instruction.textColor = .secondaryLabelColor
        content.addSubview(instruction)

        let shown = NSTextField(labelWithString: Preferences.hotKeyDisplay)
        shown.frame = NSRect(x: 20, y: 85, width: 360, height: 44)
        shown.alignment = .center
        shown.font = .systemFont(ofSize: 30, weight: .medium)
        content.addSubview(shown)
        preview = shown

        let warning = NSTextField(labelWithString:
            "This unmounts your drives, so pick something you will not hit by accident.")
        warning.frame = NSRect(x: 20, y: 60, width: 360, height: 18)
        warning.alignment = .center
        warning.font = .systemFont(ofSize: 10)
        warning.textColor = .tertiaryLabelColor
        content.addSubview(warning)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.frame = NSRect(x: 290, y: 15, width: 90, height: 30)
        save.bezelStyle = .rounded
        save.keyEquivalent = ""      // Return is a recordable key, not a default action
        save.isEnabled = false
        content.addSubview(save)
        saveButton = save

        let reset = NSButton(title: "Use Default", target: self, action: #selector(useDefault))
        reset.frame = NSRect(x: 175, y: 15, width: 105, height: 30)
        reset.bezelStyle = .rounded
        content.addSubview(reset)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 20, y: 15, width: 90, height: 30)
        cancel.bezelStyle = .rounded
        content.addSubview(cancel)

        window.contentView = content
        panel = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(capture)
    }

    @objc private func save() {
        guard let captured else { return }

        // Registration would succeed on a system combination and the shortcut
        // would still never fire, so this check has to happen before it, not
        // instead of it.
        if let owner = SystemShortcuts.owner(keyCode: captured.code,
                                             carbonModifiers: captured.modifiers) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(captured.display) belongs to \(owner)"
            alert.informativeText = "macOS handles that combination before any app "
                + "sees it. DrivePark could claim it without error and it would "
                + "still never fire. Pick a different one."
            alert.runModal()
            self.captured = nil
            preview?.stringValue = Preferences.hotKeyDisplay
            saveButton?.isEnabled = false
            return
        }

        let previousCode = Preferences.hotKeyCode
        let previousModifiers = Preferences.hotKeyModifiers
        let previousDisplay = Preferences.hotKeyDisplay

        Preferences.hotKeyCode = captured.code
        Preferences.hotKeyModifiers = captured.modifiers
        Preferences.hotKeyDisplay = captured.display

        // Verify by registering it for real. Another app may already own it,
        // and finding that out now beats finding out on the way out the door.
        if HotKeyCenter.shared.register() {
            close()
            onSaved?()
        } else {
            Preferences.hotKeyCode = previousCode
            Preferences.hotKeyModifiers = previousModifiers
            Preferences.hotKeyDisplay = previousDisplay
            _ = HotKeyCenter.shared.register()
            preview?.stringValue = previousDisplay
            saveButton?.isEnabled = false
            self.captured = nil

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(captured.display) is already taken"
            alert.informativeText = "Another app owns that combination, so DrivePark "
                + "cannot register it. Your previous shortcut, \(previousDisplay), is "
                + "still active. Try a different one."
            alert.runModal()
        }
    }

    @objc private func useDefault() {
        Preferences.resetHotKeyToDefault()
        _ = HotKeyCenter.shared.register()
        close()
        onSaved?()
    }

    @objc private func cancel() {
        close()
        onSaved?()
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        preview = nil
        saveButton = nil
        captured = nil
    }

    func windowWillClose(_ notification: Notification) {
        // However the panel goes away, the shortcut comes back.
        panel = nil
        _ = HotKeyCenter.shared.register()
        onSaved?()
    }
}
