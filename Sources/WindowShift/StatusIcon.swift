// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Menu bar icon, drawn in code as a template image so it stays crisp at any
/// backing scale and adapts to light/dark menu bars. The app icon's central
/// element — the four-way move arrow — as the whole mark.
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let black = NSColor.black
            let c = NSPoint(x: 9, y: 9)
            let reach: CGFloat = 7.8      // center to arrow tip
            let headLen: CGFloat = 3.4
            let headHalf: CGFloat = 2.9
            let shaftW: CGFloat = 2.0

            // Shafts: a plus through the center, ending under the arrowheads.
            let shaftEnd = reach - headLen + 0.3
            let shafts = NSBezierPath()
            shafts.move(to: NSPoint(x: c.x - shaftEnd, y: c.y))
            shafts.line(to: NSPoint(x: c.x + shaftEnd, y: c.y))
            shafts.move(to: NSPoint(x: c.x, y: c.y - shaftEnd))
            shafts.line(to: NSPoint(x: c.x, y: c.y + shaftEnd))
            shafts.lineWidth = shaftW
            black.setStroke()
            shafts.stroke()

            // Heads: filled triangles at the four tips.
            func head(_ dx: CGFloat, _ dy: CGFloat) {
                let tip = NSPoint(x: c.x + dx * reach, y: c.y + dy * reach)
                let bx = c.x + dx * (reach - headLen)
                let by = c.y + dy * (reach - headLen)
                let p = NSBezierPath()
                p.move(to: tip)
                p.line(to: NSPoint(x: bx + dy * headHalf, y: by + dx * headHalf))
                p.line(to: NSPoint(x: bx - dy * headHalf, y: by - dx * headHalf))
                p.close()
                black.setFill()
                p.fill()
            }
            head(1, 0)
            head(-1, 0)
            head(0, 1)
            head(0, -1)
            return true
        }
        image.isTemplate = true
        return image
    }
}
