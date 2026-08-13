import CoreGraphics
import Foundation

/// Detects whether Mission Control is currently open, without needing the
/// Screen Recording permission (window names are gated; owner/layer/bounds
/// are not). Empirical signature on macOS 26/27: while Mission Control is up,
/// the WindowManager process owns on-screen windows at layer 14 (the Spaces
/// bar strip on each display) and layer 19 (full-display overlays); it owns
/// no on-screen windows at those layers otherwise.
enum MissionControl {
    private static let overlayLayers: Set<Int> = [14, 19]

    static func isOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  let layer = w[kCGWindowLayer as String] as? Int,
                  overlayLayers.contains(layer),
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double else { return false }
            // Display-spanning strips/overlays only, not stray small windows.
            return width >= 800
        }
    }
}
