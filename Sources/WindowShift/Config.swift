import Foundation
import CoreGraphics

/// How drag events are aligned with the synthetic grab point.
enum DragMode: String {
    /// Warp the cursor to the grab point for the duration of the drag (and
    /// back on release). Event location == visible cursor, so native tiling
    /// hot zones trigger exactly at the mouse position at all times.
    case warp
    /// Keep the cursor where the user grabbed and offset event locations to
    /// the grab point. Near screen edges the offset collapses to zero ("edge
    /// handoff") so native tiling sees the pointer exactly at the mouse and
    /// previews/commits there; Magnet/Rectangle key off the real cursor and
    /// are exact in this mode regardless.
    case offset
}

/// What happens to the collapsed edge-handoff offset after the cursor leaves
/// the screen-edge band (offset drag mode only).
enum HandoffRelease: String {
    /// Once collapsed at any edge, stay collapsed for the rest of the drag.
    case sticky
    /// Stay collapsed only when engaged at the TOP edge (where Mission
    /// Control / the Spaces bar live below the band); ease back elsewhere.
    case topSticky = "top-sticky"
    /// Always ease back on exit, but force the collapse whenever Mission
    /// Control is detected open, so Spaces-bar drops track the cursor.
    case missionControl = "mission-control"
}

/// UserDefaults-backed configuration. Reloadable from the menu; read on the tap
/// thread as an immutable value (replaced wholesale by reloadConfig()).
struct Config {
    var modifierFlags: CGEventFlags
    var dragMode: DragMode
    var edgeSnapProximity: CGFloat
    /// Magnetic window-to-window snapping during move drags: pull the dragged
    /// window's edges into abutment/alignment with nearby windows' edges when
    /// within this many px. 0 = off (the default).
    var magneticSnapDistance: CGFloat
    var handoffRelease: HandoffRelease
    var titleBarInset: CGFloat
    var resizeInset: CGFloat
    var trafficLightMargin: CGFloat
    var disabledApps: Set<String>

    static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand,
        "ctrl": .maskControl,
        "opt": .maskAlternate,
        "alt": .maskAlternate,
        "shift": .maskShift,
        "fn": .maskSecondaryFn,
    ]

    static func load() -> Config {
        let d = UserDefaults.standard
        d.register(defaults: [
            "modifiers": "ctrl,cmd",
            "dragMode": "offset",
            "edgeSnapProximity": 30.0,
            "magneticSnapDistance": 0.0,
            "handoffRelease": "top-sticky",
            "titleBarInset": 4.0,
            "resizeInset": 8.0,
            "trafficLightMargin": 90.0,
        ])

        var flags: CGEventFlags = []
        let spec = d.string(forKey: "modifiers") ?? "ctrl,cmd"
        for part in spec.lowercased().split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if let f = modifierNames[name] { flags.insert(f) }
        }
        if flags.isEmpty { flags = [.maskControl, .maskCommand] }

        let disabled = Set((d.array(forKey: "disabledApps") as? [String]) ?? [])

        let mode = DragMode(rawValue: (d.string(forKey: "dragMode") ?? "offset").lowercased()) ?? .offset

        return Config(
            modifierFlags: flags,
            dragMode: mode,
            edgeSnapProximity: CGFloat(d.double(forKey: "edgeSnapProximity")),
            magneticSnapDistance: CGFloat(d.double(forKey: "magneticSnapDistance")),
            handoffRelease: HandoffRelease(
                rawValue: (d.string(forKey: "handoffRelease") ?? "top-sticky").lowercased()
            ) ?? .topSticky,
            titleBarInset: CGFloat(d.double(forKey: "titleBarInset")),
            resizeInset: CGFloat(d.double(forKey: "resizeInset")),
            trafficLightMargin: CGFloat(d.double(forKey: "trafficLightMargin")),
            disabledApps: disabled
        )
    }

    /// Canonical defaults-string form of a modifier set ("ctrl,cmd").
    static func spec(from flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("opt") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskCommand) { parts.append("cmd") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        return parts.joined(separator: ",")
    }

    var modifierDescription: String {
        var parts: [String] = []
        if modifierFlags.contains(.maskControl) { parts.append("\u{2303}") }
        if modifierFlags.contains(.maskAlternate) { parts.append("\u{2325}") }
        if modifierFlags.contains(.maskShift) { parts.append("\u{21E7}") }
        if modifierFlags.contains(.maskCommand) { parts.append("\u{2318}") }
        if modifierFlags.contains(.maskSecondaryFn) { parts.append("fn") }
        return parts.joined()
    }
}
