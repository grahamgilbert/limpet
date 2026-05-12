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

    public init() {}

    public var calls: [Call] {
        lock.withLock { _calls }
    }

    public var connectCount: Int { calls.filter { $0 == .connect }.count }
    public var disconnectCount: Int { calls.filter { $0 == .disconnect }.count }

    public var failNext: Error? {
        get { lock.withLock { _failNext } }
        set { lock.withLock { _failNext = newValue } }
    }

    public func connect() async throws {
        let toThrow: Error? = lock.withLock {
            _calls.append(.connect)
            let e = _failNext
            _failNext = nil
            return e
        }
        if let toThrow { throw toThrow }
    }

    public func disconnect() async throws {
        let toThrow: Error? = lock.withLock {
            _calls.append(.disconnect)
            let e = _failNext
            _failNext = nil
            return e
        }
        if let toThrow { throw toThrow }
    }
}
