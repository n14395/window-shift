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
///  - **The down must wait for the server.** `orderFront` returning does not
///    make the panel hit-testable; a mouse-down emitted in that gap falls
///    through to the target app, which then owns the entire gesture at the
///    grab point — dragging its own content around. `isReady` therefore
///    reports true only once the WINDOW SERVER says the panel is on screen,
///    and the caller swallows drag events until then.
///  - **It must be a NON-ACTIVATING panel.** A plain window also absorbs the
///    press, but its click makes WindowShift frontmost — and snap-on-drag
///    apps (Magnet) attribute a drag to the frontmost app, so they ignore
///    the whole drag. `.nonactivatingPanel` leaves the target app frontmost.
///  - **It stays visible to window lists** (no `sharingType = .none`): the
///    server-side readiness check reads the panel's own window-list entry,
///    which sharing-none windows do not get. The panel draws nothing
///    visible, so appearing in a screenshot is moot.
///
/// `show`/`hide` are safe to call from the event-tap thread — the AppKit
/// work hops to the main thread — and `isReady` (also tap-thread-safe) is
/// the gate the synthetic mouse-down waits behind.
final class GrabOverlay {
    /// 40 px, and deliberately no larger: snap-on-drag apps attribute a drag
    /// to the window at the mouse-down point, SKIPPING implausibly tiny
    /// windows — measured against Magnet: at 40 px the overlay is ignored and
    /// the target beneath is attributed (snap works); at 60 px the overlay
    /// itself is attributed and, since it never moves, nothing ever snaps.
    /// The down is kept inside the panel by CHASING the hand while readiness
    /// is awaited (`move(toCG:)`), not by making the panel bigger.
    static let size: CGFloat = 40

    private var panel: CountingPanel?
    private let lock = NSLock()
    private var shown = false
    private var windowID: CGWindowID = 0
    private var serverConfirmed = false
    private var lastCG = CGPoint.zero

    /// True once the panel can safely be aimed at: ordered front by the main
    /// thread AND registered on screen by the window server. The second half
    /// is load-bearing — see the type comment.
    var isReady: Bool {
        lock.lock()
        let ordered = shown
        let confirmed = serverConfirmed
        let wid = windowID
        lock.unlock()
        guard ordered, wid != 0 else { return false }
        if confirmed { return true }

        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid)
                as? [[String: Any]],
              let entry = list.first,
              (entry[kCGWindowIsOnscreen as String] as? Bool) == true else { return false }
        lock.lock()
        serverConfirmed = true
        lock.unlock()
        return true
    }

    /// Where the panel was last commanded to be (CG coords). The synthetic
    /// down must be clamped into a small box around this point.
    var lastShownCG: CGPoint {
        lock.lock()
        defer { lock.unlock() }
        return lastCG
    }

    /// Reposition the already-shown panel (does NOT reset the server
    /// confirmation — moving an on-screen window keeps it hit-testable).
    func move(toCG point: CGPoint) {
        lock.lock()
        lastCG = point
        lock.unlock()
        DispatchQueue.main.async { [self] in
            guard let panel, let primaryHeight = NSScreen.screens.first?.frame.height else { return }
            panel.setFrameOrigin(NSPoint(x: point.x - Self.size / 2,
                                         y: primaryHeight - point.y - Self.size / 2))
        }
    }

    /// Place the panel centred on a CG (top-left origin) point and show it.
    func show(atCG point: CGPoint) {
        lock.lock()
        serverConfirmed = false
        lastCG = point
        showRequestedAt = Date()
        shownAt = nil
        lock.unlock()
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
            windowID = CGWindowID(panel.windowNumber)
            shownAt = Date()
            lock.unlock()
        }
    }

    /// Diagnostics: why `isReady` is (not) true, safe from any thread.
    var debugState: String {
        lock.lock()
        let s = shown, c = serverConfirmed, w = windowID
        let requested = showRequestedAt, ran = shownAt
        lock.unlock()
        let mainLag = ran.map { Int($0.timeIntervalSince(requested) * 1000) } ?? -1
        var onscreen = "?"
        if w != 0 {
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], w) as? [[String: Any]]
            onscreen = "\((list?.first?[kCGWindowIsOnscreen as String] as? Bool).map(String.init) ?? "absent")"
        }
        return "shown=\(s) wid=\(w) confirmed=\(c) onscreen=\(onscreen) mainLagMs=\(mainLag)"
    }
    private var showRequestedAt = Date.distantPast
    private var shownAt: Date?

    /// MAIN THREAD ONLY (diagnostics).
    var downsSeen: Int { panel?.downsSeen ?? 0 }
    /// MAIN THREAD ONLY (diagnostics).
    var actualFrame: NSRect { panel?.frame ?? .zero }

    func hide() {
        lock.lock()
        shown = false
        serverConfirmed = false
        lock.unlock()
        DispatchQueue.main.async { [self] in panel?.orderOut(nil) }
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
        panel.ignoresMouseEvents = false  // must NOT be click-through
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // The gesture can start on any Space, and the panel must not follow a
        // Space switch or be offered to the window cycler.
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        panel.setAccessibilityElement(false)
        panel.contentView?.setAccessibilityElement(false)
        self.panel = panel
        return panel
    }
}
