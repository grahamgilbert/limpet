// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Network
import OSLog

/// The default GP log path on macOS.
public let panGPSLogPath = "/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log"

/// The network interface name that GlobalProtect creates when connected.
public let gpInterfaceName = "gpd0"

// MARK: - Interface observation

/// Emits `true` when the GP VPN interface is present, `false` when it is absent.
/// Using `NWPathMonitor` means zero CPU overhead while the interface is stable.
public protocol VpnInterfaceObserving: Sendable {
    var changes: AsyncStream<Bool> { get }
    func start()
    func cancel()
}

/// Live implementation backed by `NWPathMonitor`.
public final class NWVpnInterfaceObserver: VpnInterfaceObserving, @unchecked Sendable {
    public let changes: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private let monitor: NWPathMonitor

    public init(interfaceName: String = gpInterfaceName) {
        var cont: AsyncStream<Bool>.Continuation!
        self.changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont
        self.monitor = NWPathMonitor()

        let cont2 = cont!
        let name = interfaceName
        monitor.pathUpdateHandler = { path in
            let present = path.availableInterfaces.contains { $0.name == name }
            cont2.yield(present)
        }
    }

    public func start() { monitor.start(queue: .global(qos: .utility)) }
    public func cancel() { monitor.cancel(); continuation.finish() }
}

// MARK: - Status monitor

/// Monitors GlobalProtect VPN state using `NWPathMonitor` as the primary
/// signal and the GP log file only during disconnection / reconnect windows.
///
/// **Steady state (connected):** `NWPathMonitor` is dormant — zero file I/O.
/// **During reconnect:** polls `PanGPS.log` every `pollInterval` to
/// distinguish `.connecting` (GP retrying) from `.disconnected` (GP gave up).
/// As soon as the `gpd0` interface reappears, log polling stops immediately.
public final class VpnStatusMonitor: VpnStatusStreaming, @unchecked Sendable {
    public let stream: AsyncStream<ConnectionState>
    private let continuation: AsyncStream<ConnectionState>.Continuation
    private let task: Task<Void, Never>

    public init(
        path: String = panGPSLogPath,
        pollInterval: Duration = .seconds(2),
        observer: VpnInterfaceObserving = NWVpnInterfaceObserver()
    ) {
        var cont: AsyncStream<ConnectionState>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont

        let continuation = self.continuation
        self.task = Task.detached {
            await Self.runLoop(
                path: path,
                pollInterval: pollInterval,
                observer: observer,
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
        pollInterval: Duration,
        observer: VpnInterfaceObserving,
        continuation: AsyncStream<ConnectionState>.Continuation
    ) async {
        var reader = LogReader(path: path)
        var lastEmitted: ConnectionState?

        // Seed from the existing log tail so the UI shows the right state at
        // launch without waiting for the first network event.
        if let seed = reader.seedFromExistingFile() {
            continuation.yield(seed)
            lastEmitted = seed
        } else if !reader.isAccessible {
            continuation.yield(.unknown)
            lastEmitted = .unknown
        }

        observer.start()
        defer {
            observer.cancel()
            continuation.finish()
        }

        // NWPathMonitor fires once immediately at startup with the current state.
        var interfacePresent = false

        // Drain the interface-change stream, but also wake periodically while
        // the interface is absent so we can poll the log for reconnect state.
        // We drive the loop with a single `for await` on the changes stream and
        // use a separate background task to inject a synthetic `.pollTimerFired`
        // event via a shared channel when the poll interval elapses.
        let eventChannel = AsyncStream<MonitorEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))

        // Bridge interface changes into the event channel.
        // Use withTaskCancellationHandler so cancellation is handled synchronously
        // rather than via AsyncStream iterator teardown, which can trigger a Swift
        // stdlib Range assertion on macOS 26 beta when cancelled concurrently.
        let bridgeTask = Task {
            await withTaskCancellationHandler {
                for await present in observer.changes {
                    eventChannel.continuation.yield(.interfaceChanged(present))
                }
                eventChannel.continuation.finish()
            } onCancel: {
                eventChannel.continuation.finish()
            }
        }
        defer { bridgeTask.cancel() }

        // Timer task: re-created whenever we need a poll tick.
        var timerTask: Task<Void, Never>?

        func scheduleTimer() {
            timerTask?.cancel()
            timerTask = Task {
                try? await Task.sleep(for: pollInterval)
                if !Task.isCancelled {
                    eventChannel.continuation.yield(.pollTimerFired)
                }
            }
        }

        // Start a timer immediately since we don't know the initial interface
        // state until the first event arrives.
        scheduleTimer()

        for await event in eventChannel.stream {
            guard !Task.isCancelled else { break }

            switch event {
            case .interfaceChanged(let present):
                interfacePresent = present
                if present {
                    timerTask?.cancel()
                    timerTask = nil
                    if lastEmitted != .connected {
                        continuation.yield(.connected)
                        lastEmitted = .connected
                    }
                } else {
                    // Interface just went down — read log immediately, then schedule polling.
                    for state in reader.consumeAppended() where state != lastEmitted {
                        continuation.yield(state)
                        lastEmitted = state
                    }
                    scheduleTimer()
                }
            case .pollTimerFired:
                if !interfacePresent {
                    for state in reader.consumeAppended() where state != lastEmitted {
                        continuation.yield(state)
                        lastEmitted = state
                    }
                    scheduleTimer()
                }
            }
        }

        timerTask?.cancel()
    }

    private enum MonitorEvent {
        case interfaceChanged(Bool)
        case pollTimerFired
    }
}

// MARK: - LogReader

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
