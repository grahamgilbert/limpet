// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Testing
@testable import limpet

@Suite("VpnStatusMonitor — log tailer + rotation")
struct VpnStatusMonitorTests {
    @Test("seeds with the most recent state already present in the file")
    func seedsFromExistingFile() async throws {
        let path = try makeTempLog(contents: """
        P 967 NetworkConnectionMonitorThread: m_state = 0, …
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let monitor = VpnStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .milliseconds(50))
        let first = try await firstValue(from: monitor.stream, timeout: .seconds(2))
        #expect(first == .connected)
    }

    @Test("appended lines produce stream events on transitions only")
    func appendedLinesEmitTransitions() async throws {
        // Start with a file that has a connected line so the seeder yields .connected.
        let path = try makeTempLog(contents: """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let monitor = VpnStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .milliseconds(50))
        let collected = collectStates(from: monitor.stream, max: 3, timeout: .seconds(3))

        // After init, append a transition to disconnected, then to retry, then back to connected.
        try await Task.sleep(for: .milliseconds(150))
        try append(to: path, """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.

        """)
        try await Task.sleep(for: .milliseconds(200))
        try append(to: path, """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 1.

        """)
        try await Task.sleep(for: .milliseconds(200))
        try append(to: path, """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)

        let states = await collected.value
        #expect(states.first == .connected)
        #expect(states.contains(.disconnected))
        // The duplicate disconnected line should be deduped — there should be at most one .disconnected.
        #expect(states.filter { $0 == .disconnected }.count == 1)
    }

    @Test("log rotation: rename original, recreate new file, monitor follows")
    func rotation() async throws {
        let path = try makeTempLog(contents: """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let monitor = VpnStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .milliseconds(50))
        let collected = collectStates(from: monitor.stream, max: 2, timeout: .seconds(3))

        try await Task.sleep(for: .milliseconds(200))
        // Rotate: rename, write fresh file with a different state.
        let rotated = path + ".1"
        try FileManager.default.moveItem(atPath: path, toPath: rotated)
        defer { try? FileManager.default.removeItem(atPath: rotated) }
        try """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 1.

        """.write(toFile: path, atomically: true, encoding: .utf8)

        let states = await collected.value
        #expect(states.first == .connected)
        #expect(states.contains(.connecting))
    }

    @Test("a backlog written in one burst emits only its final state")
    func backlogEmitsOnlyFinalState() async throws {
        // Wake-from-sleep: limpet's loop was parked while GP kept logging, so a
        // single wakeup reads many transitions at once. Only the last is current.
        let path = try makeTempLog(contents: """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let monitor = VpnStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .milliseconds(50))
        let collected = collectStates(from: monitor.stream, max: 2, timeout: .seconds(3))

        try await Task.sleep(for: .milliseconds(150))
        // One write: dropped, then retrying. The drop is already history.
        try append(to: path, """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 1.

        """)

        let states = await collected.value
        #expect(states == [.connected, .connecting])
        #expect(!states.contains(.disconnected), "stale .disconnected would trigger a spurious reconnect click")
    }

    @Test("atomic rotation (replacement inode already present) rebinds the file source")
    func atomicRotationRebindsSource() async throws {
        let path = try makeTempLog(contents: """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Long safety poll so only a correctly-rebound DispatchSource — not the
        // poll backstop — can surface post-rotation writes within the window.
        let monitor = VpnStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .seconds(30))
        let collected = collectStates(from: monitor.stream, max: 3, timeout: .seconds(4))

        try await Task.sleep(for: .milliseconds(200))
        // Atomic rotation: one atomic write swaps in a brand-new inode, so a
        // before/after inode bracket around the read would see no change.
        try """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 1.

        """.write(toFile: path, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        // Append to the NEW inode — only a rebound source wakes us before poll.
        try append(to: path, """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.

        """)

        let states = await collected.value
        #expect(states.first == .connected)
        #expect(states.contains(.connecting))
        #expect(states.contains(.disconnected))
    }

    @Test("stays idle (no busy loop) when the log is quiescent after seeding")
    func quiescentLogDoesNotBusyLoop() async throws {
        // A connected line, then no further writes. A regression to the
        // cancel-a-live-AsyncStream-iterator pattern would spin the loop and
        // call the safety-poll sleep thousands of times in this window; a
        // healthy loop calls it ~(window / interval) times.
        let path = try makeTempLog(contents: """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let clock = CountingTimeSource(interval: .milliseconds(20))
        let monitor = VpnStatusMonitor(path: path, time: clock, pollInterval: .milliseconds(20))
        let collector = Task { for await _ in monitor.stream {} }
        defer { collector.cancel() }

        try await Task.sleep(for: .milliseconds(400))
        let ticks = clock.count
        // ~20 expected for a 400ms window at 20ms; allow generous slack.
        // Anything in the hundreds/thousands means the loop is spinning.
        #expect(ticks < 100, "safety-poll fired \(ticks) times — loop is busy-looping")
    }

    @Test("emits .unknown when the path is unreadable at startup")
    func unreadablePathEmitsUnknown() async throws {
        let bogus = "/tmp/limpet-nonexistent-\(UUID().uuidString).log"
        let monitor = VpnStatusMonitor(path: bogus, time: SystemTimeSource(), pollInterval: .milliseconds(50))
        let first = try await firstValue(from: monitor.stream, timeout: .seconds(1))
        #expect(first == .unknown)
    }

    // MARK: LogReader unit tests

    @Test("line split across two reads is parsed correctly")
    func splitLineAcrossReads() throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        var reader = LogReader(path: path)

        // Write the first half of a state line (no newline yet).
        let fullLine = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.\n"
        let splitAt = fullLine.utf8.count / 2
        let utf8 = fullLine.utf8
        let part1 = Data(utf8.prefix(splitAt))
        let part2 = Data(utf8.dropFirst(splitAt))

        try writeRaw(to: path, data: part1)
        let states1 = reader.consumeAppended()
        #expect(states1.isEmpty, "no complete line yet — nothing should be emitted")

        try writeRaw(to: path, data: part2)
        let states2 = reader.consumeAppended()
        #expect(states2 == [.connected], "complete line now spans both reads")
    }

    @Test("seedFromExistingFile advances the handle so pre-seed writes are not replayed")
    func seedAdvancesHandlePastPreSeedWrites() throws {
        let connected = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.\n"
        let path = try makeTempLog(contents: connected)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // The handle seeks to EOF at init (T0). Simulate GP writing a drop+recover
        // that resolves before the seed runs (the [T0, T1] window).
        var reader = LogReader(path: path)
        try append(to: path, """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 1.
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)

        #expect(reader.seedFromExistingFile() == .connected)
        // Those already-resolved transitions must not be replayed as fresh states.
        #expect(reader.consumeAppended().isEmpty)
    }

    @Test("oversized carry is dropped and sync resumes at next newline")
    func carryCapDropsOversizedBuffer() throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        var reader = LogReader(path: path)

        // Write 70 KB of garbage with no newline — should bloat carry past 65 000 bytes.
        let junk = Data(repeating: UInt8(ascii: "x"), count: 70_000)
        try writeRaw(to: path, data: junk)
        let states1 = reader.consumeAppended()
        #expect(states1.isEmpty)

        // Now write a valid state line — reader must re-sync and parse it.
        let stateLine = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.\n"
        try writeRaw(to: path, data: Data(stateLine.utf8))
        let states2 = reader.consumeAppended()
        #expect(states2 == [.connected], "reader re-syncs after carry is dropped")
    }
}

