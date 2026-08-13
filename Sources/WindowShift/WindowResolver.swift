import AppKit
import ApplicationServices

struct TargetWindow {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    /// CG global coordinates (y-down, origin at top-left of main display).
    /// AX position/size use the same space, so no flipping is needed.
    let frame: CGRect
}

enum WindowResolver {
    private static let systemWide = AXUIElementCreateSystemWide()

    /// Every AX call below runs INSIDE the event-tap callback, where the whole
    /// session's mouse delivery waits on our verdict. The default AX messaging
    /// timeout is 6 s PER CALL, so one busy/unresponsive target app used to wedge
    /// every click in the session for tens of seconds (worse: a target blocked in
    /// menu tracking waits for mouse events that are queued behind OUR tap — a
    /// deadlock only broken by a Space switch cancelling its tracking loop).
    /// Setting the timeout on the system-wide element bounds all of this process's
    /// AX messaging; resolution also carries a total deadline (see callers).
    private static let boundedMessaging: Void = {
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }()

    /// Cheap, non-blocking pre-check via the window server (never talks to the
    /// target app): the topmost on-screen window under `point`, front-to-back.
    /// Lets the tap skip menubar items, overlays and HUD panels with zero AX
    /// traffic — those clicks pass straight through to their owners.
    static func topWindowInfo(at point: CGPoint) -> (pid: pid_t, layer: Int, bundleID: String?)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let display = displayBounds(containing: point)
        for w in list {   // front-to-back
            guard let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  rect.contains(point),
                  let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = w[kCGWindowLayer as String] as? Int else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            // Display-covering windows at non-normal levels are passive
            // click-through overlays (Magnet keeps a resident full-screen
            // snap-preview window at status level 25; notch/annotation
            // utilities do the like). The window server hit-tests past them,
            // so this gate must look past them too or every click on screen
            // gets misattributed to the overlay.
            if layer != 0, layer != 3, let display,
               rect.contains(display.insetBy(dx: 1, dy: 1)) { continue }
            let pid = pid_t(pidNum.int32Value)
            return (pid, layer, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        }
        return nil
    }

    private static func displayBounds(containing p: CGPoint) -> CGRect? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 else { return nil }
        return CGDisplayBounds(display)
    }

    /// Hit-test the AX hierarchy at a point (CG global coords) and resolve the
    /// containing window plus its frame and owner. Gives up (nil) once `deadline`
    /// passes — the caller then passes the event through rather than holding it.
    static func window(at point: CGPoint, deadline: Date) -> TargetWindow? {
        _ = boundedMessaging
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitRef) == .success,
              let hit = hitRef, Date() < deadline else { return nil }

        guard let window = containingWindow(of: hit, deadline: deadline),
              let frame = frame(of: window), Date() < deadline else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        return TargetWindow(element: window, pid: pid, bundleID: bundleID, frame: frame)
    }

    private static func containingWindow(of element: AXUIElement, deadline: Date) -> AXUIElement? {
        if role(of: element) == kAXWindowRole { return element }

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }

        // Fallback: walk up the parent chain looking for a window role.
        var current = element
        for _ in 0..<25 where Date() < deadline {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
            let parent = parentRef as! AXUIElement
            if role(of: parent) == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    /// The universally-safe grab spot: the midpoint of the gap between the
    /// close (red) and minimize (yellow) traffic-light buttons, read from the
    /// window's own AX button geometry — window chrome in effectively every
    /// app, and never overlapped by tab strips or toolbar controls. Returns
    /// nil when the window doesn't expose plausible button frames.
    static func trafficLightGapPoint(of window: AXUIElement, frame windowFrame: CGRect) -> CGPoint? {
        guard let close = buttonFrame(of: window, attribute: kAXCloseButtonAttribute as String),
              let minimize = buttonFrame(of: window, attribute: kAXMinimizeButtonAttribute as String)
        else { return nil }
        let gapLeft = close.maxX
        let gapRight = minimize.minX
        guard gapRight - gapLeft >= 4,                      // a real gap to aim at
              close.width > 2, close.height > 2,           // buttons actually laid out
              close.minY >= windowFrame.minY - 1,          // in this window's top region
              close.midY - windowFrame.minY < 80,
              gapLeft > windowFrame.minX,
              gapRight < windowFrame.minX + 200
        else { return nil }
        return CGPoint(x: (gapLeft + gapRight) / 2, y: close.midY)
    }

    private static func buttonFrame(of window: AXUIElement, attribute: String) -> CGRect? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return frame(of: (ref as! AXUIElement))
    }

    /// True if the point hit-tests to empty draggable chrome of `window`: the
    /// window itself, or a non-interactive container (title bar background,
    /// tab-bar filler, toolbar background — all of which drag the window).
    /// Anything on the path from the hit element up to the window that has a
    /// control-like role or supports AXPress — a tab, traffic-light button,
    /// toolbar control, text field — makes the point unsafe to grab: a click
    /// there would activate the control (or tear off the tab) instead of
    /// starting a window drag.
    static func isSafeDragPoint(_ point: CGPoint, in window: AXUIElement,
                                deadline: Date = Date().addingTimeInterval(0.3)) -> Bool {
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitRef) == .success,
              let hit = hitRef else { return false }
        if CFEqual(hit, window) { return true }
        guard let hitWindow = containingWindow(of: hit, deadline: deadline),
              CFEqual(hitWindow, window) else { return false }

        var current: AXUIElement? = hit
        for _ in 0..<8 {
            guard let el = current else { return false }
            if CFEqual(el, window) { return true }
            if let r = role(of: el), controlRoles.contains(r) { return false }
            var actionsRef: CFArray?
            if AXUIElementCopyActionNames(el, &actionsRef) == .success,
               let actions = actionsRef as? [String],
               actions.contains(kAXPressAction) {
                return false
            }
            current = parent(of: el)
        }
        return false
    }

    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
        kAXSliderRole, kAXScrollBarRole, kAXDisclosureTriangleRole,
    ]

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Restore a window's frame (cancelled drags): position first, then size,
    /// so a snap that committed on the way out is fully undone.
    static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var origin = frame.origin
        var size = frame.size
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    /// Raise the window and activate its app. Dispatched to the main thread:
    /// never do AX raises synchronously from the tap callback.
    static func raise(_ target: TargetWindow) {
        let element = target.element
        let pid = target.pid
        DispatchQueue.main.async {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }
}
