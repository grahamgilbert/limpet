import Foundation
@testable import limpet

public final class FakeLoginItem: LoginItemRegistering, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _registered: Bool = false
    private var _failOnRegister: Error?
    private var _failOnUnregister: Error?

    public init(initiallyRegistered: Bool = false) {
        _registered = initiallyRegistered
    }

    public var isRegistered: Bool {
        lock.withLock { _registered }
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
        lock.withLock { _registered = true }
    }

    public func unregister() throws {
        let toThrow: Error? = lock.withLock { _failOnUnregister }
        if let toThrow { throw toThrow }
        lock.withLock { _registered = false }
    }
}

public struct FakeError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
