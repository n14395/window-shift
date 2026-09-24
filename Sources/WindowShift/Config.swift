// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreGraphics

/// UserDefaults-backed configuration. Reloadable from the menu; read on the tap
/// thread as an immutable value (replaced wholesale by reloadConfig()).
struct Config {
    var modifierFlags: CGEventFlags
    /// Magnetic window-to-window snapping during move drags: pull the dragged
    /// window's edges into abutment/alignment with nearby windows' edges when
    /// within this many px. 0 = off (the default).
    var magneticSnapDistance: CGFloat
    var resizeInset: CGFloat
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
            "magneticSnapDistance": 0.0,
            "resizeInset": 8.0,
        ])

        var flags: CGEventFlags = []
        let spec = d.string(forKey: "modifiers") ?? "ctrl,cmd"
        for part in spec.lowercased().split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if let f = modifierNames[name] { flags.insert(f) }
        }
        if flags.isEmpty { flags = [.maskControl, .maskCommand] }

        let disabled = Set((d.array(forKey: "disabledApps") as? [String]) ?? [])

        return Config(
            modifierFlags: flags,
            magneticSnapDistance: CGFloat(d.double(forKey: "magneticSnapDistance")),
            resizeInset: CGFloat(d.double(forKey: "resizeInset")),
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
