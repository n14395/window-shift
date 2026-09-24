// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

// Renders the WindowShift app icon (1024x1024 PNG) with CoreGraphics.
// Usage: swift tools/make-icon.swift <output.png>
// Regenerate the .icns after changing this: see tools/make-icon.sh
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

// Background squircle with vertical indigo gradient (everything else clips to it).
let bg = rr(100, 100, 824, 824, 186)
ctx.addPath(bg)
ctx.clip()
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.36, green: 0.52, blue: 0.96, alpha: 1),
        CGColor(red: 0.13, green: 0.17, blue: 0.42, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Left-half tile zone: dashed outline + faint fill (the edge-tiling target).
let tile = rr(170, 190, 330, 644, 42)
ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
ctx.addPath(tile)
ctx.fillPath()
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
ctx.setLineWidth(14)
ctx.setLineDash(phase: 0, lengths: [46, 30])
ctx.addPath(tile)
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// The window being dragged.
let win = rr(430, 290, 400, 430, 46)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 46,
              color: CGColor(gray: 0, alpha: 0.45))
ctx.setFillColor(CGColor(red: 0.965, green: 0.97, blue: 0.985, alpha: 1))
ctx.addPath(win)
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Title bar separator + traffic lights.
ctx.setStrokeColor(CGColor(red: 0.85, green: 0.86, blue: 0.90, alpha: 1))
ctx.setLineWidth(6)
ctx.move(to: CGPoint(x: 434, y: 628))
ctx.addLine(to: CGPoint(x: 826, y: 628))
ctx.strokePath()

let dotColors: [(CGFloat, CGFloat, CGFloat)] = [
    (1.0, 0.373, 0.341), (0.996, 0.737, 0.18), (0.157, 0.784, 0.251),
]
for (i, c) in dotColors.enumerated() {
    ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 465 + CGFloat(i) * 60, y: 653, width: 42, height: 42))
}

// Four-way move arrow in the window body.
let arrowColor = CGColor(red: 0.18, green: 0.23, blue: 0.48, alpha: 1)
let center = CGPoint(x: 630, y: 458)

func arrow(toward angle: CGFloat) {
    let gap: CGFloat = 8, shaftLen: CGFloat = 64, headLen: CGFloat = 60
    let shaftW: CGFloat = 28, headW: CGFloat = 78
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: gap, y: -shaftW / 2))
    p.addLine(to: CGPoint(x: gap + shaftLen, y: -shaftW / 2))
    p.addLine(to: CGPoint(x: gap + shaftLen, y: -headW / 2))
    p.addLine(to: CGPoint(x: gap + shaftLen + headLen, y: 0))
    p.addLine(to: CGPoint(x: gap + shaftLen, y: headW / 2))
    p.addLine(to: CGPoint(x: gap + shaftLen, y: shaftW / 2))
    p.addLine(to: CGPoint(x: gap, y: shaftW / 2))
    p.closeSubpath()
    ctx.setFillColor(arrowColor)
    ctx.addPath(p)
    ctx.fillPath()
    ctx.restoreGState()
}

for i in 0..<4 {
    arrow(toward: CGFloat(i) * .pi / 2)
}
ctx.setFillColor(arrowColor)
ctx.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
