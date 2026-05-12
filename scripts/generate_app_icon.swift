#!/usr/bin/env swift
//
// Render fossil.shell into a macOS app icon set.
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

func makeIcon(pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: size)
    let bgPath = NSBezierPath(roundedRect: rect,
                              xRadius: CGFloat(pixels) * 0.225,
                              yRadius: CGFloat(pixels) * 0.225)
    bgPath.addClip()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.14, green: 0.42, blue: 0.55, alpha: 1.0),
        NSColor(red: 0.05, green: 0.18, blue: 0.30, alpha: 1.0),
    ])!
    gradient.draw(in: rect, angle: -90)

    let inset = CGFloat(pixels) * 0.16
    let symbolRect = rect.insetBy(dx: inset, dy: inset)
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.6, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "fossil.shell", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        if let tinted = symbol.copy() as? NSImage {
            tinted.lockFocus()
            NSColor.white.set()
            let imgRect = NSRect(origin: .zero, size: tinted.size)
            imgRect.fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG: \(url.lastPathComponent)")
    }
    try png.write(to: url)
}

for (name, pixels) in sizes {
    let icon = makeIcon(pixels: pixels)
    let url = dest.appendingPathComponent("\(name).png")
    try writePNG(icon, to: url)
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
