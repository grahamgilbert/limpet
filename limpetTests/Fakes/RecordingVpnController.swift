// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
@testable import limpet

public final class RecordingVpnController: VpnControlling, @unchecked Sendable {
    public enum Call: Equatable, Sendable {
        case connect
        case disconnect
    }

    private let lock = AsyncSafeLock()
    private var _calls: [Call] = []
    private var _failNext: Error?
    private var _refreshFallbacks: [Bool] = []
    /// Makes the call actually suspend. Needed to open the actor-reentrancy
    /// window that an instantly-returning fake hides.
    private let delay: Duration

    public init(delay: Duration = .zero) {
        self.delay = delay
    }

    public var calls: [Call] {
        lock.withLock { _calls }
    }

    public var connectCount: Int { calls.filter { $0 == .connect }.count }
    public var disconnectCount: Int { calls.filter { $0 == .disconnect }.count }

    /// `allowRefreshFallback` as passed to each `connect`, in order. "Refresh
    /// Connection" tears down a session that is merely mid-connect, so which
    /// calls opt in is behaviour worth asserting on.
    public var refreshFallbacks: [Bool] { lock.withLock { _refreshFallbacks } }

    public var failNext: Error? {
        get { lock.withLock { _failNext } }
        set { lock.withLock { _failNext = newValue } }
    }

    public func connect(allowRefreshFallback: Bool) async throws {
        let toThrow: Error? = lock.withLock {
            _calls.append(.connect)
            _refreshFallbacks.append(allowRefreshFallback)
            let e = _failNext
            _failNext = nil
            return e
        }
        if delay != .zero { try? await Task.sleep(for: delay) }
        if let toThrow { throw toThrow }
    }

    public func disconnect() async throws {
        let toThrow: Error? = lock.withLock {
            _calls.append(.disconnect)
            let e = _failNext
            _failNext = nil
            return e
        }
        if delay != .zero { try? await Task.sleep(for: delay) }
        if let toThrow { throw toThrow }
    }
}
