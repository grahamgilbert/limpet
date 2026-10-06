// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Observation

@MainActor
@Observable
public final class AppState: StateSink {
    public var connection: ConnectionState
    public var lastError: String?
    /// Set while the watchdog is mid-connect; drives the menu bar spinner.
    public var isReconnecting = false
    /// Blink phase for the menu bar dot while `activity` is non-nil.
    var blinkDim = false
    // swiftlint:disable discouraged_optional_boolean
    /// The user's optimistic intent while a manual connect/disconnect is in
    /// flight; nil when none is. Three-state on purpose.
    public var pendingDesiredOn: Bool?
    // swiftlint:enable discouraged_optional_boolean

    var toggleState: VPNToggleState {
        VPNToggleState(pendingDesiredOn: pendingDesiredOn, connection: connection, isReconnecting: isReconnecting)
    }

    var activity: VPNToggleState.Activity? { toggleState.activity }

    @ObservationIgnored private var blinkTask: Task<Void, Never>?

    /// Runs the 2 Hz blink only while `activity` is non-nil. A TimelineView in
    /// the MenuBarExtra label spins SwiftUI at 95% CPU, so the phase is driven
    /// from here instead; idle costs nothing.
    func trackBlink() {
        withObservationTracking {
            _ = activity
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncBlink()
                self?.trackBlink()
            }
        }
        syncBlink()
    }

    private func syncBlink() {
        if activity == nil {
            blinkTask?.cancel()
            blinkTask = nil
            blinkDim = false
        } else if blinkTask == nil {
            blinkTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    blinkDim.toggle()
                }
            }
        }
    }

    public init(connection: ConnectionState = .unknown) {
        self.connection = connection
    }

    public nonisolated func update(_ state: ConnectionState) {
        Task { @MainActor in
            // @Observable fires on every assignment, equal or not, and the
            // watchdog re-reports the current state on a timer. Skip no-op
            // writes so the menu bar isn't invalidated every tick.
            guard self.connection != state else { return }
            self.connection = state
        }
    }

    public nonisolated func setReconnecting(_ reconnecting: Bool) {
        Task { @MainActor in
            guard self.isReconnecting != reconnecting else { return }
            self.isReconnecting = reconnecting
        }
    }
}
