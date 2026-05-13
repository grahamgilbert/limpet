// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
@testable import limpet

public final class RecordingLoginItemNotifier: AppNotifying, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _approvalCalls: Int = 0
    private var _signatureInvalidCalls: Int = 0

    public init() {}

    public var approvalCalls: Int { lock.withLock { _approvalCalls } }
    public var signatureInvalidCalls: Int { lock.withLock { _signatureInvalidCalls } }
    /// Legacy accessor for tests that only care about approval notifications.
    public var calls: Int { approvalCalls }

    public func notifyRequiresApproval() {
        lock.withLock { _approvalCalls += 1 }
    }

    public func notifyGlobalProtectSignatureInvalid() {
        lock.withLock { _signatureInvalidCalls += 1 }
    }
}
