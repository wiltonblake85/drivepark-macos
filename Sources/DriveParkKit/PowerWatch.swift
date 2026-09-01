// PowerWatch.swift — system sleep and wake, with the acknowledgement macOS
// actually requires.
//
// NSWorkspace.willSleepNotification is easier to use and wrong for this job:
// it tells you sleep is happening, it does not hold sleep open while you
// finish. IORegisterForSystemPower does, and the price is that every
// kIOMessageSystemWillSleep MUST be answered with IOAllowPowerChange. Miss one
// and the machine stalls for the full timeout before sleeping anyway.

import Foundation
import IOKit
import IOKit.pwr_mgt

public final class PowerWatch {
    /// Called when the machine is about to sleep. The handler MUST call the
    /// supplied closure when it is done. Calling it twice is harmless; never
    /// calling it hangs the sleep until macOS gives up.
    public typealias WillSleepHandler = (_ allowSleep: @escaping () -> Void) -> Void

    public var onWillSleep: WillSleepHandler?
    public var onDidWake: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var portRef: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    /// The kIOMessage* constants are function-like macros (iokit_common_msg)
    /// that Swift cannot import, so they are spelled out here. These values
    /// were read out of the SDK by compiling IOMessage.h on 2026-09-01, not
    /// recalled: sys_iokit | sub_iokit_common is 0xE0000000, plus the code.
    private enum Message {
        static let canSystemSleep: UInt32 = 0xE000_0270
        static let systemWillSleep: UInt32 = 0xE000_0280
        static let systemWillPowerOn: UInt32 = 0xE000_0320
        static let systemHasPoweredOn: UInt32 = 0xE000_0300
    }

    /// Registers for power notifications on the main run loop.
    /// - Returns: false when registration failed, so a caller can say so
    ///   instead of silently never firing.
    @discardableResult
    public func start() -> Bool {
        guard rootPort == 0 else { return true }
        var notifierObject: io_object_t = 0
        var port: IONotificationPortRef?
        let context = Unmanaged.passUnretained(self).toOpaque()

        let connection = IORegisterForSystemPower(context, &port, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let watch = Unmanaged<PowerWatch>.fromOpaque(refcon).takeUnretainedValue()
            watch.handle(messageType: messageType, argument: messageArgument)
        }, &notifierObject)

        guard connection != 0, let port else { return false }
        rootPort = connection
        notifier = notifierObject
        portRef = port

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    public func stop() {
        guard rootPort != 0 else { return }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let portRef { IONotificationPortDestroy(portRef) }
        rootPort = 0
        notifier = 0
        portRef = nil
        runLoopSource = nil
    }

    deinit { stop() }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        let port = rootPort

        if messageType == Message.canSystemSleep {
            // An idle-sleep request we could veto. We never do: a drive tool
            // that keeps the Mac awake is a worse bug than an unparked drive.
            IOAllowPowerChange(port, token)
            return
        }

        if messageType == Message.systemWillSleep {
            guard let onWillSleep else {
                IOAllowPowerChange(port, token)
                return
            }
            // Sleep is held open until this fires. Guarded so a handler that
            // both finishes and times out cannot acknowledge twice.
            let lock = NSLock()
            var acknowledged = false
            let allow: () -> Void = {
                lock.lock()
                defer { lock.unlock() }
                guard !acknowledged else { return }
                acknowledged = true
                IOAllowPowerChange(port, token)
            }
            onWillSleep(allow)
            return
        }

        if messageType == Message.systemHasPoweredOn {
            onDidWake?()
        }
    }
}
