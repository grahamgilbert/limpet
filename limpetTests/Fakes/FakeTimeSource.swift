import Foundation
@testable import limpet

/// Manually-advanced clock. `sleep(for:)` returns immediately; tests advance
/// `now()` explicitly via `advance(by:)`.
public final class FakeTimeSource: TimeSource, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    public func now() -> Date {
        lock.withLock { current }
    }

    public func sleep(for duration: Duration) async throws {
        await Task.yield()
    }

    public func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    public func advance(by duration: Duration) {
        let comps = duration.components
        let secs = TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
        advance(by: secs)
    }
}
