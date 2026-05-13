// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import OSLog

/// The default GP log path on macOS.
public let panGPSLogPath = "/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log"

/// Tails `PanGPS.log`, parses every line through `parsePanGPSLine`,
/// and emits **transitions** in `ConnectionState` over an `AsyncStream`.
///
/// Identical states are deduplicated — flipping the same flag values every
/// second produces zero stream events.
///
/// Handles log rotation by reopening when the file's inode changes. If the
/// path is unreadable at startup, emits `.unknown` once and keeps polling.
public final class LogTailingStatusMonitor: VpnStatusStreaming, @unchecked Sendable {
    public let stream: AsyncStream<ConnectionState>
    private let continuation: AsyncStream<ConnectionState>.Continuation
    private let task: Task<Void, Never>

    public init(
        path: String = panGPSLogPath,
        time: TimeSource = SystemTimeSource(),
        pollInterval: Duration = .seconds(1)
    ) {
        var cont: AsyncStream<ConnectionState>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont

        let continuation = self.continuation
        self.task = Task.detached {
            await Self.runLoop(
                path: path,
                time: time,
                pollInterval: pollInterval,
                continuation: continuation
            )
        }
    }

    deinit {
        task.cancel()
        continuation.finish()
    }

    // MARK: - Loop

    private static func runLoop(
        path: String,
        time: TimeSource,
        pollInterval: Duration,
        continuation: AsyncStream<ConnectionState>.Continuation
    ) async {
        var reader = LogReader(path: path)
        var lastEmitted: ConnectionState?

        if let seed = reader.seedFromExistingFile() {
            continuation.yield(seed)
            lastEmitted = seed
        } else if !reader.isAccessible {
            continuation.yield(.unknown)
            lastEmitted = .unknown
        }

        while !Task.isCancelled {
            do {
                try await time.sleep(for: pollInterval)
            } catch {
                break
            }

            for state in reader.consumeAppended() where state != lastEmitted {
                continuation.yield(state)
                lastEmitted = state
            }
        }

        continuation.finish()
    }
}

/// Reads newly-appended bytes from a log file across reopens (rotation).
/// Not thread-safe; the monitor's loop owns it.
struct LogReader {
    let path: String
    private var handle: FileHandle?
    private var inode: UInt64?
    private(set) var isAccessible: Bool = false
    private var carry: Data = Data()

    init(path: String) {
        self.path = path
        openSeekingToEnd()
    }

    /// Reads the existing tail of the file once, returns the most recent
    /// parseable state. Used to surface the current GP state at launch
    /// without waiting for the next GP heartbeat.
    mutating func seedFromExistingFile() -> ConnectionState? {
        guard isAccessible else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .uncached) else {
            return nil
        }
        // Scan only the last ~64 KB for efficiency on giant logs.
        let tailWindow = 64 * 1024
        let slice = data.suffix(tailWindow)
        // isoLatin1 is total over all byte values, so the slice can never fail
        // to decode. The lines we care about (PanGPS flag lines) are ASCII.
        let text = String(bytes: slice, encoding: .isoLatin1) ?? ""
        var lastState: ConnectionState?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let s = parsePanGPSLine(String(line)) {
                lastState = s
            }
        }
        return lastState
    }

    /// Returns every parseable state encountered in bytes appended since
    /// the last call (or since `init`).
    mutating func consumeAppended() -> [ConnectionState] {
        rotateIfNeeded()
        guard let handle else { return [] }

        let chunk: Data
        do {
            chunk = try handle.readToEnd() ?? Data()
        } catch {
            return []
        }
        guard !chunk.isEmpty else { return [] }

        let combined = carry + chunk

        var states: [ConnectionState] = []
        var lineStart = combined.startIndex
        for i in combined.indices {
            if combined[i] == 0x0A {
                let lineData = combined[lineStart..<i]
                let line = String(bytes: lineData, encoding: .isoLatin1) ?? ""
                if let state = parsePanGPSLine(line) {
                    states.append(state)
                }
                lineStart = combined.index(after: i)
            }
        }
        let tail = combined[lineStart...]
        // Guard against unbounded carry growth from an unterminated or malformed line.
        carry = tail.count > 65_000 ? Data() : Data(tail)
        return states
    }

    private mutating func rotateIfNeeded() {
        let currentInode = inodeOf(path: path)
        if currentInode != inode {
            do { try handle?.close() } catch { /* best-effort */ }
            handle = nil
            inode = nil
            carry = Data()
            openFromBeginning()
        }
    }

    private mutating func openSeekingToEnd() {
        let url = URL(fileURLWithPath: path)
        guard let h = try? FileHandle(forReadingFrom: url) else {
            isAccessible = false
            return
        }
        do { try h.seekToEnd() } catch { /* tail anyway */ }
        handle = h
        inode = inodeOf(path: path)
        isAccessible = true
    }

    private mutating func openFromBeginning() {
        // After rotation, read the new file from the start so we don't miss
        // anything written between the rename and our reopen.
        let url = URL(fileURLWithPath: path)
        guard let h = try? FileHandle(forReadingFrom: url) else {
            isAccessible = false
            return
        }
        handle = h
        inode = inodeOf(path: path)
        isAccessible = true
    }
}

private func inodeOf(path: String) -> UInt64? {
    var s = stat()
    guard stat(path, &s) == 0 else { return nil }
    return UInt64(s.st_ino)
}
