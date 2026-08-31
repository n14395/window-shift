import AppKit
import CoreGraphics

/// The core state machine. All mouse events from the tap flow through handle().
///
/// **Move.** On modifier+mouseDown we swallow the click and park an invisible,
/// non-activating panel under the cursor (see `GrabOverlay`). The FIRST
/// subsequent drag event is rewritten in flight into a `leftMouseDown` on that
/// panel — so the target app never sees a click — and the SECOND hands the
/// window server the target's window ID via `SLSDragWindowRelativeToMouse`,
/// which binds the live button press to a genuine server-side drag of that
/// window. From then on the window moves itself, server-side, tracking our
/// event stream 1:1 with no per-frame IPC. Because the session is real,
/// native edge tiling, Option-drag tiling and Magnet/Rectangle-style
/// snap-on-drag all engage exactly as for a manual title-bar drag.
///
/// The point of naming the window by ID is that nothing has to be *clickable*:
/// a window whose title bar is full of tabs and toolbar controls, or parked
/// off-screen entirely, drags exactly as well as any other. The grabbed point
/// stays under the cursor for the whole drag, and the cursor never warps.
///
/// **Resize** keeps the older mechanism: the first right-drag is rewritten
/// into a `leftMouseDown` on the window's resize border at the nearest
/// reachable corner, which starts a native resize session. There is no
/// SkyLight interactive-resize primitive to replace it with, and resize needs
/// no tiling interop.
final class DragController {

    private struct Grab {
        let isResize: Bool
        let appName: String
        /// The window and its pre-drag frame: for Esc-restore, for the
        /// after-the-fact outcome check, and for the SkyLight bind offset.
        let element: AXUIElement
        /// Owner of the target window, re-activated when the drag binds.
        let pid: pid_t
        let originalFrame: CGRect
        /// Window-server ID of the target. Required for a move — it is what
        /// names the drag target — so a move is declined without one. A
        /// resize tolerates 0 (it only weakens an occlusion check).
        let windowID: CGWindowID
        /// Where the synthetic mouse-down goes: the cursor itself for a move
        /// (which is where the overlay is), the resize corner for a resize.
        let point: CGPoint
        /// Resize only: `point` − cursor, re-applied to every event so the
        /// grabbed corner tracks the hand. Zero for moves — the server keeps
        /// the grabbed point under the cursor by itself.
        let offset: CGVector
        /// Move only: cursor − window origin at mouse-down, handed to
        /// `SkyLight.beginDrag`. This is the real grip, so the point the user
        /// grabbed stays under the cursor even though the synthetic press
        /// lands elsewhere.
        let dragOffset: CGPoint
        /// The physical cursor at mouse-down. For a move the synthetic press
        /// goes to the title bar instead, so travel and magnetic snapping have
        /// to measure from here, not from `point`.
        let cursorAtGrab: CGPoint
        /// Neighbour frames for magnetic snapping, snapshotted at grab time.
        /// Empty when the feature is off, or for a resize.
        let neighbors: [CGRect]
        /// Set when the grab wasn't the preferred one — appended to the
        /// menu's diagnostics line.
        let note: String?
        /// Move only: no drag session is possible, so drive the window with
        /// Accessibility writes instead. No tiling, no snapping.
        var degraded: Bool
        /// When the button went down, to bound the wait for the overlay.
        let startedAt: Date
        /// When the synthetic mouse-down was emitted, so the bind can wait for
        /// it to be fully processed.
        var downAt: Date?
        /// Move only: has the SkyLight drag been bound yet? The bind needs a
        /// button-down that has actually LANDED, so it happens one event
        /// after the synthetic down.
        var bound = false
        /// Set once the bind has been shown to actually move the window.
        var verified = false
        /// When the drag was handed to the window server, so the check that it
        /// took effect does not run before the server could possibly act.
        var boundAt: Date?
        /// The last location we emitted — the session pointer. A cancel's
        /// synthetic mouse-up has to land exactly there.
        var lastEmitted: CGPoint
    }

    private enum State {
        case idle
        /// Down swallowed; waiting for the first drag to start the session.
        case pending(Grab)
        /// Drag session running.
        case dragging(Grab)
        /// Esc-cancelled: the session was already ended synthetically;
        /// swallow the rest of the physical gesture until its mouse-up.
        case cancelled(isResize: Bool)
    }

