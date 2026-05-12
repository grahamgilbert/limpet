import Foundation

/// A tiny scoped wrapper around `NSLock` that's safe to call from async
/// contexts (Swift 6 forbids bare `lock()`/`unlock()` calls in async funcs).
public final class AsyncSafeLock: @unchecked Sendable {
    private let _lock = NSLock()
    public init() {}

    public func withLock<R>(_ body: () -> R) -> R {
        _lock.lock()
        defer { _lock.unlock() }
        return body()
    }
}
