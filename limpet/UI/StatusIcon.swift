import SwiftUI
import AppKit

struct StatusIcon: View {
    let state: ConnectionState

    var body: some View {
        Image(systemName: state.menuBarSystemImage)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: state == .connecting)
    }

    private var tint: Color {
        switch state {
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

    var body: some View {
        Image(nsImage: renderMenuBarImage(state: state))
    }
}

private func renderMenuBarImage(state: ConnectionState) -> NSImage {
    let pointSize: CGFloat = 18
    let canvas = NSSize(width: pointSize + 4, height: pointSize)
    let image = NSImage(size: canvas, flipped: false) { _ in
        // The drawing handler runs with the destination's NSAppearance set,
        // so NSColor.labelColor here resolves to white on a dark menubar
        // and black on a light menubar. That's exactly what we need.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let symbol = NSImage(systemSymbolName: state.menuBarSystemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig),
           let tinted = symbol.copy() as? NSImage {
            tinted.lockFocus()
            NSColor.labelColor.set()
            let r = NSRect(origin: .zero, size: tinted.size)
            r.fill(using: .sourceAtop)
            tinted.unlockFocus()
            let symbolRect = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
            tinted.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        if state.showsMenuBarBadge {
            let dotSize: CGFloat = 6
            let dotRect = NSRect(
                x: canvas.width - dotSize - 0.5,
                y: canvas.height - dotSize - 0.5,
                width: dotSize,
                height: dotSize
            )
            state.menuBarBadgeNSColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
        return true
    }
    // Non-template so colour survives.
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
