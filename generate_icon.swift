#!/usr/bin/env swift

import AppKit
import Foundation

// Icon sizes needed for macOS app
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func createGhostIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let scale = CGFloat(size) / 1024.0

    // Background - rounded rectangle with gradient
    let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 40 * scale, dy: 40 * scale), xRadius: 180 * scale, yRadius: 180 * scale)

    // Gradient background (purple to blue - theme vibes)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1.0),
        NSColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1.0)
    ])!
    gradient.draw(in: bgPath, angle: -45)

    // Ghost body
    let ghostCenterX = CGFloat(size) / 2
    let ghostTop = CGFloat(size) * 0.18
    let ghostBottom = CGFloat(size) * 0.82
    let ghostWidth = CGFloat(size) * 0.55

    let ghostPath = NSBezierPath()

    // Start from bottom left wave
    let waveHeight = CGFloat(size) * 0.08
    let waveCount = 3
    let waveWidth = ghostWidth / CGFloat(waveCount)

    // Bottom wavy edge
    ghostPath.move(to: NSPoint(x: ghostCenterX - ghostWidth/2, y: ghostBottom - waveHeight))

    for i in 0..<waveCount {
        let startX = ghostCenterX - ghostWidth/2 + CGFloat(i) * waveWidth
        let midX = startX + waveWidth/2
        let endX = startX + waveWidth

        if i % 2 == 0 {
            ghostPath.curve(to: NSPoint(x: endX, y: ghostBottom - waveHeight),
                           controlPoint1: NSPoint(x: midX, y: ghostBottom + waveHeight),
                           controlPoint2: NSPoint(x: midX, y: ghostBottom + waveHeight))
        } else {
            ghostPath.curve(to: NSPoint(x: endX, y: ghostBottom - waveHeight),
                           controlPoint1: NSPoint(x: midX, y: ghostBottom - waveHeight * 2.5),
                           controlPoint2: NSPoint(x: midX, y: ghostBottom - waveHeight * 2.5))
        }
    }

    // Right side up
    ghostPath.line(to: NSPoint(x: ghostCenterX + ghostWidth/2, y: ghostTop + ghostWidth/2))

    // Top rounded part (head)
    ghostPath.curve(to: NSPoint(x: ghostCenterX - ghostWidth/2, y: ghostTop + ghostWidth/2),
                   controlPoint1: NSPoint(x: ghostCenterX + ghostWidth/2, y: ghostTop - ghostWidth * 0.1),
                   controlPoint2: NSPoint(x: ghostCenterX - ghostWidth/2, y: ghostTop - ghostWidth * 0.1))

    // Left side down
    ghostPath.line(to: NSPoint(x: ghostCenterX - ghostWidth/2, y: ghostBottom - waveHeight))

    ghostPath.close()

    // Ghost fill - white with slight transparency
    NSColor(white: 1.0, alpha: 0.95).setFill()
    ghostPath.fill()

    // Eyes
    let eyeRadius = CGFloat(size) * 0.055
    let eyeY = ghostTop + ghostWidth * 0.45
    let eyeSpacing = CGFloat(size) * 0.12

    // Left eye
    let leftEyePath = NSBezierPath(ovalIn: NSRect(
        x: ghostCenterX - eyeSpacing - eyeRadius,
        y: eyeY - eyeRadius,
        width: eyeRadius * 2,
        height: eyeRadius * 2
    ))
    NSColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1.0).setFill()
    leftEyePath.fill()

    // Right eye
    let rightEyePath = NSBezierPath(ovalIn: NSRect(
        x: ghostCenterX + eyeSpacing - eyeRadius,
        y: eyeY - eyeRadius,
        width: eyeRadius * 2,
        height: eyeRadius * 2
    ))
    rightEyePath.fill()

    // Small smile
    let smilePath = NSBezierPath()
    let smileY = eyeY - CGFloat(size) * 0.12
    let smileWidth = CGFloat(size) * 0.1
    smilePath.move(to: NSPoint(x: ghostCenterX - smileWidth/2, y: smileY))
    smilePath.curve(to: NSPoint(x: ghostCenterX + smileWidth/2, y: smileY),
                   controlPoint1: NSPoint(x: ghostCenterX - smileWidth/4, y: smileY - CGFloat(size) * 0.04),
                   controlPoint2: NSPoint(x: ghostCenterX + smileWidth/4, y: smileY - CGFloat(size) * 0.04))
    NSColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1.0).setStroke()
    smilePath.lineWidth = CGFloat(size) * 0.02
    smilePath.stroke()

    // Color swatches on the side (representing themes)
    let swatchSize = CGFloat(size) * 0.08
    let swatchX = ghostCenterX + ghostWidth/2 + swatchSize * 0.3
    let swatchColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0),
        NSColor(red: 0.4, green: 0.9, blue: 0.5, alpha: 1.0),
        NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0),
    ]

    for (i, color) in swatchColors.enumerated() {
        let swatchY = CGFloat(size) * 0.35 + CGFloat(i) * swatchSize * 1.3
        let swatchRect = NSRect(x: swatchX, y: swatchY, width: swatchSize, height: swatchSize)
        let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: swatchSize * 0.2, yRadius: swatchSize * 0.2)
        color.setFill()
        swatchPath.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Create Assets.xcassets/AppIcon.appiconset directory
let baseDir = FileManager.default.currentDirectoryPath
let appIconDir = "\(baseDir)/Assets.xcassets/AppIcon.appiconset"

try? FileManager.default.createDirectory(atPath: "\(baseDir)/Assets.xcassets", withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: appIconDir, withIntermediateDirectories: true)

// Generate icons at all sizes
var contentImages: [[String: Any]] = []

for size in sizes {
    let bitmap = createGhostIcon(size: size)

    // Save 1x version
    let filename = "icon_\(size)x\(size).png"
    let filepath = "\(appIconDir)/\(filename)"

    if let pngData = bitmap.representation(using: .png, properties: [:]) {
        try? pngData.write(to: URL(fileURLWithPath: filepath))
        print("Generated: \(filename)")
    }

    // Add to Contents.json
    let sizeStr = size <= 512 ? "\(size)x\(size)" : "512x512"
    let scaleStr = size == 1024 ? "2x" : "1x"

    if size == 16 {
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "1x", "size": "16x16"])
    } else if size == 32 {
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "2x", "size": "16x16"])
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "1x", "size": "32x32"])
    } else if size == 64 {
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "2x", "size": "32x32"])
    } else if size == 128 {
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "1x", "size": "128x128"])
    } else if size == 256 {
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "2x", "size": "128x128"])
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "1x", "size": "256x256"])
    } else if size == 512 {
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "2x", "size": "256x256"])
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "1x", "size": "512x512"])
    } else if size == 1024 {
        contentImages.append(["filename": filename, "idiom": "mac", "scale": "2x", "size": "512x512"])
    }
}

// Create Contents.json
let contents: [String: Any] = [
    "images": contentImages,
    "info": ["author": "xcode", "version": 1]
]

if let jsonData = try? JSONSerialization.data(withJSONObject: contents, options: .prettyPrinted) {
    try? jsonData.write(to: URL(fileURLWithPath: "\(appIconDir)/Contents.json"))
    print("Generated: Contents.json")
}

print("\nApp icon generated in Assets.xcassets/AppIcon.appiconset/")
