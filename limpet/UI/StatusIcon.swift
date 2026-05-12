import SwiftUI

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

/// Compact menubar label: the shell icon with a small status dot in the
/// top-right corner so the user can tell at a glance whether the VPN is up.
struct MenuBarLabel: View {
    let state: ConnectionState

    var body: some View {
        Image(systemName: state.menuBarSystemImage)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(state.menuBarBadgeColor)
                    .frame(width: 6, height: 6)
                    .opacity(state.showsMenuBarBadge ? 1 : 0)
                    .offset(x: 2, y: -2)
            }
            .symbolEffect(.pulse, isActive: state == .connecting)
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