    /// How long a gesture waits for the overlay to reach the screen before
    /// giving up. Swallowing a few drag events is invisible; aiming a
    /// mouse-down at a panel that isn't there yet would put a stray click into
    /// the user's app.
    private static let overlayWait: TimeInterval = 0.4

    /// How long the SkyLight bind waits after the synthetic mouse-down.
    /// The window server only hands a window over to a press it has finished
    /// processing; binding too eagerly returns success and moves nothing.
    /// Drag events are swallowed during the wait, so the window starts moving
    /// a beat late but perfectly aligned rather than jumping.
    /// Explains the fallback wherever it is surfaced.
    static let noSessionNote =
        "no drag session (grant Screen Recording to get tiling and snapping back)"

    /// Grace period between the synthetic mouse-down and the bind. Drag events
    /// are swallowed during it, so the window starts moving a beat late but
    /// perfectly aligned instead of jumping by the pointer travel.
    private static let bindDelay: TimeInterval = 0.03

    /// How long after the bind to wait before judging whether the window
    /// server honoured it. Several drag events must have been delivered, so
    /// this is generously longer than one frame.
    private static let verifyDelay: TimeInterval = 0.25


    /// Toggled from the menu (main thread); read on the tap thread.
    var enabled = true
    /// Cleared during fast user switching.
    var sessionActive = true
    /// One-line outcome of the most recent modifier-drag, for the menu's
    /// diagnostics row. Written on the tap thread, read on the main thread.
    private(set) var lastStatus: String?
    /// Fired on the tap thread as a gesture begins/ends; EventTap arms the
    /// Esc (cancel) keyboard tap only while one is in flight.
    var onDragActiveChanged: ((Bool) -> Void)?

    /// Cleared the first time a bound drag is seen to move nothing, so the
    /// rest of the session goes straight to the Accessibility fallback instead
    /// of dying silently on every gesture. Re-armed by reloadConfig(), so
    /// granting the missing permission takes effect without a relaunch.
    private var dragSessionsWork = true

    private var state: State = .idle
    private var config = Config.load()
    private let overlay = GrabOverlay()

    func reloadConfig() {
        config = Config.load()
        dragSessionsWork = SkyLight.available
        dragSessionsRefused = false
    }

