import AppKit
import CoreGraphics

/// The core state machine. All mouse events from the tap flow through handle().
///
/// Mechanism (see plan): we never move windows ourselves. On modifier+mouseDown
/// we swallow the click; the FIRST subsequent drag event is rewritten in-flight
/// into a leftMouseDown on the window's title bar (move) or resize border
/// (resize). The WindowServer hit-tests that point and starts a genuine
/// server-side drag/resize session, so native edge tiling, Option-drag tiling,
/// and Magnet/Rectangle-style snap-on-drag all engage exactly as for a manual
/// title-bar drag.
///
/// Native tiling hot zones are evaluated against the drag session's pointer,
/// i.e. the event locations. In .warp mode the cursor is warped to the grab
/// point when the drag starts and back on release, so the visible cursor,
/// the event location, and the tiling triggers all coincide. In .offset mode
/// (default) the cursor stays put and event locations carry the grab offset,
/// which ramps away smoothly as the cursor approaches a tiling edge ("edge
/// handoff") so native zones trigger exactly at the mouse.
final class DragController {

    /// Which screen edges hand off (and clamp) for a drag: an edge qualifies
    /// only while something actually has snap zones there — native tiling per
    /// its System Settings switches (top and sides; there are no native
    /// bottom zones), or a running snap-on-drag app (Magnet, Rectangle, …),
    /// which reads locations off this same event stream and zones every edge.
    private struct HandoffEdges {
        let top: Bool
        let sides: Bool
        let bottom: Bool
    }

    private struct Grab {
        let point: CGPoint      // synthetic grab location (title bar / resize corner)
        let offset: CGVector    // point - physical cursor at mouse-down
        let isResize: Bool
        let mode: DragMode
        let handoffEdges: HandoffEdges
        let appName: String
        // For Esc-cancel: the window and its pre-drag frame to restore.
        let element: AXUIElement
        let originalFrame: CGRect
        // Neighbor window frames snapshotted at grab time, for magnetic
        // window-to-window snapping (empty when the feature is off).
        let neighbors: [CGRect]
        // The last event location we emitted — the session pointer. A
        // cancel's synthetic mouse-up must end the session exactly there.
        var lastAligned: CGPoint
        var startedAt = Date.distantPast   // set when the drag session starts
        // Edge handoff (offset mode): fraction of `offset` currently applied.
        // 1 mid-screen; ramps smoothly down to 0 as the cursor approaches a
        // tiling edge (top/left/right) so the session pointer lands on the
        // physical cursor — without the window jumping — by the time native
        // tiling zones engage.
        var ease: CGFloat = 1
        // Set per HandoffRelease policy: once true, the collapse holds for
        // the rest of the drag (so Mission Control / Spaces-bar drops keep
        // tracking the cursor after it leaves the edge band).
        var stickyCollapsed = false
    }

    private enum State {
        case idle
        /// Down swallowed; waiting for the first drag to start the session.
        case pending(Grab)
        /// Native drag session running.
        case dragging(Grab)
        /// Esc-cancelled: the session was already ended synthetically;
        /// swallow the rest of the physical gesture until its mouse-up.
        case cancelled(isResize: Bool)
    }

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

    private var state: State = .idle
    private var config = Config.load()

    func reloadConfig() {
        config = Config.load()
    }

    var currentConfig: Config { config }

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
        case .leftMouseDown:
            guard case .idle = state, modifiersMatch(event.flags) else { return pass }
            return beginGrab(event, isResize: false) ? nil : pass

        case .rightMouseDown:
            guard case .idle = state, modifiersMatch(event.flags) else { return pass }
            return beginGrab(event, isResize: true) ? nil : pass

