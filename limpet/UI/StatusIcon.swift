// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import SwiftUI
import AppKit

struct StatusIcon: View {
    let state: ConnectionState
    var activity: VPNToggleState.Activity?

    var body: some View {
        Image(systemName: state.menuBarSystemImage)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: activity != nil)
    }

    private var tint: Color {
        if activity != nil { return ConnectionState.connecting.menuBarBadgeColor }
        return switch state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        case .disabled: .gray
        case .unknown: .secondary
        }
    }
}

/// Compact menubar label.
///
/// We render the shell icon as a template image so macOS handles the
/// black-on-light / white-on-dark inversion automatically, then composite
/// a coloured status dot on top as a non-template overlay so the colour
/// survives the templating step.
struct MenuBarLabel: View {
    let state: ConnectionState
    var activity: VPNToggleState.Activity?

    /// Blink phase, driven externally: a `TimelineView` inside a MenuBarExtra
    /// label makes SwiftUI rebuild the status button in a tight loop (95% CPU).
    var dim = false

    var body: some View {
        Image(nsImage: renderMenuBarImage(state: state, activity: activity, dim: activity != nil && dim))
    }
}

private func renderMenuBarImage(state: ConnectionState, activity: VPNToggleState.Activity?, dim: Bool) -> NSImage {
    // Render the SF Symbol at its natural size to avoid the menubar squashing
    // a non-square canvas. We draw both the symbol and the dot inside that
    // square; the dot lives in the top-right of the symbol bounds.
    let pointSize: CGFloat = 18
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let baseSymbol = NSImage(systemSymbolName: state.menuBarSystemImage, accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) else {
        return NSImage()
    }
    let symbolSize = baseSymbol.size

    let image = NSImage(size: symbolSize, flipped: false) { _ in
        // labelColor adapts to the menubar's appearance at draw time.
        if let tinted = baseSymbol.copy() as? NSImage {
            tinted.lockFocus()
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(origin: .zero, size: symbolSize),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0)
        }

        if activity != nil || state.showsMenuBarBadge {
            let dotSize: CGFloat = 6
            let dotRect = NSRect(
                x: symbolSize.width - dotSize,
                y: symbolSize.height - dotSize,
                width: dotSize,
                height: dotSize
            )
            let color = activity != nil ? ConnectionState.connecting.menuBarBadgeNSColor : state.menuBarBadgeNSColor
            color.withAlphaComponent(dim ? 0.2 : 1).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

extension ConnectionState {
    var menuBarBadgeNSColor: NSColor {
        switch self {
        case .connected: .systemGreen
        case .connecting: .systemYellow
        case .disconnected: .systemRed
        case .disabled, .unknown: .systemGray
        }
    }
}

extension ConnectionState {
    var menuBarBadgeColor: Color {
        switch self {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        case .disabled, .unknown: .gray
        }
    }

    var showsMenuBarBadge: Bool {
        switch self {
        case .connected, .connecting, .disconnected, .disabled: true
        case .unknown: false
        }
    }
}

extension ConnectionState {
    var menuLabel: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case .disabled: "GlobalProtect disabled"
        case .unknown: "Status unknown"
        }
    }

    var menuBarSystemImage: String {
        "fossil.shell"
    }
}
