// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
@testable import limpet

public final class RecordingStateSink: StateSink, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _states: [ConnectionState] = []

    public init() {}

    public var states: [ConnectionState] {
        lock.withLock { _states }
    }

    public func update(_ state: ConnectionState) {
        lock.withLock { _states.append(state) }
    }
}

public final class StaticDesiredState: DesiredStateProviding, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _value: Bool

    public init(_ value: Bool) {
        _value = value
    }

    public var desiredOn: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