        case .leftMouseDragged, .rightMouseDragged:
            switch state {
            case .pending(var grab):
                guard sourceMatches(type, isResize: grab.isResize) else { return pass }
                if grab.mode == .warp {
                    CGWarpMouseCursorPosition(grab.point)
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
                grab.startedAt = Date()
                // First drag: becomes the leftMouseDown that starts the native
                // drag session at the grab point.
                event.type = .leftMouseDown
                event.location = grab.point
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.flags = strippedFlags(event.flags)
                state = .dragging(grab)
                lastStatus = "\(grab.isResize ? "resized" : "moved") a \(grab.appName) window"
                return pass
            case .dragging(var grab):
                guard sourceMatches(type, isResize: grab.isResize) else { return pass }
                if grab.isResize {
                    event.type = .leftMouseDragged
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                }
                event.location = alignedLocation(event.location, grab: &grab)
                event.flags = strippedFlags(event.flags)
                grab.lastAligned = event.location
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
                // No warp happened yet, so nothing to restore. The system
                // click chain survives the swallowing, so clickState 2 here
                // is a genuine double-click at the user's own speed: run the
                // fill (left) / center (right) gesture.
                state = .idle
                onDragActiveChanged?(false)
                if event.getIntegerValueField(.mouseEventClickState) >= 2 {
                    performDoubleClickAction(grab)
                } else {
                    lastStatus = "click swallowed (no drag)"
                }
                return nil
            case .dragging(var grab):
                guard buttonMatches(type, isResize: grab.isResize) else { return pass }
                if grab.isResize {
                    event.type = .leftMouseUp
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                }
                let releasePoint = alignedLocation(event.location, grab: &grab)
                event.location = releasePoint
                event.flags = strippedFlags(event.flags)
                state = .idle
                onDragActiveChanged?(false)
                if grab.mode == .warp {
                    warpBack(from: releasePoint, grab: grab)
                }
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

    private func alignedLocation(_ location: CGPoint, grab: inout Grab) -> CGPoint {
        switch grab.mode {
        case .offset:
            // Edge handoff: `location` is the true pointer here (no warp).
            // Collapse the offset instantly when the cursor nears a screen
            // edge — the session pointer lands on the cursor, so the native
            // tiling engine previews/commits exactly at the mouse. Ease the
            // offset back once the cursor leaves the (hysteresis-widened)
            // edge band. Resize sessions never tile, so they skip this.
            guard !grab.isResize, config.edgeSnapProximity > 0 else {
                return location + grab.offset
            }
            if grab.stickyCollapsed { return location }
            let prox = config.edgeSnapProximity
            let edge = collapsibleEdgeDistance(location, edges: grab.handoffEdges)
            // Distance-based ease: 1 outside the ramp, 0 inside the handoff
            // band, linear between. The grip drifts onto the cursor smoothly
            // while the cursor covers the ramp, instead of the whole window
            // jumping by the grab offset the moment the band is crossed.
            let ramp = prox * 4
            var target: CGFloat = 1
            if let d = edge.distance {
                target = min(1, max(0, (d - prox) / (ramp - prox)))
            }
            if config.handoffRelease == .missionControl, missionControlOpen() {
                target = 0
            }
            let easeBefore = grab.ease
            if target <= grab.ease {
                grab.ease = target                         // collapse tracks the hand
            } else {
                grab.ease = min(target, grab.ease + 0.15)  // recovery eases back
            }
            if easeBefore > 0, grab.ease == 0 {
                // Handoff engaged — the grip just landed on the cursor and
                // tiling is armed. Alignment tick (no-op without a haptic
                // trackpad).
                DispatchQueue.main.async {
                    NSHapticFeedbackManager.defaultPerformer
                        .perform(.alignment, performanceTime: .default)
                }
            }
            if grab.ease == 0 {
                switch config.handoffRelease {
                case .sticky:
                    if let d = edge.distance, d <= prox { grab.stickyCollapsed = true }
                case .topSticky:
                    if (edge.topDistance ?? .infinity) <= prox { grab.stickyCollapsed = true }
                case .missionControl:
                    break
                }
            }
            var aligned = location + grab.offset * grab.ease
            if grab.ease > 0 {
                // The grab point (traffic-light gap) sits far from the cursor,
                // so the session pointer could enter a snap zone while the
                // cursor is mid-screen. Keep it clamped to the display
                // interior — zones must only ever trigger at the cursor.
                aligned = clampToDisplayInterior(aligned, near: location,
                                                inset: prox * 1.5, edges: grab.handoffEdges)
            }
            // Magnetic window-to-window snapping, only while fully outside
            // the handoff ramp — inside it, tiling owns the pointer.
            if target == 1 {
                aligned = aligned + magneticDelta(pointer: aligned, grab: grab)
            }
            return aligned
        case .warp:
            // Events generated before the warp landed in the server still
            // carry hand-relative coordinates; during the first instant of
            // the drag, translate anything closer to the pre-warp cursor
            // position than to the grab point.
            var pointer = location
            if Date().timeIntervalSince(grab.startedAt) < 0.1 {
                let preWarpCursor = grab.point - grab.offset
                if location.distance(to: preWarpCursor) < location.distance(to: grab.point) {
                    pointer = location + grab.offset
                }
            }
            // Magnetic snapping away from zone-bearing edges (there, tiling
            // owns the pointer).
            if !nearCommitEdge(pointer, edges: grab.handoffEdges, margin: 60) {
                pointer = pointer + magneticDelta(pointer: pointer, grab: grab)
            }
            return pointer
        }
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
        let f = grab.originalFrame.offsetBy(dx: pointer.x - grab.point.x,
                                            dy: pointer.y - grab.point.y)
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
    private func neighborFrames(excluding target: TargetWindow) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var rects: [CGRect] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 || layer == 3,
                  let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  rect.width >= 40, rect.height >= 40 else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            if let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber,
               pid_t(pidNum.int32Value) == target.pid,
               abs(rect.minX - target.frame.minX) < 2,
               abs(rect.minY - target.frame.minY) < 2 { continue }   // the dragged window
            rects.append(rect)
            if rects.count >= 20 { break }
        }
        return rects
    }

    /// After the native session ends, return the cursor to where the user's
    /// hand "is" (release location minus the warp offset) — unless the drag
    /// ended near an edge that actually carries snap zones, where a
    /// tile/snap likely committed and the cursor should stay at the edge
    /// like a manual drag.
    private func warpBack(from releasePoint: CGPoint, grab: Grab) {
        guard !nearCommitEdge(releasePoint, edges: grab.handoffEdges) else { return }
        let hand = releasePoint - grab.offset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            CGWarpMouseCursorPosition(hand)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    /// Within `margin` of an outer screen edge that has snap zones — shared
    /// display boundaries and zoneless edges never count.
    private func nearCommitEdge(_ p: CGPoint, edges: HandoffEdges, margin: CGFloat = 20) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 else {
            return false
        }
        let b = CGDisplayBounds(display)
        let outer = outerEdges(of: b)
        if edges.top, outer.top, p.y - b.minY < margin { return true }
        if edges.sides, outer.left, p.x - b.minX < margin { return true }
        if edges.sides, outer.right, b.maxX - p.x < margin { return true }
        if edges.bottom, outer.bottom, b.maxY - p.y < margin { return true }
        return false
    }

    /// Clamp `p` into the interior of the display containing `ref` (the
    /// physical cursor). Each edge's inset is capped at the cursor's own
    /// distance to that edge: the clamp may hold the pointer back from an
    /// edge, but never pushes it to the far side of the cursor — that would
    /// re-introduce a pointer jump right at the handoff boundary. Only edges
    /// that actually carry zones clamp; shared display boundaries and
    /// zoneless edges leave the pointer free (it must be able to cross into
    /// an adjacent display mid-drag).
    private func clampToDisplayInterior(_ p: CGPoint, near ref: CGPoint, inset: CGFloat,
                                        edges: HandoffEdges) -> CGPoint {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(ref, 1, &display, &count) == .success, count > 0 else {
            return p
        }
        let b = CGDisplayBounds(display)
        let outer = outerEdges(of: b)
        let big = CGFloat.greatestFiniteMagnitude
        let minX = edges.sides && outer.left ? b.minX + min(inset, max(0, ref.x - b.minX)) : -big
        let maxX = edges.sides && outer.right ? b.maxX - min(inset, max(0, b.maxX - ref.x)) : big
        let minY = edges.top && outer.top ? b.minY + min(inset, max(0, ref.y - b.minY)) : -big
        let maxY = edges.bottom && outer.bottom ? b.maxY - min(inset, max(0, b.maxY - ref.y)) : big
        return CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
    }

    /// Distance from `p` to the nearest screen edge that carries snap zones
    /// for this drag, plus the top-edge distance separately for the
    /// top-sticky policy. Only true outer edges count — a boundary with
    /// another display across it has no zones and must not hand off. nil
    /// when nothing qualifies.
    private func collapsibleEdgeDistance(_ p: CGPoint, edges: HandoffEdges) -> (distance: CGFloat?, topDistance: CGFloat?) {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 else {
            return (nil, nil)
        }
        let b = CGDisplayBounds(display)
        let outer = outerEdges(of: b)
        var d = CGFloat.infinity
        let top = p.y - b.minY
        if edges.top, outer.top { d = min(d, top) }
        if edges.sides, outer.left { d = min(d, p.x - b.minX) }
        if edges.sides, outer.right { d = min(d, b.maxX - p.x) }
        if edges.bottom, outer.bottom { d = min(d, b.maxY - p.y) }
        return (d.isFinite ? d : nil, edges.top && outer.top ? top : nil)
    }

    // MARK: - Display layout

    // Cached arrangement (5 s TTL): which display edges are true outer
    // screen edges vs shared boundaries with an adjacent display.
    private var displayCache: (checked: Date, bounds: [CGRect]) = (.distantPast, [])

    private func allDisplayBounds() -> [CGRect] {
        let now = Date()
        if now.timeIntervalSince(displayCache.checked) > 5 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            CGGetActiveDisplayList(16, &ids, &count)
            displayCache = (now, ids.prefix(Int(count)).map { CGDisplayBounds($0) })
        }
        return displayCache.bounds
    }

