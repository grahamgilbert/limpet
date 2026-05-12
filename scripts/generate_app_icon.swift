#!/usr/bin/env swift
//
// Render fossil.shell into a macOS app icon set with separate light and
// dark appearance variants.
//
// Run from repo root:
//   swift scripts/generate_app_icon.swift

import AppKit

let dest = URL(fileURLWithPath: "limpet/Resources/Assets.xcassets/AppIcon.appiconset")

enum Appearance {
    case dark, light

    var suffix: String {
        switch self {
        case .dark: "_dark"
        case .light: "_light"
        }
    }

    var bgGradient: [NSColor] {
        switch self {
        case .dark:
            return [
                NSColor(red: 0.14, green: 0.42, blue: 0.55, alpha: 1.0),
                NSColor(red: 0.05, green: 0.18, blue: 0.30, alpha: 1.0),
            ]
        case .light:
            return [
                NSColor(red: 0.62, green: 0.86, blue: 0.94, alpha: 1.0),
                NSColor(red: 0.32, green: 0.66, blue: 0.82, alpha: 1.0),
            ]
        }
    }

    /// Symbol fill colour — choose the value that contrasts most with the
    /// background.
    var foreground: NSColor {
        switch self {
        case .dark: .white
        case .light: NSColor(white: 0.10, alpha: 1.0)
        }
    }
}

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

func makeIcon(pixels: Int, appearance: Appearance) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: size)
    let bgPath = NSBezierPath(roundedRect: rect,
                              xRadius: CGFloat(pixels) * 0.225,
                              yRadius: CGFloat(pixels) * 0.225)
    bgPath.addClip()

    if let gradient = NSGradient(colors: appearance.bgGradient) {
        gradient.draw(in: rect, angle: -90)
    }

    let inset = CGFloat(pixels) * 0.16
    let symbolRect = rect.insetBy(dx: inset, dy: inset)
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.6, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "fossil.shell", accessibilityDescription: nil)?
        .withSymbolConfiguration(config),
       let tinted = symbol.copy() as? NSImage {
        tinted.lockFocus()
        appearance.foreground.set()
        let imgRect = NSRect(origin: .zero, size: tinted.size)
        imgRect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
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

// Wipe any old PNGs so renames take effect cleanly.
let fm = FileManager.default
for case let file as URL in (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "png" {
    try? fm.removeItem(at: file)
}

for appearance in [Appearance.dark, .light] {
    for (name, pixels) in sizes {
        let icon = makeIcon(pixels: pixels, appearance: appearance)
        let url = dest.appendingPathComponent("\(name)\(appearance.suffix).png")
        try writePNG(icon, to: url)
        print("✓ \(name)\(appearance.suffix).png (\(pixels)x\(pixels))")
    }
}

func contentsEntry(name: String, scale: String, size: String, appearance: Appearance) -> String {
    let appearanceJSON: String
    switch appearance {
    case .dark:
        appearanceJSON = """
        ,
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ]
"""
    case .light:
        // Default (no appearances key) — used when the system asks for light or
        // when no specific appearance match is requested.
        appearanceJSON = ""
    }
    return """
    {
      "idiom" : "mac",
      "scale" : "\(scale)",
      "size" : "\(size)",
      "filename" : "\(name)\(appearance.suffix).png"\(appearanceJSON)
    }
"""
}

var entries: [String] = []
for (name, _) in sizes {
    let parts = name.replacingOccurrences(of: "icon_", with: "")
    let pieces = parts.split(separator: "@")
    let dim = String(pieces[0])
    let scale = pieces.count > 1 ? String(pieces[1]).replacingOccurrences(of: "x", with: "") + "x" : "1x"
    for appearance in [Appearance.light, .dark] {
        entries.append(contentsEntry(name: name, scale: scale, size: dim, appearance: appearance))
    }
}

let contentsJSON = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contentsJSON.write(to: dest.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("✓ Contents.json")
