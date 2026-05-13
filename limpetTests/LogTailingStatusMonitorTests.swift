// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Testing
@testable import limpet

@Suite("LogTailingStatusMonitor — log tailer + rotation")
struct LogTailingStatusMonitorTests {
    @Test("seeds with the most recent state already present in the file")
    func seedsFromExistingFile() async throws {
        let path = try makeTempLog(contents: """
        P 967 NetworkConnectionMonitorThread: m_state = 0, …
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let monitor = LogTailingStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .milliseconds(50))
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

        let monitor = LogTailingStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .milliseconds(50))
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

        let monitor = LogTailingStatusMonitor(path: path, time: SystemTimeSource(), pollInterval: .milliseconds(50))
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

    @Test("emits .unknown when the path is unreadable at startup")
    func unreadablePathEmitsUnknown() async throws {
        let bogus = "/tmp/limpet-nonexistent-\(UUID().uuidString).log"
        let monitor = LogTailingStatusMonitor(path: bogus, time: SystemTimeSource(), pollInterval: .milliseconds(50))
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

private func firstValue<T: Sendable>(from stream: AsyncStream<T>, timeout: Duration) async throws -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = (await group.next()).flatMap { $0 }
        group.cancelAll()
        return result
    }
}

/// Spawn a task that reads up to `max` states from `stream`, with a hard
/// timeout so a test can never hang forever.
private func collectStates(
    from stream: AsyncStream<ConnectionState>,
    max: Int,
    timeout: Duration
) -> Task<[ConnectionState], Never> {
    Task {
        await withTaskGroup(of: [ConnectionState].self) { group in
            group.addTask {
                var collected: [ConnectionState] = []
                for await s in stream {
                    collected.append(s)
                    if collected.count >= max { break }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let comps = self.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
    }
}