    /// Abandon any gesture in flight and return to a clean slate. Called when
    /// the event tap is disabled or re-enabled (its callback overran, or the
    /// system dropped it) — those events never reach handle(), so without an
    /// explicit reset the state machine keeps waiting for a mouse-up that can
    /// no longer arrive.
    func resetGesture() {
        guard !isIdle else { return }
        state = .idle
        overlay.hide()
        onDragActiveChanged?(false)
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    var currentConfig: Config { config }

    /// Whether the window-server drag SPI is present. Surfaced in the menu so
    /// a future macOS removing it is visible rather than mysterious.
    var dragSessionsAvailable: Bool { SkyLight.available }

    /// True once a drag has been observed to bind and move nothing — the
    /// window server is refusing the hand-over, so moves are degraded.
    private(set) var dragSessionsRefused = false

    // MARK: - Event handling (tap thread)

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Events we post ourselves (the cancel's mouse-up) re-enter the tap;
        // they are already final — let them through untouched.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticUserData {
            return pass
        }
        guard enabled, sessionActive else { return pass }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            // A fresh button press means any previous gesture is over, whatever
            // the state machine still believes. Without this, one lost mouse-up
            // — the tap being disabled mid-drag by a callback overrun, a Space
            // switch, fast user switching — would strand `state` off .idle and
            // silently kill every future drag until relaunch.
            if case .idle = state {} else { resetGesture() }
            guard modifiersMatch(event.flags) else { return pass }
            return beginGrab(event, isResize: type == .rightMouseDown) ? nil : pass

        case .leftMouseDragged, .rightMouseDragged:
            switch state {
            case .pending(var grab):
                guard sourceMatches(type, isResize: grab.isResize) else { return pass }

                if grab.degraded {
                    // No session to start: just start moving the window.
                    state = .dragging(grab)
                    lastStatus = "moving a \(grab.appName) window without a drag session"
                    moveWithAccessibility(grab, to: event.location)
                    return nil
                }
                // A move aims its mouse-down at the overlay, so the overlay has
                // to be on screen first. It normally is — it was ordered front
                // on the main thread a frame ago — but a busy main thread must
                // not cause a stray click in the user's app, so wait, and
                // abandon the gesture rather than fire blind.
                if !grab.isResize, !overlay.isReady {
                    guard Date().timeIntervalSince(grab.startedAt) < Self.overlayWait else {
                        state = .idle
                        overlay.hide()
                        onDragActiveChanged?(false)
                        lastStatus = "gesture abandoned — the grab overlay never appeared"
                        return nil
                    }
                    return nil   // swallow; try again on the next drag event
                }

                // First drag: puts the button down — on our overlay for a
                // move, on the window's resize border for a resize.
                event.type = .leftMouseDown
                event.location = grab.point
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.flags = strippedFlags(event.flags)
                grab.lastEmitted = event.location
                grab.downAt = Date()
                state = .dragging(grab)
                lastStatus = [grab.isResize ? "resized" : "moved",
                              "a \(grab.appName) window", grab.note.map { "— \($0)" }]
                    .compactMap { $0 }.joined(separator: " ")
                return pass

            case .dragging(var grab):
                guard sourceMatches(type, isResize: grab.isResize) else { return pass }

                if grab.degraded {
                    moveWithAccessibility(grab, to: event.location)
                    return nil
                }
                if grab.isResize {
                    event.type = .leftMouseDragged
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                } else if !grab.bound {
                    // Wait for the press to settle before handing the window
                    // over; swallow drags meanwhile so the pointer travel does
                    // not become a grip offset.
                    guard let downAt = grab.downAt,
                          Date().timeIntervalSince(downAt) >= Self.bindDelay else { return nil }
                    // The synthetic down from the previous event has landed, so
                    // the server has a live button press to bind to. Its
                    // pointer is still AT that down, which is why the offset
                    // measured at grab time is the right one: the window stays
                    // put now and tracks from here.
                    grab.bound = true
                    grab.boundAt = Date()
                    let ok = SkyLight.beginDrag(window: grab.windowID, offset: grab.dragOffset)
                    if !ok {
                        lastStatus = "the window server refused to drag the "
                            + "\(grab.appName) window"
                    }
                    // The overlay stays up for the whole drag: it owns the
                    // mouse-down the session is bound to, and ordering it out
                    // while the button is still down ends the session.
                }
                // A bind that reports success but moves nothing means the
                // window server declined the hand-over — on this system the
                // observed cause is a missing Screen Recording grant. Rather
                // than guess at permissions, prove it: once the pointer has
                // travelled far enough for movement to be unmistakable, look
                // at the window. If it has not budged, release the button and
                // finish the gesture (and every later one) with Accessibility
                // moves, so the user gets a window that moves and a status
                // line saying what was lost.
                // Give the server time to actually act first: the binding
                // event has not even been delivered yet at the moment the bind
                // returns, so anything sooner than this always reports "did not
                // move" and would degrade every single drag.
                if grab.bound, !grab.verified,
                   let boundAt = grab.boundAt,
                   Date().timeIntervalSince(boundAt) >= Self.verifyDelay,
                   hypot(event.location.x - grab.cursorAtGrab.x,
                         event.location.y - grab.cursorAtGrab.y) >= 24 {
                    let moved = WindowResolver.liveBounds(of: grab.windowID).map {
                        abs($0.minX - grab.originalFrame.minX) >= 1
                            || abs($0.minY - grab.originalFrame.minY) >= 1
                    } ?? true
                    grab.verified = true
                    if !moved {
                        dragSessionsWork = false
                        dragSessionsRefused = true
                        grab.degraded = true
                        releaseSyntheticButton(at: grab.lastEmitted)
                        overlay.hide()
                        lastStatus = "moving a \(grab.appName) window — \(Self.noSessionNote)"
                        state = .dragging(grab)
                        moveWithAccessibility(grab, to: event.location)
                        return nil
                    }
                }
                event.location = alignedLocation(event.location, grab: grab)
                event.flags = strippedFlags(event.flags)
                grab.lastEmitted = event.location
                state = .dragging(grab)
                return pass

            case .cancelled(let isResize):
                // Session already ended; eat the rest of the gesture.
                return sourceMatches(type, isResize: isResize) ? nil : pass
            case .idle:
                return pass
            }

        case .leftMouseUp, .rightMouseUp:
            switch state {
            case .pending(let grab):
                guard buttonMatches(type, isResize: grab.isResize) else { return pass }
                // Modifier-click with no drag: swallow the up too (the down was
                // already swallowed) so the app under the cursor sees nothing.
                // The system click chain survives the swallowing, so clickState
                // 2 here is a genuine double-click at the user's own speed: run
                // the fill (left) / center (right) gesture.
                state = .idle
                overlay.hide()
                onDragActiveChanged?(false)
                if event.getIntegerValueField(.mouseEventClickState) >= 2 {
                    performDoubleClickAction(grab)
                } else {
                    lastStatus = "click swallowed (no drag)"
                }
                return nil

            case .dragging(var grab):
                guard buttonMatches(type, isResize: grab.isResize) else { return pass }
                if grab.degraded {
                    state = .idle
                    onDragActiveChanged?(false)
                    lastStatus = "moved a \(grab.appName) window "
                        + "(no drag session — no tiling or snapping)"
                    return nil
                }
                if grab.isResize {
                    event.type = .leftMouseUp
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                }
                let releasePoint = alignedLocation(event.location, grab: grab)
                event.location = releasePoint
                event.flags = strippedFlags(event.flags)
                grab.lastEmitted = releasePoint
                state = .idle
                overlay.hide()
                onDragActiveChanged?(false)
                reportDragOutcome(grab, releasedAt: releasePoint)
                return pass

            case .cancelled(let isResize):
                guard buttonMatches(type, isResize: isResize) else { return pass }
                state = .idle
                return nil
            case .idle:
                return pass
            }

        default:
            return pass
        }
    }

    private func sourceMatches(_ type: CGEventType, isResize: Bool) -> Bool {
        isResize ? type == .rightMouseDragged : type == .leftMouseDragged
    }

    private func buttonMatches(_ type: CGEventType, isResize: Bool) -> Bool {
        isResize ? type == .rightMouseUp : type == .leftMouseUp
    }

    // MARK: - Location alignment

    /// The location to emit for a drag/up event.
    ///
    /// A resize session was started at the window's corner, so every event
    /// carries that offset. A move session tracks the pointer directly — the
    /// server already keeps the grabbed point under the cursor — so the only
    /// adjustment is the optional magnetic pull toward neighbouring windows.
    ///
    /// That the pull works at all is a measured property of the SkyLight drag:
    /// it follows the event stream we emit, not the hardware cursor, so
    /// nudging a location still steers the window.
    private func alignedLocation(_ location: CGPoint, grab: Grab) -> CGPoint {
        guard !grab.isResize else { return location + grab.offset }
        return location + magneticDelta(pointer: location, grab: grab)
    }

    // MARK: - Magnetic window-to-window snapping

    /// Pointer nudge that brings the dragged window's edges into
    /// abutment/alignment with a neighbor's edges, when within the snap
    /// distance. Stateless per event: the delta appears while the prospective
    /// (unsnapped) frame is within range and vanishes once the hand pulls
    /// past it — which is the classic magnetic feel.
    private func magneticDelta(pointer: CGPoint, grab: Grab) -> CGVector {
        let distance = config.magneticSnapDistance
        guard distance > 0, !grab.isResize, !grab.neighbors.isEmpty else { return .zero }
        // The session keeps the grip offset constant, so the window's frame
        // tracks the pointer's total displacement from the grab point.
        let f = grab.originalFrame.offsetBy(dx: pointer.x - grab.cursorAtGrab.x,
                                            dy: pointer.y - grab.cursorAtGrab.y)
        var bestDX = CGFloat.infinity
        var bestDY = CGFloat.infinity
        for n in grab.neighbors {
            // Snap an axis only when the windows are adjacent on the other
            // axis (ranges overlap, or gap within the snap distance) — never
            // to far-away windows across the screen.
            let yNear = f.minY < n.maxY + distance && f.maxY > n.minY - distance
            let xNear = f.minX < n.maxX + distance && f.maxX > n.minX - distance
            if yNear {
                for d in [n.maxX - f.minX,   // abut: our left edge to their right
                          n.minX - f.maxX,   // abut: our right edge to their left
                          n.minX - f.minX,   // align left edges
                          n.maxX - f.maxX]   // align right edges
                where abs(d) <= distance && abs(d) < abs(bestDX) { bestDX = d }
            }
            if xNear {
                for d in [n.maxY - f.minY, n.minY - f.maxY,
                          n.minY - f.minY, n.maxY - f.maxY]
                where abs(d) <= distance && abs(d) < abs(bestDY) { bestDY = d }
            }
        }
        return CGVector(dx: bestDX.isFinite ? bestDX : 0,
                        dy: bestDY.isFinite ? bestDY : 0)
    }

    /// On-screen normal/floating windows other than the dragged one, capped
    /// to bound the per-event arithmetic. Snapshotted once per drag.
    private func neighborFrames(excluding target: TargetWindow,
                                in snapshot: [WindowSnapshot]) -> [CGRect] {
        var rects: [CGRect] = []
        for w in snapshot where w.layer == 0 || w.layer == 3 {
            guard w.bounds.width >= 40, w.bounds.height >= 40 else { continue }
            if w.pid == target.pid,
               abs(w.bounds.minX - target.frame.minX) < 2,
               abs(w.bounds.minY - target.frame.minY) < 2 { continue }   // the dragged window
            rects.append(w.bounds)
            if rects.count >= 20 { break }
        }
        return rects
    }

    // MARK: - System tiling settings

    /// A boolean from the com.apple.WindowManager domain, where the native
    /// tiling switches live; a missing key means the system default (on).
    static func windowManagerFlag(_ key: String) -> Bool {
        let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.WindowManager" as CFString)
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number != 0 }
        return true
    }

    // MARK: - Double-click gestures

    /// The previously-filled window and its pre-fill frame, so a second
    /// double-click restores it. Main-thread only.
    private var lastFill: (element: AXUIElement, previous: CGRect)?

    /// Modifier double-click with no drag: left fills the screen's visible
    /// frame (double-click again to restore), right centers the window.
    /// Runs on the main thread (AX writes + NSScreen geometry).
    private func performDoubleClickAction(_ grab: Grab) {
        let element = grab.element
        let frame = grab.originalFrame
        DispatchQueue.main.async { [weak self] in
            guard let self, let visible = self.visibleFrameCG(containing: frame) else { return }
            if grab.isResize {
                let centered = CGRect(x: (visible.midX - frame.width / 2).rounded(),
                                      y: (visible.midY - frame.height / 2).rounded(),
                                      width: frame.width, height: frame.height)
                WindowResolver.setFrame(centered, of: element)
                self.lastStatus = "centered a \(grab.appName) window"
            } else if let last = self.lastFill, CFEqual(last.element, element),
                      self.approximatelyEqual(frame, visible) {
                WindowResolver.setFrame(last.previous, of: element)
                self.lastFill = nil
                self.lastStatus = "restored a \(grab.appName) window"
            } else {
                self.lastFill = (element, frame)
                WindowResolver.setFrame(visible, of: element)
                self.lastStatus = "filled the screen with a \(grab.appName) window"
            }
        }
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The visible frame (minus menu bar / Dock) of the screen containing
    /// `rect`'s center, converted from AppKit's y-up coordinates to the CG
    /// y-down global space that AX shares.
    private func visibleFrameCG(containing rect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        func toCG(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        // Largest intersection, not "contains the centre": a window straddling
        // two displays — or one whose centre falls in an uncovered gap between
        // mismatched displays — has no containing screen at all.
        func overlap(_ screen: NSScreen) -> CGFloat {
            let i = toCG(screen.frame).intersection(rect)
            return i.isNull ? 0 : i.width * i.height
        }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) } ?? NSScreen.main
        return screen.map { toCG($0.visibleFrame) }
    }

    // MARK: - Grab setup

    private func beginGrab(_ event: CGEvent, isResize: Bool) -> Bool {
        let cursor = event.location
        // Non-blocking pre-check first: only points whose TOPMOST window is a
        // normal (0) or floating (3) window are grab candidates. Status items,
        // menu-bar overlays, and switcher HUD panels all sit at higher levels —
        // those clicks pass through with zero AX traffic, so a busy menubar
        // process can never wedge the session's mouse pipeline, and clicks meant
        // for other utilities' panels are never swallowed.
        let snapshot = WindowResolver.onScreenWindows()
        guard let top = WindowResolver.topWindow(at: cursor, in: snapshot) else {
            lastStatus = "no window under the cursor"
            return false
        }
        guard top.layer == 0 || top.layer == 3 else {
            lastStatus = "passed through — topmost window there belongs to "
                + "\(appName(pid: top.pid)) (level \(top.layer))"
            return false
        }
        if let bid = bundleID(pid: top.pid), config.disabledApps.contains(bid) {
            lastStatus = "\(appName(pid: top.pid)) is in Disabled Apps"
            return false
        }

        // Hard budget for the AX resolution. The whole session's mouse delivery
        // waits on this callback, and macOS disables any tap that overruns
        // (~1 s) — which drops the gesture entirely. Individual AX calls are
        // bounded at 0.25 s, so the total has to leave room for one of those to
        // land badly on top of the budget: 0.35 + 0.25 still clears the limit.
        let deadline = Date().addingTimeInterval(0.35)
        guard let target = WindowResolver.window(at: cursor, deadline: deadline) else {
            lastStatus = "couldn't resolve the \(appName(pid: top.pid)) window (AX timed out)"
            return false
        }
        if let bid = target.bundleID, config.disabledApps.contains(bid) {
            lastStatus = "\(appName(pid: target.pid)) is in Disabled Apps"
            return false
        }

        let name = appName(pid: target.pid)
        let wid = windowID(of: target, in: snapshot)
        let chosen = isResize
            ? resizeGrab(cursor: cursor, target: target, name: name,
                         windowID: wid, snapshot: snapshot)
            : moveGrab(cursor: cursor, target: target, name: name,
                       windowID: wid, snapshot: snapshot)
        guard let chosen else { return false }

        WindowResolver.raise(target)
        state = .pending(chosen)
        lastStatus = "grabbed a \(name) window"
        onDragActiveChanged?(true)
        return true
    }

    /// A move needs no clickable point on the window at all — the drag is
    /// named by window ID — so the only hard requirement is having that ID.
    /// Without it there is no way to say WHICH window to drag.
    private func moveGrab(cursor: CGPoint, target: TargetWindow, name: String,
                          windowID wid: CGWindowID, snapshot: [WindowSnapshot]) -> Grab? {
        guard wid != 0 else {
            lastStatus = "couldn't identify the \(name) window to the window server"
            return nil
        }
        // No SkyLight means no drag session anywhere in this process, so say
        // so plainly and fall back to plain Accessibility moves.
        let degraded = !SkyLight.available || !dragSessionsWork

        // The press goes exactly where the user grabbed, so the drag stream is
        // continuous with it. Snap-on-drag apps follow the pointer from the
        // press onward, and a press that jumps to a different point (the title
        // bar, say) breaks that continuity and they ignore the whole drag —
        // measured against Magnet.
        //
        // Nothing has to be clickable here: the overlay absorbs the press, so
        // whatever the app draws under the cursor is never activated. That is
        // what makes this two lines instead of the probing ladder it replaced.
        let frame = target.frame
        let downPoint = cursor
        if !degraded { overlay.show(atCG: downPoint) }

        return Grab(isResize: false, appName: name,
                    element: target.element, pid: target.pid,
                    originalFrame: frame, windowID: wid,
                    point: downPoint, offset: .zero,
                    dragOffset: CGPoint(x: cursor.x - frame.minX,
                                        y: cursor.y - frame.minY),
                    cursorAtGrab: cursor,
                    neighbors: config.magneticSnapDistance > 0
                        ? neighborFrames(excluding: target, in: snapshot) : [],
                    note: degraded
                        ? (SkyLight.available ? Self.noSessionNote
                                              : "the window-server drag SPI is missing")
                        : nil,
                    degraded: degraded, startedAt: Date(), lastEmitted: cursor)
    }

    private func resizeGrab(cursor: CGPoint, target: TargetWindow, name: String,
                            windowID wid: CGWindowID, snapshot: [WindowSnapshot]) -> Grab? {
        guard let choice = resizeGrabPoint(cursor: cursor, frame: target.frame,
                                           windowID: wid, snapshot: snapshot) else {
            lastStatus = "couldn't reach \(name)'s resize corners — click passed through"
            return nil
        }
        // Nothing reaches the wire unvalidated: a synthetic mouse-down at a
        // point on no display starts no session, and because the physical down
        // was already swallowed the whole gesture would silently vanish.
        guard WindowResolver.onAnyDisplay(choice.point) else {
            lastStatus = "grab point for \(name) was off-screen — click passed through"
            return nil
        }
        return Grab(isResize: true, appName: name,
                    element: target.element, pid: target.pid,
                    originalFrame: target.frame, windowID: wid,
                    point: choice.point,
                    offset: CGVector(dx: choice.point.x - cursor.x,
                                     dy: choice.point.y - cursor.y),
                    dragOffset: .zero, cursorAtGrab: cursor,
                    neighbors: [], note: choice.note,
                    degraded: false, startedAt: Date(), lastEmitted: choice.point)
    }

    /// A chosen resize grab point, plus a note for the diagnostics line.
    private struct GrabChoice {
        let point: CGPoint
        var note: String? = nil
    }

    /// A point just inside the window's resize border at a corner that is
    /// actually reachable — preferring the quadrant the user clicked, then the
    /// remaining corners, so a window clipped by a screen edge still resizes.
    private func resizeGrabPoint(cursor: CGPoint, frame: CGRect, windowID: CGWindowID,
                                 snapshot: [WindowSnapshot]) -> GrabChoice? {
        let inset = config.resizeInset
        let xs = [frame.minX + inset, frame.maxX - inset]
        let ys = [frame.minY + inset, frame.maxY - inset]
        let px = cursor.x < frame.midX ? 0 : 1
        let py = cursor.y < frame.midY ? 0 : 1
        let order = [(px, py), (1 - px, py), (px, 1 - py), (1 - px, 1 - py)]
        for (i, j) in order {
            let corner = CGPoint(x: xs[i], y: ys[j])
            guard deliverable(corner, in: frame, ownedBy: windowID, snapshot) else { continue }
            let note = (i, j) == (px, py) ? nil : "resized from the nearest reachable corner"
            return GrabChoice(point: corner, note: note)
        }
        return nil
    }

    /// The invariant for a synthetic mouse-down aimed at a window: the point is
    /// on an active display, inside that window, and the window server would
    /// hit-test it to THAT window.
    ///
    /// Both halves of the occlusion test are load-bearing. System chrome — the
    /// menu bar (level 24), Dock (20), status windows (25) — hit-tests above
    /// every ordinary window, so a synthetic mouse-down under one opens a menu
    /// instead of starting a resize. And an ordinary window covering the point
    /// is equally fatal, because the session starts on whatever the server
    /// finds there: aiming at a covered corner resizes someone else's window.
    /// Raising the target does not make that safe — the raise is dispatched to
    /// the main thread while this snapshot and the synthetic down are not, so
    /// the stacking we can see may still be in force when the event lands.
    private func deliverable(_ p: CGPoint, in frame: CGRect, ownedBy windowID: CGWindowID,
                             _ snapshot: [WindowSnapshot]) -> Bool {
        guard frame.insetBy(dx: -0.5, dy: -0.5).contains(p),
              WindowResolver.onAnyDisplay(p),
              let top = WindowResolver.topWindow(at: p, in: snapshot),
              top.layer == 0 || top.layer == 3 else { return false }
        // windowID 0 means CG and AX disagree about which window this is; we
        // cannot prove ownership, so fall back to the level test alone.
        return windowID == 0 || top.id == windowID
    }

    private func windowID(of target: TargetWindow, in snapshot: [WindowSnapshot]) -> CGWindowID {
        // Match CG's view of the window to AX's by owner and origin. On
        // disagreement return 0: a resize degrades to a weaker occlusion check,
        // and a move declines outright.
        for w in snapshot where w.pid == target.pid
            && abs(w.bounds.minX - target.frame.minX) < 2
            && abs(w.bounds.minY - target.frame.minY) < 2 {
            return w.id
        }
        return 0
    }

    private func bundleID(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    // MARK: - Degraded move (no window-server drag SPI)

    /// Last-resort move for a system where `SLSDragWindowRelativeToMouse` has
    /// gone: write the window's position directly. No drag session exists, so
    /// nothing downstream — native tiling, Magnet, Rectangle — reacts, and the
    /// status line says so. The write is dispatched off the tap thread: AX
    /// writes are cross-process round trips and the session's whole mouse
    /// pipeline is waiting on this callback.
    private func moveWithAccessibility(_ grab: Grab, to location: CGPoint) {
        let origin = CGPoint(x: grab.originalFrame.minX + location.x - grab.cursorAtGrab.x,
                             y: grab.originalFrame.minY + location.y - grab.cursorAtGrab.y)
        let element = grab.element
        DispatchQueue.main.async {
            WindowResolver.setOrigin(origin, of: element)
        }
    }

    /// After a drag that travelled a real distance, check whether the window
    /// actually went anywhere. If it didn't, the drag never bound (the SPI was
    /// refused, the window vanished mid-gesture, or it is a full-screen window
    /// the server will not move) — say so in the diagnostics line instead of
    /// leaving the user to wonder. Purely observational: it runs after the
    /// gesture is over and touches no events.
    private func reportDragOutcome(_ grab: Grab, releasedAt: CGPoint) {
        guard grab.windowID != 0, !grab.isResize else { return }
        let travel = hypot(releasedAt.x - grab.cursorAtGrab.x,
                           releasedAt.y - grab.cursorAtGrab.y)
        guard travel >= 24 else { return }
        let before = grab.originalFrame
        let name = grab.appName
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let now = WindowResolver.liveBounds(of: grab.windowID) else { return }
            if abs(now.minX - before.minX) < 2, abs(now.minY - before.minY) < 2 {
                self.lastStatus = "the \(name) window didn't move — no drag session started"
            }
        }
    }

    private func appName(pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "app \(pid)"
    }

    // MARK: - Cancel (Esc)

    /// Tag carried by events we post ourselves, so the tap lets them through.
    private static let syntheticUserData: Int64 = 0x5753_4654   // "WSFT"

    private static let syntheticSource: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = syntheticUserData
        return source
    }()

    /// End the button press we synthesised, without ending the user's gesture.
    private func releaseSyntheticButton(at point: CGPoint) {
        guard let up = CGEvent(mouseEventSource: Self.syntheticSource, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        up.flags = strippedFlags(up.flags)
        up.post(tap: .cghidEventTap)
    }

    /// Called from the Esc keyboard tap (same thread as the mouse tap, so no
    /// races with handle()). Ends the session where it stands and restores the
    /// window's original frame.
    ///
    /// The session has to be ended by ending the BUTTON: the window server's
    /// own cancel call (`SLSPackagesCancelWindowDrag`) reports success and
    /// leaves the window following the mouse regardless. So: synthetic
    /// mouse-up, then put the frame back — which also undoes a tile or snap
    /// that committed on that mouse-up.
    func cancelDrag() -> Bool {
        switch state {
        case .idle:
            return false
        case .pending(let grab):
            // Nothing started yet — just eat the rest of the gesture.
            state = .cancelled(isResize: grab.isResize)
            overlay.hide()
            onDragActiveChanged?(false)
            lastStatus = "cancelled (Esc)"
            return true
        case .dragging(let grab):
            state = .cancelled(isResize: grab.isResize)
            overlay.hide()
            if !grab.degraded,
               let up = CGEvent(mouseEventSource: Self.syntheticSource, mouseType: .leftMouseUp,
                                mouseCursorPosition: grab.lastEmitted, mouseButton: .left) {
                up.flags = strippedFlags(up.flags)
                up.post(tap: .cghidEventTap)
            }
            let element = grab.element
            let frame = grab.originalFrame
            // Restore after the session has fully ended (and any snap that
            // committed on the synthetic up has been applied — this undoes
            // that too).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                WindowResolver.setFrame(frame, of: element)
            }
            onDragActiveChanged?(false)
            lastStatus = "cancelled (Esc) — window restored"
            return true
        case .cancelled:
            return false
        }
    }

    // MARK: - Modifier handling

    private static let relevantModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
    ]

    /// All configured modifiers held, and no other relevant ones. Caps lock
    /// (alphaShift) and device-dependent bits are ignored for matching.
    private func modifiersMatch(_ flags: CGEventFlags) -> Bool {
        flags.intersection(Self.relevantModifiers)
            == config.modifierFlags.intersection(Self.relevantModifiers)
    }

    /// NX device-dependent sub-bits that accompany the coalesced masks; strip
    /// them together with their mask so nothing downstream (AppKit's
    /// ctrl-click => context menu, cmd-click handling, ...) sees our modifier.
    private static let deviceBits: [(CGEventFlags, UInt64)] = [
        (.maskControl, 0x0000_0001 | 0x0000_2000),   // NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK
        (.maskShift, 0x0000_0002 | 0x0000_0004),     // NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK
        (.maskCommand, 0x0000_0008 | 0x0000_0010),   // NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK
        (.maskAlternate, 0x0000_0020 | 0x0000_0040), // NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK
    ]

    private func strippedFlags(_ flags: CGEventFlags) -> CGEventFlags {
        var raw = flags.subtracting(config.modifierFlags).rawValue
        for (mask, bits) in Self.deviceBits where config.modifierFlags.contains(mask) {
            raw &= ~bits
        }
        return CGEventFlags(rawValue: raw)
    }
}

private func + (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
}
