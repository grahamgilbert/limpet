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
