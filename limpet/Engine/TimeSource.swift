// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation

/// Indirection over wall-clock time and sleep so tests can advance time
/// without actually waiting. Named `TimeSource` to avoid colliding with
/// stdlib `Clock`.
public protocol TimeSource: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemTimeSource: TimeSource {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
