import AppKit

/// A tiny transparent panel parked under the cursor while a move gesture is in
/// flight.
///
/// The SkyLight drag binds to a mouse button that is already down, so the
/// gesture has to put one down — but the user grabbed the middle of the target
/// app's content, and a click there would select text, follow a link or start
/// a drag-and-drop inside their app. So the synthetic mouse-down lands on this
/// panel instead, and the app underneath sees nothing.
///
/// Three properties are load-bearing, and all three were measured rather than
/// assumed:
///
///  - **It must be a NON-ACTIVATING panel.** A plain window also absorbs the
///    press, but its click makes WindowShift frontmost — and snap-on-drag
///    apps (Magnet) attribute a drag to the frontmost app, so they ignore the
///    whole drag. `.nonactivatingPanel` leaves the target app frontmost and
///    Magnet snaps. (An earlier conclusion that the panel broke the drag was
///    an artifact of the then-missing Screen Recording grant, without which
///    NO variant moved anything.)
///  - **A `.clear` background is enough to block the click.** A fully
///    transparent window is still hit-tested, so no near-invisible fill is
///    needed to stop the event reaching the app below.
///  - **Our own content view never receives `mouseDown`** (the click is
///    consumed at the window level, even with `acceptsFirstMouse`). That is
///    fine: all the mechanism needs is for the press to exist in the window
///    server and for the app underneath to be unaware of it.
///
/// `show`/`hide` are safe to call from the event-tap thread — the AppKit work
/// hops to the main thread — and `isReady` lets the tap wait for the panel to
/// actually be on screen before aiming a mouse-down at it.
final class GrabOverlay {
    private static let size: CGFloat = 24

    private var panel: NSPanel?
    private let lock = NSLock()
    private var shown = false

    /// Whether the panel is on screen and can be safely aimed at. False until
    /// the main thread has ordered it front, so a busy main thread delays the
    /// synthetic mouse-down rather than letting it fall through to the app.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shown
    }

    /// Place the panel centred on a CG (top-left origin) point and show it.
    func show(atCG point: CGPoint) {
        DispatchQueue.main.async { [self] in
            // The flip uses the PRIMARY screen's height and AppKit's global
            // coordinates, which is correct for displays at negative
            // coordinates too (verified on a three-display arrangement).
            guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
            let panel = panel ?? makePanel()
            panel.setFrameOrigin(NSPoint(x: point.x - Self.size / 2,
                                         y: primaryHeight - point.y - Self.size / 2))
            panel.orderFrontRegardless()
            lock.lock()
            shown = true
            lock.unlock()
        }
    }

    func hide() {
        lock.lock()
        shown = false
        lock.unlock()
        DispatchQueue.main.async { [self] in panel?.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Above EVERYTHING. `.statusBar` (25) is not enough: Magnet parks a
        // resident full-display overlay at exactly that level, and when it wins
        // the tie the synthetic down lands on Magnet's window instead of ours,
        // so the drag binds to nothing and the window silently refuses to move.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false  // must NOT be click-through
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // The gesture can start on any Space, and the panel must not follow a
        // Space switch or be offered to the window cycler.
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        panel.sharingType = .none         // stays out of screen shares and recordings
        panel.setAccessibilityElement(false)
        panel.contentView?.setAccessibilityElement(false)
        self.panel = panel
        return panel
    }
}