    /// Which edges of display bounds `b` have no other display adjacent
    /// across them. Corner-only contact does not count as adjacency.
    private func outerEdges(of b: CGRect) -> (top: Bool, left: Bool, bottom: Bool, right: Bool) {
        var edges = (top: true, left: true, bottom: true, right: true)
        for o in allDisplayBounds() where o != b {
            let xOverlap = o.minX < b.maxX && o.maxX > b.minX
            let yOverlap = o.minY < b.maxY && o.maxY > b.minY
            if xOverlap, abs(o.maxY - b.minY) < 1 { edges.top = false }
            if xOverlap, abs(o.minY - b.maxY) < 1 { edges.bottom = false }
            if yOverlap, abs(o.maxX - b.minX) < 1 { edges.left = false }
            if yOverlap, abs(o.minX - b.maxX) < 1 { edges.right = false }
        }
        return edges
    }

    // MARK: - Snap-app detection

    /// Snap-on-drag utilities whose edge zones read drag-event locations.
    private static let snapAppBundleIDs = [
        "com.crowdcafe.windowmagnet",       // Magnet
        "com.knollsoft.Rectangle",          // Rectangle
        "com.knollsoft.Hookshot",           // Rectangle Pro
        "com.hegenberg.BetterTouchTool",    // BetterTouchTool
        "com.MrKai77.Loop",                 // Loop
    ]

