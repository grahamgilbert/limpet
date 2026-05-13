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
///
/// Uses a `DispatchSourceFileSystemObject` to wake only on actual file
/// activity (writes, rotations). A 10-second safety poll backstop catches
/// any events the kernel drops.
public final class LogTailingStatusMonitor: VpnStatusStreaming, @unchecked Sendable {
    public let stream: AsyncStream<ConnectionState>
    private let continuation: AsyncStream<ConnectionState>.Continuation
    private let task: Task<Void, Never>

    public init(
        path: String = panGPSLogPath,
        time: TimeSource = SystemTimeSource(),
        pollInterval: Duration = .seconds(10)
    ) {
        var cont: AsyncStream<ConnectionState>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont

        let continuation = self.continuation
        self.task = Task.detached {
            await Self.runLoop(
                path: path,
                time: time,
                safetyInterval: pollInterval,
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
        safetyInterval: Duration,
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

        // Signal channel: the DispatchSource posts here on every interesting
        // filesystem event (write, extend, rename, delete). Buffering is
        // capped at 1 so rapid writes coalesce into a single wakeup instead
        // of queuing up and busy-looping the drain.
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        // Open the file with O_EVTONLY so we don't prevent log rotation.
        var fsSource: DispatchSourceFileSystemObject? = makeFSSource(
            path: path,
            signal: signal.continuation
        )

        while !Task.isCancelled {
            // Wait for a filesystem event or the safety backstop.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = await signal.stream.first { _ in true }
                }
                group.addTask {
                    try? await time.sleep(for: safetyInterval)
                }
                await group.next()
                group.cancelAll()
            }

            guard !Task.isCancelled else { break }

            // Sample the inode before consuming so we can detect rotation.
            // consumeAppended calls rotateIfNeeded internally, which opens a
            // new handle for the replacement file; comparing the inode after
            // the fact would always show equality.
            let inodeBefore = inodeOf(path: path)
            let wasAccessible = reader.isAccessible
            for state in reader.consumeAppended() where state != lastEmitted {
                continuation.yield(state)
                lastEmitted = state
            }
            let inodeAfter = inodeOf(path: path)
            // Recreate the DispatchSource when the file was rotated (inode
            // changed) or when the file first appeared (was inaccessible and
            // is now readable).
            if inodeAfter != inodeBefore || (!wasAccessible && reader.isAccessible) {
                fsSource?.cancel()
                fsSource = makeFSSource(path: path, signal: signal.continuation)
            }
        }

        fsSource?.cancel()
        continuation.finish()
    }

    private static func makeFSSource(
        path: String,
        signal: AsyncStream<Void>.Continuation
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { signal.yield() }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }
}

/// Reads newly-appended bytes from a log file across reopens (rotation).
/// Not thread-safe; the monitor's loop owns it.
struct LogReader {
    let path: String
    private var handle: FileHandle?
    private var inode: UInt64?
    private(set) var isAccessible: Bool = false
    private var carry: String = ""
    private static let maxCarryBytes = 65_000

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
        let text = String(bytes: slice, encoding: .utf8) ?? ""
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

        let raw = String(bytes: chunk, encoding: .utf8) ?? ""
        let combined = carry + raw

        var parts = combined.split(separator: "\n", omittingEmptySubsequences: false)
        // The last element is either empty (line ended with \n) or an incomplete
        // line fragment to carry forward to the next read.
        let tail = combined.hasSuffix("\n") ? "" : String(parts.removeLast())
        // Guard against unbounded carry growth from a stuck unterminated line.
        carry = tail.utf8.count > Self.maxCarryBytes ? "" : tail

        return parts.compactMap { parsePanGPSLine(String($0)) }
    }

    private mutating func rotateIfNeeded() {
        let currentInode = inodeOf(path: path)
        if currentInode != inode {
            do { try handle?.close() } catch { /* best-effort */ }
            handle = nil
            inode = nil
            carry = ""
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
