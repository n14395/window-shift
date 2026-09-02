import AppKit
import CoreGraphics

/// Counts the mouse-downs actually DELIVERED here, so a gesture can prove
/// whether its synthetic click landed on the panel or fell through into the
/// user's document. (Temporary; failure diagnosis only.)
private final class CountingPanel: NSPanel {
    var downsSeen = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { downsSeen += 1 }
        super.sendEvent(event)
    }
}

/// A transparent panel placed under the cursor for the duration of a move
/// gesture, to catch the synthetic mouse-down.
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
///    Snap-on-drag apps also attribute a drag to the window at the mouse-down
///    point while SKIPPING implausibly tiny ones: at 40 px the overlay is
///    ignored and the target beneath is attributed (snapping works); at 60 px
///    the overlay is attributed and, since it never moves, nothing ever snaps.
///  - **It is placed by the window server, from the event-tap thread.**
///    `SLSMoveWindow` on our own window takes effect synchronously, so by the
///    time the tap emits the mouse-down the panel is provably under it. The
///    AppKit route cannot offer that: it has to hop to the main thread, which
///    the window server can stall for hundreds of milliseconds during exactly
///    a drag, a tile preview or a snap. Gestures then either fired the click
///    before the panel arrived — falling through into the user's document,
///    selecting text and dragging Finder items — or waited for it and were
///    abandoned outright. Both were the "works about half the time" bug.
///  - **The move is its own confirmation.** `place` returns the frame it just
///    set and the caller aims the down inside that. Reading the position back
///    out of the window list to "verify" is worse than useless: that list is
///    the server's published state and lags its real state exactly when the
///    server is busy, so the check fails on a move that in fact succeeded.
///  - **It must be a NON-ACTIVATING panel.** A plain window also absorbs the
///    press, but its click makes WindowShift frontmost — and snap-on-drag
///    apps attribute a drag to the frontmost app, so they ignore the whole
///    drag. `.nonactivatingPanel` leaves the target app frontmost.
///  - **It stays visible to window lists** (no `sharingType = .none`), so it
///    keeps a window-server identity to be moved by. The panel draws nothing
///    visible, so appearing in a screenshot is moot.
///
/// Between gestures the panel stays on screen but click-through, so it never
/// swallows a real click; ordering it out and back in is what used to cost
/// the main-thread stall, so it is never ordered out at all.
final class GrabOverlay {
    /// See the type comment. Overridable for A/B testing which sizes a
    /// snap-on-drag app ignores; 0 means "no panel at all", i.e. let the click
    /// fall through to the app, which is the control case.
    ///   defaults write dev.nwf.WindowShift debugOverlaySize -float 4
    static let size: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "debugOverlaySize") as? Double
        return CGFloat(v ?? 40)
    }()

    private var panel: CountingPanel?
    private let lock = NSLock()
    private var windowID: CGWindowID = 0

    /// Put the panel on screen for good. Call once, from the main thread, at
    /// launch. It starts click-through; `arm` makes it live for a gesture.
    func prepare() {
        let panel = panel ?? makePanel()
        panel.orderFrontRegardless()
        lock.lock()
        windowID = CGWindowID(panel.windowNumber)
        if let primaryHeight = NSScreen.screens.first?.frame.height {
            // Parked with ONE pixel on screen, at the bottom-left corner.
            // On screen because a window parked off every display drops out
            // of the window list for several moves (measured); one pixel
            // because the panel is always able to catch a click, so anything
            // larger would be a dead spot in the user's desktop.
            parkOrigin = CGPoint(x: -(Self.size - 1), y: primaryHeight - 1)
        }
        lock.unlock()
        park()
    }

    /// Put the panel under `point` (a CG, top-left-origin location) and return
    /// the frame it now occupies, or nil if it is not armed yet. Safe to call
    /// from the event-tap thread, and takes effect before it returns.
    func place(atCG point: CGPoint) -> CGRect? {
        lock.lock()
        let wid = windowID
        lock.unlock()
        guard wid != 0 else { return nil }
        // Size 0: deliberately no catcher — the click falls through to the
        // app. Diagnostic control case only.
        if Self.size == 0 { return CGRect(origin: point, size: .zero) }

        let origin = CGPoint(x: (point.x - Self.size / 2).rounded(),
                             y: (point.y - Self.size / 2).rounded())
        guard SkyLight.move(window: wid, toTopLeft: origin) else { return nil }
        // The move IS the confirmation. Reading the position back out of
        // CGWindowList to double-check looks safer and is actively harmful:
        // that list is the server's PUBLISHED state and lags its real state
        // while the server is busy — which is during a drag, a tile preview,
        // a snap. The read-back then reports the old position, the gesture
        // decides the panel isn't ready, swallows every event waiting for it,
        // and is abandoned. Nothing moves and nothing is clicked, which is
        // half of "it works about half the time".
        return CGRect(origin: origin, size: CGSize(width: Self.size, height: Self.size))
    }

    /// Get the panel out from under the cursor RIGHT NOW, server-side. Called
    /// once the press has been caught and the drag is bound: the rest of the
    /// gesture still belongs to the panel (delivery follows the button owner),
    /// but anything hit-testing the pointer from here on — a snapping app
    /// working out which window is being dragged — finds the target window.
    func vacate() { park() }

    private func park() {
        lock.lock()
        let wid = windowID
        let park = parkOrigin
        lock.unlock()
        if wid != 0 { SkyLight.move(window: wid, toTopLeft: park) }
    }

    /// Gesture over: back to the parking spot.
    func disarm() { park() }

    /// Somewhere on screen — the panel has to stay registered with the window
    /// server, and parking it off every display drops it out of the window
    /// list for several moves (measured), which is the latency this whole
    /// design exists to avoid. The bottom-left corner of the primary display
    /// is as harmless as anywhere: the panel is click-through whenever it is
    /// parked here, and it is moved here BEFORE the flip, never after.
    private var parkOrigin = CGPoint(x: 0, y: 0)

    /// MAIN THREAD ONLY. Diagnostic: how many clicks the panel has caught.
    var downsSeen: Int { panel?.downsSeen ?? 0 }

    /// The panel is always able to catch a click; it is parked out of the way
    /// rather than switched off, so there is no state to be out of sync.
    var isArmed: Bool { true }

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
        // ALWAYS able to catch a click. Toggling this per gesture means an
        // AppKit property change on the main thread, and the window server can
        // apply it later than the tap fires the click — which lands the click
        // in the user's document. Parking the panel is instant and needs no
        // main thread, so position is the only state that matters.
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // No fade on order-in: it would run an NSAnimation and fence against
        // the window server for no visible benefit — the panel is transparent.
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
