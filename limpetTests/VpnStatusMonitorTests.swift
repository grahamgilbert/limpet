// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Testing
@testable import limpet

// MARK: - VpnStatusMonitor integration tests

@Suite("VpnStatusMonitor — NWPath + log hybrid")
struct VpnStatusMonitorTests {

    @Test("interface up at startup → emits connected without reading log")
    func interfaceUpAtStartup() async throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let observer = ManualInterfaceObserver()
        let monitor = VpnStatusMonitor(path: path, pollInterval: .seconds(30), observer: observer)
        let collected = collectStates(from: monitor.stream, max: 1, timeout: .seconds(2))

        observer.send(true)

        let states = await collected.value
        #expect(states == [.connected])
    }

    @Test("interface transitions from up to down then back up → connected, then log state, then connected")
    func interfaceDownThenUp() async throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let observer = ManualInterfaceObserver()
        let monitor = VpnStatusMonitor(path: path, pollInterval: .seconds(30), observer: observer)
        let collected = collectStates(from: monitor.stream, max: 3, timeout: .seconds(3))

        // Start connected
        observer.send(true)
        try await Task.sleep(for: .milliseconds(100))

        // Drop the interface — write a connecting line to the log
        let connectingLine = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 1.\n"
        try appendToLog(path: path, contents: connectingLine)
        observer.send(false)
        try await Task.sleep(for: .milliseconds(200))

        // Interface comes back up
        observer.send(true)

        let states = await collected.value
        #expect(states.contains(.connected))
        #expect(states.contains(.connecting))
        // Final state should be connected (interface came back)
        #expect(states.last == .connected)
    }

    @Test("poll timer fires while interface is down → reads log")
    func pollTimerReadsLog() async throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let observer = ManualInterfaceObserver()
        let monitor = VpnStatusMonitor(path: path, pollInterval: .milliseconds(100), observer: observer)
        let collected = collectStates(from: monitor.stream, max: 2, timeout: .seconds(3))

        // Interface is down from the start
        observer.send(false)
        try await Task.sleep(for: .milliseconds(50))

        // Write a log line — the poll timer should pick it up
        let line = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.\n"
        try appendToLog(path: path, contents: line)

        // Wait for the poll to fire
        try await Task.sleep(for: .milliseconds(300))
        observer.send(true) // unblock collector

        let states = await collected.value
        #expect(states.contains(.disconnected))
    }

    @Test("no log polling while interface is up")
    func noLogPollingWhileConnected() async throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let observer = ManualInterfaceObserver()
        // Very short poll interval — would fire immediately if activated
        let monitor = VpnStatusMonitor(path: path, pollInterval: .milliseconds(50), observer: observer)

        observer.send(true)
        try await Task.sleep(for: .milliseconds(100))

        // Write a disconnected line — should NOT be emitted because log polling is suspended
        let line = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.\n"
        try appendToLog(path: path, contents: line)
        try await Task.sleep(for: .milliseconds(200))

        let collected = collectStates(from: monitor.stream, max: 5, timeout: .milliseconds(300))
        let states = await collected.value

        // Only .connected should have been emitted; the disconnected log line is ignored
        #expect(!states.contains(.disconnected))
    }

    @Test("seeds from existing file on startup")
    func seedsFromExistingFile() async throws {
        let path = try makeTempLog(contents: """
         m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let observer = ManualInterfaceObserver()
        let monitor = VpnStatusMonitor(path: path, pollInterval: .seconds(30), observer: observer)
        let first = try await firstValue(from: monitor.stream, timeout: .seconds(2))
        #expect(first == .connected)
    }

    @Test("emits .unknown when log is inaccessible and interface is down")
    func unknownWhenLogMissingAndInterfaceDown() async throws {
        let bogusPath = "/tmp/limpet-nonexistent-\(UUID().uuidString).log"
        let observer = ManualInterfaceObserver()
        let monitor = VpnStatusMonitor(path: bogusPath, pollInterval: .seconds(30), observer: observer)
        let first = try await firstValue(from: monitor.stream, timeout: .seconds(1))
        #expect(first == .unknown)
    }

    @Test("duplicate states are deduplicated")
    func duplicateStatesDeduplicated() async throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let observer = ManualInterfaceObserver()
        let monitor = VpnStatusMonitor(path: path, pollInterval: .milliseconds(50), observer: observer)
        let collected = collectStates(from: monitor.stream, max: 3, timeout: .seconds(2))

        observer.send(true)  // connected
        try await Task.sleep(for: .milliseconds(100))
        observer.send(true)  // same state, should not emit again
        try await Task.sleep(for: .milliseconds(100))
        observer.send(false) // now disconnected
        try await Task.sleep(for: .milliseconds(100))
        observer.send(true)  // back to connected

        let states = await collected.value
        // Should not see consecutive duplicates
        for i in 1..<states.count {
            #expect(states[i] != states[i - 1], "got consecutive duplicate at index \(i): \(states[i])")
        }
    }
}

// MARK: - LogReader unit tests (kept from old LogTailingStatusMonitorTests)

@Suite("LogReader — low-level log parsing")
struct LogReaderTests {

    @Test("line split across two reads is parsed correctly")
    func splitLineAcrossReads() throws {
        let path = try makeTempLog(contents: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        var reader = LogReader(path: path)

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

        let junk = Data(repeating: UInt8(ascii: "x"), count: 70_000)
        try writeRaw(to: path, data: junk)
        let states1 = reader.consumeAppended()
        #expect(states1.isEmpty)

        let stateLine = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.\n"
        try writeRaw(to: path, data: Data(stateLine.utf8))
        let states2 = reader.consumeAppended()
        #expect(states2 == [.connected], "reader re-syncs after carry is dropped")
    }
}

// MARK: - ManualInterfaceObserver

/// Test double for `VpnInterfaceObserving` — caller drives events manually.
final class ManualInterfaceObserver: VpnInterfaceObserving, @unchecked Sendable {
    let changes: AsyncStream<Bool>
    private let cont: AsyncStream<Bool>.Continuation

    init() {
        var c: AsyncStream<Bool>.Continuation!
        changes = AsyncStream { c = $0 }
        cont = c
    }

    func send(_ present: Bool) { cont.yield(present) }
    func start() {}
    func cancel() { cont.finish() }
}

// MARK: - Helpers

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

private func appendToLog(path: String, contents: String) throws {
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
