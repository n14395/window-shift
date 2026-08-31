import CoreGraphics

/// Thin binding to the two SkyLight symbols the move mechanism needs.
///
/// `SLSDragWindowRelativeToMouse` starts a genuine server-side drag of an
/// arbitrary window named by its `CGWindowID` — the same kind of session the
/// window server runs for a manual title-bar drag, so native edge tiling and
/// snap-on-drag apps engage — but without anything having to click the title
/// bar. That is what lets WindowShift move windows whose title bars are full
/// of controls or parked off-screen.
///
/// It is private API, so it is resolved at runtime rather than linked: a
/// future macOS could remove it, or gate it cross-process the way
/// `SLSMoveWindow` (the discrete-teleport call) already is. `available` is the
/// single check every caller must make; `DragController` degrades to an
/// Accessibility move when it is false.
///
/// Measured on macOS 27.0 (26A5421a): both symbols resolve from a normal,
/// Accessibility-granted, SIP-on process, with the hardened runtime enabled
/// and with an ad-hoc or Developer ID signature. No entitlement is involved.
enum SkyLight {
    typealias MainConnFn = @convention(c) () -> Int32
    typealias DragRelFn  = @convention(c) (Int32, UInt32, CGPoint) -> Int32

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let mainConnectionID: MainConnFn? = sym("SLSMainConnectionID", MainConnFn.self)
    private static let dragWindowRelativeToMouse: DragRelFn? =
        sym("SLSDragWindowRelativeToMouse", DragRelFn.self)

    /// Whether the mechanism is usable at all on this system.
    static var available: Bool { mainConnectionID != nil && dragWindowRelativeToMouse != nil }

    /// This process's window-server connection. Stable for the process's life.
    static let connectionID: Int32 = mainConnectionID?() ?? 0

    /// Bind the mouse button that is currently down to a server-side drag of
    /// `window`.
    ///
    /// The contract, established by testing:
    ///  - a real `leftMouseDown` must already have LANDED; with no button down
    ///    the call succeeds and does nothing,
    ///  - `offset` is the cursor's position relative to the window's origin at
    ///    the moment the button went down (CG top-left coordinates), which is
    ///    what keeps the grabbed point under the cursor for the whole drag,
    ///  - the window then tracks the drag EVENT STREAM — not the hardware
    ///    cursor — so rewriting event locations still steers it,
    ///  - there is no working cancel: `SLSPackagesCancelWindowDrag` reports
    ///    success and the window keeps following. Ending the drag means ending
    ///    the button.
    @discardableResult
    static func beginDrag(window: CGWindowID, offset: CGPoint) -> Bool {
        guard let dragWindowRelativeToMouse else { return false }
        return dragWindowRelativeToMouse(connectionID, window, offset) == 0
    }
}