// MARK: - helpers

/// A real-time clock that counts `sleep(for:)` calls. Unlike `FakeTimeSource`
/// (whose `sleep` returns instantly), this actually waits, so a busy loop
/// shows up as a runaway call count over a fixed wall-clock window.
private final class CountingTimeSource: TimeSource, @unchecked Sendable {
    private let interval: Duration
    private let lock = AsyncSafeLock()
    private var _count = 0

    init(interval: Duration) { self.interval = interval }

    var count: Int { lock.withLock { _count } }

    func now() -> Date { Date() }

    func sleep(for duration: Duration) async throws {
        lock.withLock { _count += 1 }
        try await Task.sleep(for: interval)
    }
}

private func makeTempLog(contents: String) throws -> String {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("limpet-\(UUID().uuidString).log")
    try contents.write(to: tmp, atomically: true, encoding: .utf8)
    return tmp.path
}

private func writeRaw(to path: String, data: Data) throws {
    let url = URL(fileURLWithPath: path)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
}

private func append(to path: String, _ contents: String) throws {
    try writeRaw(to: path, data: Data(contents.utf8))
}

// The timeout helpers below race the stream against a timer via a shared signal
// channel and explicit `Task.cancel()`, rather than `withTaskGroup { … cancelAll() }`
// over a live `AsyncStream` iterator. This matches the production monitor and
// `Preferences`, which use the same idiom to sidestep the documented macOS 26
// Swift `AsyncStream` cancellation race (a stdlib Range assertion).

private func firstValue<T: Sendable>(from stream: AsyncStream<T>, timeout: Duration) async throws -> T? {
    let signal = AsyncStream<T?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let streamTask = Task {
        for await value in stream { signal.continuation.yield(value); return }
        signal.continuation.yield(nil)
    }
    let timerTask = Task {
        try? await Task.sleep(for: timeout)
        signal.continuation.yield(nil)
    }
    let result = (await signal.stream.first { _ in true }).flatMap { $0 }
    streamTask.cancel()
    timerTask.cancel()
    return result
}

/// Spawn a task that reads up to `max` states from `stream`, with a hard
/// timeout so a test can never hang forever.
private func collectStates(
    from stream: AsyncStream<ConnectionState>,
    max: Int,
    timeout: Duration
) -> Task<[ConnectionState], Never> {
    Task {
        let signal = AsyncStream<[ConnectionState]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let collectTask = Task {
            var collected: [ConnectionState] = []
            for await s in stream {
                collected.append(s)
                if collected.count >= max { signal.continuation.yield(collected); return }
            }
            signal.continuation.yield(collected)
        }
        let timerTask = Task {
            try? await Task.sleep(for: timeout)
            signal.continuation.yield([])
        }
        let result = await signal.stream.first { _ in true } ?? []
        collectTask.cancel()
        timerTask.cancel()
        return result
    }
}
