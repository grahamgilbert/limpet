import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Bindable var appState: AppState
    @Bindable var preferences: Preferences
    @Bindable var trust: AccessibilityTrustWatcher
    let controller: VpnControlling
    let openPreferences: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyView()
                .onAppear { preferences.refreshLoginItemState() }
            HStack(spacing: 8) {
                StatusIcon(state: appState.connection)
                    .font(.title3)
                Text(appState.connection.menuLabel)
                    .font(.headline)
                Spacer()
            }

            if !trust.isTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility permission needed")
                        .font(.caption)
                        .foregroundStyle(.red)
                    HStack {
                        Button("Grant Permission") {
                            _ = AX.isProcessTrusted(prompt: true)
                        }
                        .controlSize(.small)
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }
            }

            if let err = appState.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("VPN On", isOn: Binding(
                get: {
                    switch appState.connection {
                    case .connected, .connecting: true
                    case .disconnected, .disabled, .unknown: false
                    }
                },
                set: { newValue in
                    preferences.desiredOn = newValue
                    Task {
                        do {
                            if newValue {
                                try await controller.connect()
                            } else {
                                try await controller.disconnect()
                            }
                        } catch {
                            await MainActor.run {
                                appState.lastError = "\(error)"
                            }
                        }
                    }
                }
            ))
            .toggleStyle(.switch)

            Divider()

            Button {
                openPreferences()
            } label: {
                HStack {
                    Text("Preferences…")
                    Spacer()
                    Text("⌘,").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Text("Quit limpet")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(14)
        .frame(width: 240)
    }
}
