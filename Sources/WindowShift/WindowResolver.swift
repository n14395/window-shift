// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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

/// One on-screen window as the window server sees it. Cheap to gather in bulk
/// and pure arithmetic to query, so a gesture takes ONE scan and reuses it.
struct WindowSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
}

enum WindowResolver {
    private static let systemWide = AXUIElementCreateSystemWide()

    /// Window-server artifacts (drag shadows, tiling-zone previews) sit just
    /// below the maximum window level — measured at maximumWindow − 1. Nothing
    /// an app can legitimately create lives anywhere near here, so a small band
    /// below the ceiling is a safe thing to ignore wholesale.
    private static let artifactLevelFloor = Int(CGWindowLevelForKey(.maximumWindow)) - 8

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

    /// Every on-screen window, front-to-back, via the window server (never
    /// talks to the target app). One scan per gesture, reused for the
    /// topmost-window gate and for magnetic-snap neighbours.
    static func onScreenWindows() -> [WindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [WindowSnapshot] = []
        out.reserveCapacity(list.count)
        for w in list {   // front-to-back
            guard let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let number = w[kCGWindowNumber as String] as? NSNumber else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            out.append(WindowSnapshot(id: CGWindowID(number.uint32Value),
                                      pid: pid_t(pidNum.int32Value),
                                      layer: layer, bounds: rect))
        }
        return out
    }

    /// The topmost window under `point` in a snapshot. Lets the tap skip
    /// menubar items, overlays and HUD panels with zero AX traffic — those
    /// clicks pass straight through to their owners.
    static func topWindow(at point: CGPoint, in windows: [WindowSnapshot]) -> WindowSnapshot? {
        let display = displayBounds(containing: point)
        // Half-point outset: a point exactly on a window's edge belongs to it.
        for w in windows where w.bounds.insetBy(dx: -0.5, dy: -0.5).contains(point) {
            // Windows at non-normal levels that blanket a display are passive
            // click-through overlays (Magnet keeps a resident full-screen
            // snap-preview window at status level 25; notch/annotation
            // utilities do the like). The window server hit-tests past them,
            // so this gate must look past them too or every click on screen
            // gets misattributed to the overlay.
            //
            // COVERAGE, not exact containment. Demanding that the overlay
            // contain the whole display reads as the tighter test and silently
            // breaks: Osaurus keeps a level-25 overlay over the display MINUS
            // the menu bar, which missed that test by those 40 px, was read as
            // a real panel, and passed every gesture on that display through.
            // Magnet's overlay only ever passed by being exactly display-sized.
            //
            // There is no exact test to reach for instead. Whether a window is
            // click-through is a property the window server will not report:
            // SLSSetWindowEventShape has no getter; SLSGetWindowEventMask reads
            // the same for a click-through overlay as for a real panel; and
            // SLSFindWindowByGeometry hit-tests PIXELS, so it looks straight
            // past an invisible window that does catch clicks (all measured).
            // Coverage is the honest proxy, and it fails towards passing the
            // click through, which is the safe direction.
            if w.layer != 0, w.layer != 3, let display, blankets(display, w.bounds) { continue }
            // Window-server artifacts — drag shadows, tiling-zone previews (which
            // appear whenever Option is held, so any combo containing it sees
            // them) — sit at the maximum window level and linger for a moment
            // after the drag that spawned them. They are not click targets, and
            // treating one as the topmost window declines the next gesture.
            if w.layer >= Self.artifactLevelFloor { continue }
            return w
        }
        return nil
    }

    /// Whether `rect` covers essentially all of `display`. The threshold has to
    /// clear an overlay that dodges the menu bar (~97% of a display) and one
    /// that dodges the menu bar and a tall Dock (~88%), while staying far above
    /// anything a real panel occupies — Osaurus's own level-25 panel is 14%.
    private static func blankets(_ display: CGRect, _ rect: CGRect) -> Bool {
        let area = display.width * display.height
        guard area > 0 else { return false }
        let covered = display.intersection(rect)
        guard !covered.isNull else { return false }
        return covered.width * covered.height >= 0.8 * area
    }

    static func displayBounds(containing p: CGPoint) -> CGRect? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 else { return nil }
        return CGDisplayBounds(display)
    }

    /// Whether `p` lies on SOME active display. The desktop is a union of
    /// display rectangles, not one rectangle: displays at different vertical
    /// offsets leave uncovered "staircase" gaps INSIDE the bounding box, and
    /// the window server hit-tests nothing there. A synthetic mouse-down at
    /// such a point starts no drag session — so every grab point must pass
    /// this test. (Testing the sign of a coordinate is NOT equivalent: a
    /// display left of the main one has legitimately negative x.)
    static func onAnyDisplay(_ p: CGPoint) -> Bool {
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 0, nil, &count) == .success && count > 0
    }

    /// The window server's current bounds for one window, by ID.
    static func liveBounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bd = list.first?[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bd as CFDictionary)
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

    @discardableResult
    static func setOrigin(_ origin: CGPoint, of window: AXUIElement) -> Bool {
        var o = origin
        guard let value = AXValueCreate(.cgPoint, &o) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
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
