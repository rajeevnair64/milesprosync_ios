#!/usr/bin/env swift
// Packages the approved M-road-and-car artwork as opaque 1024px app icons.
// Run from the project root: swift scripts/generate-app-icon.swift
// Source artwork is retained locally so regeneration never restores the old pin design.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sourceDirectory = URL(fileURLWithPath: "scripts/app-icon-source")
let outputDirectory = URL(fileURLWithPath: "MilesProSync/Assets.xcassets/AppIcon.appiconset")
let size = 1024
for name in ["AppIcon.png", "AppIcon-Dark.png", "AppIcon-Tinted.png"] {
    let sourceURL = sourceDirectory.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { fatalError("Cannot load icon source: \(name)") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let output = outputDirectory.appendingPathComponent(name)
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot create icon: \(name)") }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save icon: \(name)") }
    print("Wrote \(output.path)")
}
