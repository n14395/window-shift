import AppKit
import CoreGraphics

/// Diagnostic: counts the mouse-downs actually DELIVERED to the panel, so a
/// gesture can prove whether its synthetic down landed here or fell through.
private final class CountingPanel: NSPanel {
    var downsSeen = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { downsSeen += 1 }
        super.sendEvent(event)
    }
}

/// A transparent panel parked around the grab point while a move gesture is
/// in flight.
///
/// The SkyLight drag binds to a mouse button that is already down, so the
/// gesture has to put one down — but the user grabbed the middle of the
/// target app's content, and a click there would select text, follow a link
/// or start dragging the app's items around. The synthetic mouse-down lands
/// on this panel instead. Delivery of the rest of the gesture follows the
/// button's owner, so once the down lands here, the drags and the mouse-up
/// come to us too and the app underneath never sees any of it.
///
/// Hard-won properties, each measured rather than assumed:
///
///  - **It must be small.** The obvious hardening — cover the whole desktop
///    so nothing can ever be under the cursor — does not work: the window
///    server deliberately hit-tests PAST display-covering windows at high
///    levels (that is how Magnet's resident full-screen overlay stays
///    click-through), so a desktop-sized panel absorbs nothing at any alpha.
///  - **It is never ordered in or out.** It goes on screen once and stays
///    there for the process's life, click-through between gestures. Showing
///    a window is not cheap: `_setVisible:` takes a CoreAnimation fence
///    round-trip to the window server, which is busiest during exactly what
///    this app does — a drag, a tile preview, a snap. Sampling caught that
///    call blocking the main thread for hundreds of milliseconds, and since
///    the panel has to be up before the synthetic down can be emitted, the
///    gesture was abandoned outright when it overran. Arming instead flips
///    `ignoresMouseEvents` and moves the panel, neither of which fences.
///  - **The down must wait for the server.** Even so, arming is main-thread
///    work and the down is emitted from the event tap, so it can still be
///    early. A down emitted before the panel is really there falls through
///    to the target app, which then owns the whole gesture at the grab point
///    — dragging its own content around. `armedFrame` therefore returns the
///    panel's position *as the window server reports it*, and the caller
///    swallows drag events until it does, then aims the down inside it.
///  - **It must be a NON-ACTIVATING panel.** A plain window also absorbs the
///    press, but its click makes WindowShift frontmost — and snap-on-drag
///    apps (Magnet) attribute a drag to the frontmost app, so they ignore
///    the whole drag. `.nonactivatingPanel` leaves the target app frontmost.
///  - **It stays visible to window lists** (no `sharingType = .none`): the
///    readiness check reads the panel's own window-list entry, which
///    sharing-none windows do not get. The panel draws nothing visible, so
///    appearing in a screenshot is moot.
///
/// `arm`/`move`/`disarm` are safe to call from the event-tap thread — the
/// AppKit work hops to the main thread — and `armedFrame` (also tap-thread
/// safe) is the gate the synthetic mouse-down waits behind.
final class GrabOverlay {
    /// 40 px, and deliberately no larger: snap-on-drag apps attribute a drag
    /// to the window at the mouse-down point, SKIPPING implausibly tiny
    /// windows — measured against Magnet: at 40 px the overlay is ignored and
    /// the target beneath is attributed (snap works); at 60 px the overlay
    /// itself is attributed and, since it never moves, nothing ever snaps.
    /// The down is kept inside the panel by CHASING the hand while the server
    /// catches up (`move(toCG:)`), not by making the panel bigger.
    static let size: CGFloat = 40

    private var panel: CountingPanel?
    private let lock = NSLock()
    private var armed = false
    private var windowID: CGWindowID = 0
    private var lastCG = CGPoint.zero

    /// Put the panel on screen for good. Call once, from the main thread, at
    /// launch: everything after this is a property flip, never an order-in.
    func prepare() {
        let panel = panel ?? makePanel()
        panel.setFrameOrigin(NSPoint(x: -Self.size * 4, y: -Self.size * 4))
        panel.orderFrontRegardless()
        lock.lock()
        windowID = CGWindowID(panel.windowNumber)
        lock.unlock()
    }

