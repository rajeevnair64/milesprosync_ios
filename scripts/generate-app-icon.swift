#!/usr/bin/env swift
// Renders the Miles Pro Sync app icon (default, dark, and tinted appearances) as 1024×1024 PNGs
// into the asset catalog. Run from the project root:
//
//     swift scripts/generate-app-icon.swift
//
// Design: a road curving into the distance and ending at a location pin. Full-bleed square with
// no transparency on the default icon; iOS applies the rounded mask.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let outputDirectory = URL(fileURLWithPath: "MilesProSync/Assets.xcassets/AppIcon.appiconset")

struct Palette {
    var skyTop: CGColor
    var skyBottom: CGColor
    var asphalt: CGColor
    var edgeLine: CGColor
    var centerLine: CGColor
    var pin: CGColor
    var pinDot: CGColor
    var shadow: CGColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let palettes: [(file: String, palette: Palette)] = [
    ("AppIcon.png", Palette(
        skyTop: rgb(0x3D9BFF), skyBottom: rgb(0x0B3A8C),
        asphalt: rgb(0x1F2B3A), edgeLine: rgb(0xFFFFFF), centerLine: rgb(0xFFC93C),
        pin: rgb(0xFFFFFF), pinDot: rgb(0xFF5A4E), shadow: rgb(0x000000, 0.35)
    )),
    ("AppIcon-Dark.png", Palette(
        skyTop: rgb(0x1C2A40), skyBottom: rgb(0x070B12),
        asphalt: rgb(0x2E3D52), edgeLine: rgb(0xDCE4EE), centerLine: rgb(0xFFC93C),
        pin: rgb(0xFFFFFF), pinDot: rgb(0xFF6B5F), shadow: rgb(0x000000, 0.5)
    )),
    // Tinted: grayscale; iOS maps luminance onto the user's chosen tint.
    ("AppIcon-Tinted.png", Palette(
        skyTop: rgb(0x000000), skyBottom: rgb(0x000000),
        asphalt: rgb(0x3A3A3A), edgeLine: rgb(0xA8A8A8), centerLine: rgb(0xFFFFFF),
        pin: rgb(0xFFFFFF), pinDot: rgb(0x000000), shadow: rgb(0x000000, 0)
    )),
]

// MARK: - Road geometry (top-left origin; the context is flipped to match)

/// Centerline of the road: a quadratic curve from below the bottom edge to the vanishing point.
func centerline(_ t: CGFloat) -> CGPoint {
    let p0 = CGPoint(x: 590, y: 1100)
    let p1 = CGPoint(x: 660, y: 760)
    let p2 = CGPoint(x: 490, y: 560)
    let u = 1 - t
    return CGPoint(
        x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
        y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y
    )
}

/// Unit normal to the centerline at t.
func normal(_ t: CGFloat) -> CGVector {
    let a = centerline(max(t - 0.001, 0)), b = centerline(min(t + 0.001, 1))
    let dx = b.x - a.x, dy = b.y - a.y
    let length = max(hypot(dx, dy), 0.0001)
    return CGVector(dx: -dy / length, dy: dx / length)
}

/// Road width, narrowing with distance to suggest perspective.
func roadWidth(_ t: CGFloat) -> CGFloat {
    let near: CGFloat = 700, far: CGFloat = 50
    return far + (near - far) * pow(1 - t, 1.4)
}

/// A strip along the centerline from t0 to t1 whose width is `fraction` of the road width.
func strip(from t0: CGFloat, to t1: CGFloat, fraction: CGFloat, offset: CGFloat = 0, steps: Int = 120) -> CGPath {
    let path = CGMutablePath()
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0...steps {
        let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(steps)
        let c = centerline(t), n = normal(t), w = roadWidth(t)
        let center = CGPoint(x: c.x + n.dx * w * offset, y: c.y + n.dy * w * offset)
        let half = w * fraction / 2
        left.append(CGPoint(x: center.x + n.dx * half, y: center.y + n.dy * half))
        right.append(CGPoint(x: center.x - n.dx * half, y: center.y - n.dy * half))
    }
    path.addLines(between: left + right.reversed())
    path.closeSubpath()
    return path
}

// MARK: - Pin

func pinPath(tip: CGPoint, headRadius r: CGFloat) -> CGPath {
    // A teardrop: circle of radius r whose tangents meet at the tip.
    let center = CGPoint(x: tip.x, y: tip.y - r * 1.55)
    let d = tip.y - center.y
    let angle = asin(r / d) // half-angle at the tip
    let tangentAngle = CGFloat.pi / 2 - angle // measured from the circle center, pointing down-right
    let path = CGMutablePath()
    path.move(to: tip)
    path.addLine(to: CGPoint(x: center.x + r * cos(tangentAngle), y: center.y + r * sin(tangentAngle)))
    path.addArc(
        center: center, radius: r,
        startAngle: tangentAngle, endAngle: .pi - tangentAngle,
        clockwise: true
    )
    path.closeSubpath()
    return path
}

// MARK: - Render

func render(_ palette: Palette, opaque: Bool) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    // Sky / background.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [palette.skyTop, palette.skyBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 200, y: 0), end: CGPoint(x: 824, y: canvas),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Road: white edge lines are the full road; asphalt is drawn slightly narrower on top.
    context.setFillColor(palette.edgeLine)
    context.addPath(strip(from: 0, to: 1, fraction: 1.0))
    context.fillPath()
    context.setFillColor(palette.asphalt)
    context.addPath(strip(from: 0, to: 1, fraction: 0.88))
    context.fillPath()

    // Dashed center line, dashes shortening with distance.
    context.setFillColor(palette.centerLine)
    // Each dash (and gap) is 85% of the previous one; the series sums to just past the horizon,
    // and the dash-length floor guarantees the loop ends.
    var t: CGFloat = 0.02
    var dash: CGFloat = 0.075
    while t < 0.86, dash > 0.012 {
        context.addPath(strip(from: t, to: min(t + dash, 0.88), fraction: 0.05, steps: 16))
        context.fillPath()
        t += dash * 1.9
        dash *= 0.85
    }

    // Destination pin standing at the end of the road.
    let tip = centerline(1)
    let pin = pinPath(tip: CGPoint(x: tip.x, y: tip.y + 10), headRadius: 150)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: palette.shadow)
    context.setFillColor(palette.pin)
    context.addPath(pin)
    context.fillPath()
    context.restoreGState()

    let headCenter = CGPoint(x: tip.x, y: tip.y + 10 - 150 * 1.55)
    context.setFillColor(palette.pinDot)
    context.fillEllipse(in: CGRect(x: headCenter.x - 62, y: headCenter.y - 62, width: 124, height: 124))

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

for (file, palette) in palettes {
    let url = outputDirectory.appendingPathComponent(file)
    writePNG(render(palette, opaque: true), to: url)
    print("Wrote \(url.path)")
}
