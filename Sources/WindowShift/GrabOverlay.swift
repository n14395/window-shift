// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
///    Size buys nothing towards snapping interop in either direction: every
///    size from 4 px up is found by a snapper's hit test, and what actually
///    decides whether snapping survives is where our tap sits in the chain
///    (see `EventTap`). Small is only so the parked panel is not a dead spot
///    on the user's desktop.
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
/// Between gestures the panel is parked with a single pixel showing in the
/// bottom-left corner of the primary display, never ordered out: it is always
/// able to catch a click (see `makePanel`), and ordering it out and back in is
/// what used to cost a main-thread stall of up to a second.
final class GrabOverlay {
    /// See the type comment.
    static let size: CGFloat = 40

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
            // larger would be a dead spot in the user's desktop. The panel is
            // BORN here (see `makePanel`), so this is where it already is.
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
        guard wid != 0, let park else { return }
        SkyLight.move(window: wid, toTopLeft: park)
    }

    /// Gesture over: back to the parking spot.
    func disarm() { park() }

    /// The parking spot in CG (top-left origin) coordinates, resolved in
    /// `prepare` once the screen geometry is known. Nil until then, and a nil
    /// park moves nothing: parking to a default (0, 0) would strand the panel
    /// in the TOP-left corner, which is a live dead spot rather than a corner
    /// the panel only has one pixel in.
    ///
    /// Somewhere ON screen — the panel has to stay registered with the window
    /// server, and parking it off every display drops it out of the window
    /// list for several moves (measured), which is the latency this whole
    /// design exists to avoid.
    private var parkOrigin: CGPoint?

    /// MAIN THREAD ONLY. Diagnostic: how many clicks the panel has caught.
    var downsSeen: Int { panel?.downsSeen ?? 0 }

    /// The panel is always able to catch a click; it is parked out of the way
    /// rather than switched off, so there is no state to be out of sync.
    var isArmed: Bool { true }

    private func makePanel() -> CountingPanel {
        // BORN at the parking spot, not at the origin and moved there.
        // `prepare` orders the panel front and parks it in one run-loop turn,
        // but AppKit commits the window to the server at the END of that turn,
        // with the frame the panel was CREATED with — so the park landed on a
        // window the server did not have yet and was then undone. Measured: the
        // panel sat at its birth position for the whole session, a 40×40
        // click-catching square in the bottom-left of the primary display.
        // Birth spot == park spot removes the race, and also survives any later
        // AppKit re-commit (a screen-parameter change re-sends the frame AppKit
        // has cached, which the SkyLight moves never update).
        //
        // AppKit's origin is the bottom-left of the primary display and its y
        // runs up, so this is the same point as `parkOrigin` in CG coordinates,
        // with one pixel of the panel on screen. AppKit does not constrain a
        // borderless panel born off-screen (measured).
        let park = NSRect(x: -(Self.size - 1), y: -(Self.size - 1),
                          width: Self.size, height: Self.size)
        let panel = CountingPanel(
            contentRect: park,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
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
        // Above EVERYTHING, and set AFTER `isFloatingPanel` — that property
        // resets the level to `.floating` (3), so assigning the level first
        // threw the assignment away. Measured: the panel ran at layer 3, below
        // every level-25 overlay on screen, and caught its press only because
        // the overlays up there happen to be click-through. `.statusBar` (25)
        // is where Magnet parks a resident full-display overlay; a
        // click-catching window at that level would take the synthetic down
        // instead of us. This level also puts the panel inside the band
        // `WindowResolver` ignores, so a gesture can never target it.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
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
