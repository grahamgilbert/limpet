#!/usr/bin/env swift
//
// Render fossil.shell into a macOS app icon set.
//
// We deliberately use NSBitmapImageRep so the output PNG dimensions are
// **exact pixels**, not points — `NSImage(size:flipped:drawingHandler:)`
// resolves at the device's backing-scale and produces 2x bitmaps when run
// on a Retina display.
//
// Run from repo root:
//   swift scripts/generate_app_icon.swift

import AppKit

let dest = URL(fileURLWithPath: "limpet/Resources/Assets.xcassets/AppIcon.appiconset")

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",     128),
    ("icon_128x128@2x",  256),
    ("icon_256x256",     256),
    ("icon_256x256@2x",  512),
    ("icon_512x512",     512),
    ("icon_512x512@2x",  1024),
]

func makeIcon(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Couldn't allocate bitmap rep at \(pixels)x\(pixels)")
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)

    // Squircle clip + opaque teal-blue gradient. Fully opaque so the icon
    // reads on any background (light or dark mode).
    let bgPath = NSBezierPath(
        roundedRect: rect,
        xRadius: CGFloat(pixels) * 0.225,
        yRadius: CGFloat(pixels) * 0.225
    )
    bgPath.addClip()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.20, green: 0.55, blue: 0.78, alpha: 1.0),  // surface — sky
        NSColor(red: 0.06, green: 0.20, blue: 0.36, alpha: 1.0),  // depth  — abyss
    ])!
    gradient.draw(in: rect, angle: -90)

    // Render the SF Symbol on top in white. Preserve aspect ratio — the
    // fossil.shell symbol is wider than tall, so a naive draw(in: square)
    // stretches it vertically.
    let inset = CGFloat(pixels) * 0.18
    let symbolBox = rect.insetBy(dx: inset, dy: inset)
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.6, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "fossil.shell", accessibilityDescription: nil)?
        .withSymbolConfiguration(config),
       let tinted = symbol.copy() as? NSImage {
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let nat = tinted.size
        let scale = min(symbolBox.width / nat.width, symbolBox.height / nat.height)
        let drawSize = NSSize(width: nat.width * scale, height: nat.height * scale)
        let drawRect = NSRect(
            x: symbolBox.midX - drawSize.width / 2,
            y: symbolBox.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG: \(url.lastPathComponent)")
    }
    try png.write(to: url)
}

// Wipe stale PNGs so renames take effect.
let fm = FileManager.default
for case let file as URL in (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "png" {
    try? fm.removeItem(at: file)
}

for (name, pixels) in sizes {
    let rep = makeIcon(pixels: pixels)
    let url = dest.appendingPathComponent("\(name).png")
    try writePNG(rep, to: url)
    print("✓ \(name).png (\(pixels)x\(pixels))")
}

let contents = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(to: dest.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("✓ Contents.json")
