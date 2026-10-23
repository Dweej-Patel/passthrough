#!/usr/bin/env swift
// Renders the Passthrough app icon at every size: a white arrow passing
// through a ring (behind it on the left, in front on the right) on the
// teal→violet brand gradient. Vector drawing, so it stays crisp when small.
//
//   swift scripts/make_icons.swift              iOS and macOS app icons
//   swift scripts/make_icons.swift --android    Android adaptive-icon layers
//   swift scripts/make_icons.swift --preview D  a contact sheet in directory D
import AppKit
import CoreGraphics

let teal = CGColor(red: 0.09, green: 0.78, blue: 0.72, alpha: 1)
let violet = CGColor(red: 0.47, green: 0.33, blue: 0.98, alpha: 1)
let deep = CGColor(red: 0.20, green: 0.16, blue: 0.55, alpha: 1)

enum Layer { case full, background, glyph }

/// Draws the icon into a `size`×`size` bitmap. `rounded` bakes in the macOS
/// corner shape; `glyphScale` shrinks the mark (Android's safe zone).
func render(size: Int, rounded: Bool, layer: Layer = .full, glyphScale: CGFloat = 1) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Work in a 1024-unit square with y down, whatever the pixel size.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: s / 1024, y: -s / 1024)
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)

    if rounded {
        ctx.addPath(CGPath(roundedRect: canvas, cornerWidth: 230, cornerHeight: 230, transform: nil))
        ctx.clip()
    }
    if layer != .glyph { drawBackground(ctx, canvas) }
    if layer != .background { drawGlyph(ctx, scale: glyphScale, shadow: layer == .full) }
    return ctx.makeImage()!
}

func drawBackground(_ ctx: CGContext, _ canvas: CGRect) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Teal top-left to violet, deepening toward the bottom-right corner.
    let base = CGGradient(colorsSpace: space, colors: [teal, violet, deep] as CFArray, locations: [0, 0.62, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 80, y: 0), end: CGPoint(x: 944, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A soft light from the top left, and a little depth at the bottom.
    let light = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(light, startCenter: CGPoint(x: 230, y: 150), startRadius: 0, endCenter: CGPoint(x: 230, y: 150), endRadius: 700, options: [])
    let shade = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.18)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: 560), end: CGPoint(x: 512, y: 1024), options: [])
}

/// A phone with traffic passing through it: the arrow goes in behind the
/// phone's left side and comes out over its right side. Strokes, so the mark has
/// one weight at every size.
func drawGlyph(_ ctx: CGContext, scale: CGFloat, shadow: Bool) {
    let center = CGPoint(x: 512, y: 512)
    let width: CGFloat = 66
    let gap: CGFloat = 24
    let phone = CGRect(x: 512 - 150, y: 512 - 255, width: 300, height: 510)
    var t = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: scale, y: scale).translatedBy(x: -center.x, y: -center.y)
    let body = CGPath(roundedRect: phone, cornerWidth: 78, cornerHeight: 78, transform: &t)
    let island = CGPath(roundedRect: CGRect(x: 512 - 42, y: phone.minY + 52, width: 84, height: 26), cornerWidth: 13, cornerHeight: 13, transform: &t)

    /// A right-pointing arrow along `y` from `start` to `tip`.
    func arrow(y: CGFloat, from start: CGFloat, to tip: CGFloat) -> CGPath {
        let arm: CGFloat = 104
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start, y: y))
        path.addLine(to: CGPoint(x: tip, y: y))
        path.move(to: CGPoint(x: tip - arm, y: y - arm))
        path.addLine(to: CGPoint(x: tip, y: y))
        path.addLine(to: CGPoint(x: tip - arm, y: y + arm))
        return path.copy(using: &t)!
    }
    /// The stretch of the phone's side at `x` that passes over an arrow at `y`.
    func side(x: CGFloat, y: CGFloat, half: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y - half))
        path.addLine(to: CGPoint(x: x, y: y + half))
        return path.copy(using: &t)!
    }

    let w = width * scale, g = gap * scale
    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 14 * scale), blur: 40 * scale, color: CGColor(red: 0.08, green: 0.05, blue: 0.30, alpha: 0.45)) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setLineJoin(.round)
    func stroke(_ path: CGPath, _ lineWidth: CGFloat, cap: CGLineCap = .round, clear: Bool = false) {
        ctx.setBlendMode(clear ? .clear : .normal)
        ctx.setLineCap(cap)
        ctx.addPath(path)
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(.white)
        ctx.strokePath()
    }
    stroke(body, w)
    ctx.setBlendMode(.normal)
    ctx.addPath(island)
    ctx.setFillColor(.white)
    ctx.fillPath()

    let lane: CGFloat = 560
    let path = arrow(y: lane, from: 140, to: 884)
    stroke(path, w + g * 2, clear: true)   // over the side it leaves by
    stroke(path, w)
    // Under the side it comes in by: cut a little short, redrawn a little long.
    stroke(side(x: phone.minX, y: lane, half: width / 2 + gap + 2), w + g * 2, cap: .butt, clear: true)
    stroke(side(x: phone.minX, y: lane, half: width / 2 + gap + 6), w, cap: .butt)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// `opaque` drops the alpha channel (App Store icons must not have one).
func writePNG(_ image: CGImage, to path: String, opaque: Bool = false) {
    var image = image
    if opaque {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        image = ctx.makeImage()!
    }
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), args.count > i + 1 {
    let dir = args[i + 1]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for s in [1024, 128, 64, 32, 16] { writePNG(render(size: s, rounded: true), to: "\(dir)/icon-\(s).png") }
    writePNG(render(size: 432, rounded: false, layer: .background), to: "\(dir)/android-bg.png")
    writePNG(render(size: 432, rounded: false, layer: .glyph, glyphScale: 0.74), to: "\(dir)/android-fg.png")
    print("preview written to \(dir)")
} else if args.contains("--android") {
    // Adaptive icon: 108dp layers, 72dp visible; the mark must sit inside the 66dp safe zone.
    for (density, px) in [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)] {
        let dir = "android/app/src/main/res/mipmap-\(density)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writePNG(render(size: px, rounded: false, layer: .background), to: "\(dir)/ic_launcher_background.png")
        writePNG(render(size: px, rounded: false, layer: .glyph, glyphScale: 0.74), to: "\(dir)/ic_launcher_foreground.png")
    }
    print("android icons written")
} else {
    // iOS masks its own icon; the Mac's shape is baked in.
    writePNG(render(size: 1024, rounded: false), to: "iOS/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png", opaque: true)
    for s in [16, 32, 64, 128, 256, 512, 1024] {
        writePNG(render(size: s, rounded: true), to: "macOS/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-\(s).png")
    }
    print("icons written")
}
