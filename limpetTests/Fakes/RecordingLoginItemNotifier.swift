// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
@testable import limpet

public final class RecordingLoginItemNotifier: LoginItemNotifying, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _calls: Int = 0

    public init() {}

    public var calls: Int { lock.withLock { _calls } }

    public func notifyRequiresApproval() {
        lock.withLock { _calls += 1 }
    }
}