    /// The panel's frame in CG (top-left origin) coordinates **as the window
    /// server reports it**, or nil if the server has not yet put the panel
    /// within reach of `point`.
    ///
    /// Both halves matter. Asking the server rather than trusting the last
    /// commanded position is what keeps the down on the panel at all; asking
    /// whether it has arrived NEAR THE HAND is what stops a down being aimed
    /// at wherever the panel used to be, which lands a click in some far
    /// corner of the screen and wrecks the gesture.
    func armedFrame(near point: CGPoint, tolerance: CGFloat) -> CGRect? {
        lock.lock()
        let ready = armed
        let wid = windowID
        lock.unlock()
        guard ready, wid != 0 else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid)
                as? [[String: Any]],
              let entry = list.first,
              (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        // The down is clamped into this frame, so the hand has to be close
        // enough that clamping doesn't amount to a jump: a mouse-down far
        // from the following drags is the discontinuity snap-on-drag apps
        // discard, and a big one is a stray click somewhere else entirely.
        // The panel chases the hand and can only ever be about one event
        // behind it, so the caller scales the tolerance to the hand's speed —
        // a flick covering 100 px per event is still one event behind, and
        // insisting on 40 px there would strand the gesture forever.
        return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) ? frame : nil
    }

    /// Where the panel was last commanded to be (CG coords).
    var lastShownCG: CGPoint {
        lock.lock()
        defer { lock.unlock() }
        return lastCG
    }

    /// Make the panel interactive and centre it on a CG (top-left origin)
    /// point, for a gesture that is starting.
    func arm(atCG point: CGPoint) {
        lock.lock()
        armed = false
        lastCG = point
        lock.unlock()
        DispatchQueue.main.async { [self] in
            guard let panel, let origin = flipped(point) else { return }
            panel.ignoresMouseEvents = false
            panel.setFrameOrigin(origin)
            lock.lock()
            armed = true
            windowID = CGWindowID(panel.windowNumber)
            lock.unlock()
        }
    }

    /// Chase the hand while the server catches up. Keeps the armed state.
    func move(toCG point: CGPoint) {
        lock.lock()
        lastCG = point
        lock.unlock()
        DispatchQueue.main.async { [self] in
            guard let panel, let origin = flipped(point) else { return }
            panel.setFrameOrigin(origin)
        }
    }

    /// Gesture over: click-through again. The panel stays on screen and stays
    /// where it is — see the type comment. Moving it here would only be one
    /// more main-thread round trip for a window nothing can click.
    func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
        DispatchQueue.main.async { [self] in
            panel?.ignoresMouseEvents = true
        }
    }

    /// MAIN THREAD ONLY (diagnostics).
    var downsSeen: Int { panel?.downsSeen ?? 0 }

    /// CG (top-left, primary-relative) centre point → AppKit frame origin.
    /// The flip uses the PRIMARY screen's height and AppKit's global
    /// coordinates, which is correct for displays at negative coordinates too
    /// (verified on a three-display arrangement).
    private func flipped(_ point: CGPoint) -> NSPoint? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSPoint(x: point.x - Self.size / 2,
                       y: primaryHeight - point.y - Self.size / 2)
    }

    private func makePanel() -> CountingPanel {
        let panel = CountingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Above EVERYTHING. `.statusBar` (25) is not enough: Magnet parks a
        // resident full-display overlay at exactly that level, and when it wins
        // the tie the synthetic down lands on Magnet's window instead of ours.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true   // armed per gesture; see arm(atCG:)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // No fade on order-in: it would run an NSAnimation on every gesture
        // and fence against the window server for no visible benefit — the
        // panel is transparent.
        panel.animationBehavior = .none
        // The gesture can start on any Space, and the panel must not follow a
        // Space switch or be offered to the window cycler.
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        panel.setAccessibilityElement(false)
        panel.contentView?.setAccessibilityElement(false)
        self.panel = panel
        return panel
    }
}
