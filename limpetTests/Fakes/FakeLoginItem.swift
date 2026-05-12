// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
@testable import limpet

public final class FakeLoginItem: LoginItemRegistering, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _status: LoginItemStatus
    private var _failOnRegister: Error?
    private var _failOnUnregister: Error?

    public init(initiallyRegistered: Bool = false) {
        _status = initiallyRegistered ? .enabled : .notRegistered
    }

    public init(initialStatus: LoginItemStatus) {
        _status = initialStatus
    }

    public var isRegistered: Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound, .unknown: false
        }
    }

    public var status: LoginItemStatus {
        lock.withLock { _status }
    }

    public func setStatus(_ value: LoginItemStatus) {
        lock.withLock { _status = value }
    }

    public var failOnRegister: Error? {
        get { lock.withLock { _failOnRegister } }
        set { lock.withLock { _failOnRegister = newValue } }
    }

    public var failOnUnregister: Error? {
        get { lock.withLock { _failOnUnregister } }
        set { lock.withLock { _failOnUnregister = newValue } }
    }

    public func register() throws {
        let toThrow: Error? = lock.withLock { _failOnRegister }
        if let toThrow { throw toThrow }
        lock.withLock { _status = .enabled }
    }

    public func unregister() throws {
        let toThrow: Error? = lock.withLock { _failOnUnregister }
        if let toThrow { throw toThrow }
        lock.withLock { _status = .notRegistered }
    }
}

public struct FakeError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
