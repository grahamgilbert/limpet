import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Bindable var appState: AppState
    @Bindable var preferences: Preferences
    @Bindable var trust: AccessibilityTrustWatcher
    let controller: VpnControlling
    let openPreferences: () -> Void

    // While a connect/disconnect action is in flight we display the user's
    // intent immediately and show a spinner. The optimistic value wins
    // over the real state until either reality matches the intent or the
    // timeout fires. nil = no action in flight; the three-state distinction
    // is deliberate, so silence SwiftLint here.
    // swiftlint:disable:next discouraged_optional_boolean
    @State private var pendingDesiredOn: Bool?
    @State private var pendingTask: Task<Void, Never>?

    private var connectionIsOn: Bool {
        switch appState.connection {
        case .connected, .connecting: true
        case .disconnected, .disabled, .unknown: false
        }
    }

    private var displayedToggle: Bool {
        pendingDesiredOn ?? connectionIsOn
    }

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

            VPNToggleRow(
                displayedOn: displayedToggle,
                isPending: pendingDesiredOn != nil,
                onChangeRequested: { newValue in
                    preferences.desiredOn = newValue
                    triggerToggle(to: newValue)
                }
            )
            .onChange(of: connectionIsOn) { _, newValue in
                if let pending = pendingDesiredOn, pending == newValue {
                    pendingDesiredOn = nil
                    pendingTask?.cancel()
                    pendingTask = nil
                }
            }
            .onAppear {
                // If the menu reopens after reality caught up while it was
                // closed, sync the optimistic state.
                if let pending = pendingDesiredOn, pending == connectionIsOn {
                    pendingDesiredOn = nil
                    pendingTask?.cancel()
                    pendingTask = nil
                }
            }

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

/// Toggle row extracted into its own view so SwiftUI tracks its inputs
/// (`displayedOn`, `isPending`) as plain value-type props and re-renders
/// reliably when either changes.
private struct VPNToggleRow: View {
    let displayedOn: Bool
    let isPending: Bool
    let onChangeRequested: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("VPN On", isOn: Binding(
                get: { displayedOn },
                set: { onChangeRequested($0) }
            ))
            .toggleStyle(.switch)

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
    }
}

extension MenuBarContent {
    fileprivate func triggerToggle(to newValue: Bool) {
        appState.lastError = nil
        pendingTask?.cancel()
        pendingDesiredOn = newValue

        pendingTask = Task { @MainActor in
            do {
                if newValue {
                    try await controller.connect()
                } else {
                    try await controller.disconnect()
                }
            } catch {
                appState.lastError = "\(error)"
                pendingDesiredOn = nil
                return
            }
            // Hard timeout: if the watchdog/log monitor doesn't reflect the
            // change in 30 s, give up the optimistic state so the toggle
            // doesn't get stuck.
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                pendingDesiredOn = nil
            }
        }
    }
}