    private var snapAppCache: (checked: Date, running: Bool) = (.distantPast, false)

    private func snapAppRunning() -> Bool {
        let now = Date()
        if now.timeIntervalSince(snapAppCache.checked) > 5 {
            let running = Self.snapAppBundleIDs.contains {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
            }
            snapAppCache = (now, running)
        }
        return snapAppCache.running
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

    private var tilingCache: (checked: Date, sides: Bool, top: Bool) = (.distantPast, true, true)

    /// Whether native drag-tiling is on for the side edges / the top edge.
    private func nativeTilingSettings() -> (sides: Bool, top: Bool) {
        let now = Date()
        if now.timeIntervalSince(tilingCache.checked) > 5 {
            tilingCache = (now,
                           Self.windowManagerFlag("EnableTilingByEdgeDrag"),
                           Self.windowManagerFlag("EnableTopTilingByEdgeDrag"))
        }
        return (tilingCache.sides, tilingCache.top)
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
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { toCG($0.frame).contains(center) } ?? NSScreen.main
        return screen.map { toCG($0.visibleFrame) }
    }

    // Mission Control detection is a window-list scan (~1ms); cache it so the
    // per-mouse-event cost stays negligible.
    private var mcCache: (checked: Date, open: Bool) = (.distantPast, false)

    private func missionControlOpen() -> Bool {
        let now = Date()
        if now.timeIntervalSince(mcCache.checked) > 0.25 {
            mcCache = (now, MissionControl.isOpen())
        }
        return mcCache.open
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
        guard let top = WindowResolver.topWindowInfo(at: cursor) else {
            lastStatus = "no window under the cursor"
            return false
        }
        guard top.layer == 0 || top.layer == 3 else {
            lastStatus = "passed through — topmost window there belongs to "
                + "\(appName(pid: top.pid)) (level \(top.layer))"
            return false
        }
        if let bid = top.bundleID, config.disabledApps.contains(bid) {
            lastStatus = "\(appName(pid: top.pid)) is in Disabled Apps"
            return false
        }

        // Hard budget for the AX resolution: past it, give up and pass the event
        // through rather than holding the session's mouse queue.
        let deadline = Date().addingTimeInterval(0.6)
        guard let target = WindowResolver.window(at: cursor, deadline: deadline) else {
            lastStatus = "couldn't resolve the \(appName(pid: top.pid)) window (AX timed out)"
            return false
        }
        if let bid = target.bundleID, config.disabledApps.contains(bid) {
            lastStatus = "\(appName(pid: target.pid)) is in Disabled Apps"
            return false
        }

        let grabPoint = isResize
            ? resizeGrabPoint(cursor: cursor, frame: target.frame)
            : moveGrabPoint(cursor: cursor, target: target, deadline: deadline)

        WindowResolver.raise(target)
        let offset = CGVector(dx: grabPoint.x - cursor.x, dy: grabPoint.y - cursor.y)
        let name = appName(pid: target.pid)
        let snapApp = snapAppRunning()
        let tiling = nativeTilingSettings()
        let neighbors = config.magneticSnapDistance > 0 && !isResize
            ? neighborFrames(excluding: target) : []
        state = .pending(Grab(point: grabPoint, offset: offset, isResize: isResize,
                              mode: config.dragMode,
                              handoffEdges: HandoffEdges(top: tiling.top || snapApp,
                                                         sides: tiling.sides || snapApp,
                                                         bottom: snapApp),
                              appName: name,
                              element: target.element, originalFrame: target.frame,
                              neighbors: neighbors,
                              lastAligned: grabPoint))
        lastStatus = "grabbed a \(name) window"
        onDragActiveChanged?(true)
        return true
    }

    /// A point in the window's title bar that is safe to grab. Preference
    /// order: the gap between the red and yellow traffic lights (read from
    /// the window's own AX button geometry — universally window chrome,
    /// never tabs/toolbar controls); an AX hit-test probe near the cursor;
    /// the clamped cursor position.
    private func moveGrabPoint(cursor: CGPoint, target: TargetWindow, deadline: Date) -> CGPoint {
        let frame = target.frame
        let y = frame.minY + config.titleBarInset

        if let gap = WindowResolver.trafficLightGapPoint(of: target.element, frame: frame) {
            return gap
        }

        let minX = frame.minX + config.trafficLightMargin
        let maxX = frame.maxX - 20
        guard maxX > minX else { return CGPoint(x: frame.midX, y: y) }
        let x0 = min(max(cursor.x, minX), maxX)

        // Nearest safe candidate wins, trying rightward first at each step —
        // tab strips are usually left-aligned, spare chrome to their right.
        let step: CGFloat = 64
        var candidates: [CGFloat] = [x0]
        for k in 1...12 where candidates.count < 12 {
            let right = x0 + CGFloat(k) * step
            let left = x0 - CGFloat(k) * step
            if right <= maxX { candidates.append(right) }
            if left >= minX { candidates.append(left) }
        }
        // The probes stop at the deadline: a slow AX target degrades to the
        // clamped-cursor fallback instead of holding the mouse queue.
        for x in candidates where Date() < deadline
            && WindowResolver.isSafeDragPoint(CGPoint(x: x, y: y), in: target.element,
                                              deadline: deadline) {
            return CGPoint(x: x, y: y)
        }
        // Nothing verifiably safe (e.g. AX-opaque chrome): fall back to the
        // clamped cursor position — the pre-probe behavior.
        return CGPoint(x: x0, y: y)
    }

    /// A point just inside the window's resize border at the corner nearest
    /// the initial click (quadrant of the window the cursor is in).
    private func resizeGrabPoint(cursor: CGPoint, frame: CGRect) -> CGPoint {
        let inset = config.resizeInset
        let x = cursor.x < frame.midX ? frame.minX + inset : frame.maxX - inset
        let y = cursor.y < frame.midY ? frame.minY + inset : frame.maxY - inset
        return CGPoint(x: x, y: y)
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

    /// Called from the Esc keyboard tap (same thread as the mouse tap, so no
    /// races with handle()). Ends the native session where it stands via a
    /// synthetic mouse-up, swallows the rest of the physical gesture, and
    /// restores the window's original frame.
    func cancelDrag() -> Bool {
        switch state {
        case .idle:
            return false
        case .pending(let grab):
            // Nothing started yet — just eat the rest of the gesture.
            state = .cancelled(isResize: grab.isResize)
            onDragActiveChanged?(false)
            lastStatus = "cancelled (Esc)"
            return true
        case .dragging(let grab):
            state = .cancelled(isResize: grab.isResize)
            if let up = CGEvent(mouseEventSource: Self.syntheticSource, mouseType: .leftMouseUp,
                                mouseCursorPosition: grab.lastAligned, mouseButton: .left) {
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
            if grab.mode == .warp {
                let hand = grab.lastAligned - grab.offset
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    CGWarpMouseCursorPosition(hand)
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
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

private func * (vector: CGVector, scale: CGFloat) -> CGVector {
    CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
}

private func - (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x - vector.dx, y: point.y - vector.dy)
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
