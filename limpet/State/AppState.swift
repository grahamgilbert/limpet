// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Observation

@MainActor
@Observable
public final class AppState: StateSink {
    public var connection: ConnectionState
    public var lastError: String?

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
}
