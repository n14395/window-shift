import AppKit
import CoreGraphics

/// Owns the CGEventTap and the dedicated thread whose run loop services it.
final class EventTap {
    static let permissionLostNotification = Notification.Name("WindowShiftPermissionLost")

    let controller: DragController
    private var tap: CFMachPort?
    private var keyTap: CFMachPort?
    private var disableTimestamps: [Date] = []

    init(controller: DragController) {
        self.controller = controller
    }

    /// Create and start the tap. Returns false if creation fails (no
    /// Accessibility permission, or launched as a background-only process).
    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue)

        // Session-level, head-insert, active tap: we mutate events in place.
        // (HID-level location mutation is unreliable — see plan.)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowShiftTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap

        // Keyboard tap for Esc-cancel. Created disabled and armed only while
        // a modifier-drag gesture is in flight, so no keystrokes flow through
        // WindowShift at any other time. Runs on the same thread/run loop as
        // the mouse tap, so cancelDrag() never races handle(). Creation can
        // fail independently of the mouse tap; the feature just degrades.
        let keyTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: windowShiftKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        self.keyTap = keyTap
        controller.onDragActiveChanged = { [weak self] active in
            guard let keyTap = self?.keyTap else { return }
            CGEvent.tapEnable(tap: keyTap, enable: active)
        }

        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            if let keyTap {
                let keySource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyTap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), keySource, .commonModes)
                CGEvent.tapEnable(tap: keyTap, enable: false)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "WindowShift.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Called from the tap callback when the system disabled the tap
    /// (callback timeout or user input protection). Re-enable from the main
    /// thread; rapid repeated disables mean the Accessibility grant was
    /// revoked (WindowServer kills revoked taps) — surface that instead.
    func handleDisable() {
        DragController.diagNote("TAP DISABLED (timeout or user-input) — gesture in flight dropped")
        // The events of the gesture in flight — crucially its mouse-up — were
        // never delivered while the tap was off, so the state machine would sit
        // waiting for one forever and ignore every later drag. Start clean.
        controller.resetGesture()

        // Ask TCC rather than inferring from how often we were disabled: a busy
        // machine can overrun the callback timeout several times in a row, and
        // treating that as a revoked grant used to leave the tap switched off
        // for good behind an alarming (and wrong) alert.
        let revoked = !AXIsProcessTrusted()
        let now = Date()
        disableTimestamps.append(now)
        disableTimestamps.removeAll { now.timeIntervalSince($0) > 2.0 }
        // Still rate-limit: a tap that is disabled the instant we re-enable it
        // would otherwise spin.
        let flapping = disableTimestamps.count >= 8

        guard let tap else { return }
        DispatchQueue.main.async { [weak self] in
            if revoked {
                NotificationCenter.default.post(name: Self.permissionLostNotification, object: nil)
            } else if flapping {
                self?.disableTimestamps.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            } else {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }
}

private func windowShiftTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let eventTap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        eventTap.handleDisable()
        return nil
    }
    let started = Date()
    defer {
        let ms = Date().timeIntervalSince(started) * 1000
        if ms > 100 { DragController.diagNote("slow tap callback: \(Int(ms))ms for \(type.rawValue)") }
    }
    return eventTap.controller.handle(type: type, event: event)
}

/// Esc keyboard tap: only ever enabled while a modifier-drag gesture is in
/// flight (see onDragActiveChanged). Esc cancels the drag and is consumed;
/// everything else passes through untouched.
private func windowShiftKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let refcon else { return pass }
    let eventTap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        eventTap.controller.resetGesture()
        return nil   // re-armed at the next gesture via onDragActiveChanged
    }
    if type == .keyDown,
       event.getIntegerValueField(.keyboardEventKeycode) == 53,  // Esc
       eventTap.controller.cancelDrag() {
        return nil
    }
    return pass
}
