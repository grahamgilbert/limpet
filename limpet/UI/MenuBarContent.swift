// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import SwiftUI
import AppKit

/// Pure presentation logic for the VPN toggle row, factored out of the SwiftUI
/// view so it can be unit-tested without instantiating the view.
struct VPNToggleState: Equatable {
    // swiftlint:disable discouraged_optional_boolean
    /// The user's optimistic intent while a manual connect/disconnect is in
    /// flight; `nil` when no manual action is pending.
    let pendingDesiredOn: Bool?
    // swiftlint:enable discouraged_optional_boolean
    let connection: ConnectionState
    /// True while the watchdog is driving a connect (GP may still say disconnected).
    var isReconnecting = false

    /// Whether the connection counts as "on" for the toggle's real state.
    var connectionIsOn: Bool {
        switch connection {
        case .connected, .connecting: true
        case .disconnected, .disabled, .unknown: false
        }
    }

    /// The toggle position to display: optimistic intent wins over reality
    /// until reality catches up or the pending action times out.
    var displayedOn: Bool { pendingDesiredOn ?? connectionIsOn }

    /// Whether to show the inline spinner: either a manual action is in flight,
    /// or GP is actively connecting (e.g. a watchdog-driven reconnect, which has
    /// no pending manual intent but should still show progress).
    var isPending: Bool { activity != nil }

    enum Activity {
        case connecting, disconnecting

        var label: String {
            switch self {
            case .connecting: ConnectionState.connecting.menuLabel
            case .disconnecting: "Disconnecting…"
            }
        }
    }

    /// What is happening right now, if anything; takes precedence over the
    /// settled `connection` state in every status display.
    var activity: Activity? {
        if pendingDesiredOn == false { return .disconnecting }
        if pendingDesiredOn == true || connection == .connecting || isReconnecting { return .connecting }
        return nil
    }
}

struct MenuBarContent: View {
    @Bindable var appState: AppState
    @Bindable var preferences: Preferences
    @Bindable var trust: AccessibilityTrustWatcher
    let controller: VpnControlling
    let cancelReconnect: @Sendable () async -> Void
    let openPreferences: () -> Void

    // While a connect/disconnect action is in flight we display the user's
    // intent immediately and show a spinner. The optimistic value wins
    // over the real state until either reality matches the intent or the
    // timeout fires. nil = no action in flight; the three-state distinction
    // is deliberate, so silence SwiftLint here.
    // Lives on AppState so the menu bar icon can show it too.
    // swiftlint:disable:next discouraged_optional_boolean
    private var pendingDesiredOn: Bool? {
        get { appState.pendingDesiredOn }
        nonmutating set { appState.pendingDesiredOn = newValue }
    }
    @State private var pendingTask: Task<Void, Never>?

    private var toggleState: VPNToggleState {
        appState.toggleState
    }

    private var connectionIsOn: Bool { toggleState.connectionIsOn }

    private var displayedToggle: Bool { toggleState.displayedOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyView()
                .onAppear { preferences.refreshLoginItemState() }
            HStack(spacing: 8) {
                StatusIcon(state: appState.connection, activity: toggleState.activity)
                    .font(.title3)
                Text(toggleState.activity?.label ?? appState.connection.menuLabel)
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

            if preferences.loginItemNeedsAttention {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Login Items approval needed")
                            .font(.caption.bold())
                    }
                    Text("Approve limpet in System Settings so it launches at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items Settings") {
                        openLoginItemsSettings()
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            VPNToggleRow(
                displayedOn: displayedToggle,
                isPending: toggleState.isPending,
                onChangeRequested: setDesired,
                onCancel: {
                    // desiredOn first, or the watchdog restarts the attempt.
                    setDesired(false)
                    Task { await cancelReconnect() }
                }
            )
            .onChange(of: connectionIsOn) { _, newValue in
                if let pending = pendingDesiredOn, pending == newValue {
                    pendingDesiredOn = nil
                    pendingTask?.cancel()
                    pendingTask = nil
                }
                clearErrorIfSatisfied(current: newValue)
            }
            .onAppear {
                // If the menu reopens after reality caught up while it was
                // closed, sync the optimistic state.
                if let pending = pendingDesiredOn, pending == connectionIsOn {
                    pendingDesiredOn = nil
                    pendingTask?.cancel()
                    pendingTask = nil
                }
                clearErrorIfSatisfied(current: connectionIsOn)
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
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("VPN On", isOn: Binding(
                get: { displayedOn },
                set: { onChangeRequested($0) }
            ))
            .toggleStyle(.switch)
            // Mid-operation the toggle would race the in-flight AX action; the
            // cancel button is the way out.
            .disabled(isPending)

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel")
            }
        }
    }
}

extension MenuBarContent {
    fileprivate func clearErrorIfSatisfied(current: Bool) {
        if current == preferences.desiredOn {
            appState.lastError = nil
        }
    }

    fileprivate func setDesired(_ newValue: Bool) {
        preferences.desiredOn = newValue
        triggerToggle(to: newValue)
    }

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
            } catch is CancellationError {
                // Superseded by a newer action, which owns the pending state now.
                return
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
