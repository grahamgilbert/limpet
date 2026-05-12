// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
@testable import limpet

public final class FakeWindowProvider: WindowProvider, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _windows: [PopupWindow] = []
    private var _pressCount: Int = 0

    public init() {}

    public var pressCount: Int {
        lock.withLock { _pressCount }
    }

    public func setWindows(_ windows: [PopupWindow]) {
        lock.withLock { _windows = windows }
    }

    public func currentWindows() -> [PopupWindow] {
        lock.withLock { _windows }
    }

    public final class WindowCounter: @unchecked Sendable {
        private let lock = AsyncSafeLock()
        private var _pressed: Int = 0
        public init() {}
        public var pressed: Int { lock.withLock { _pressed } }
        public func increment() { lock.withLock { _pressed += 1 } }
    }
}
