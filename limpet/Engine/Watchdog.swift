// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import OSLog

public protocol DesiredStateProviding: AnyObject, Sendable {
    var desiredOn: Bool { get }
}

public protocol StateSink: AnyObject, Sendable {
    func update(_ state: ConnectionState)
}

/// Reconciles desired VPN state vs. actual state observed from the status
/// stream.
///
/// Design:
/// - When `desiredOn`, we want the actual state to be `.connected`.
/// - When not `desiredOn`, we want the actual state to be `.disconnected`
///   or `.disabled`.
/// - Issuing a control action (`connect`/`disconnect`) takes time to take
///   effect. To avoid click-storming GP we apply a **settle window** after
///   each action: no further action is issued until either the observed
///   state has *changed* from what it was when we issued the action, or
///   `settleWindow` has elapsed.
/// - On successive failures (state never changes), we widen the settle
///   window via exponential backoff up to `maxBackoff`.
public actor Watchdog {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "watchdog")

    private let controller: VpnControlling
    private let stateSink: StateSink
    private let desired: DesiredStateProviding
    private let time: TimeSource

    private let connectingGrace: Duration
    private let initialBackoff: Duration
    private let maxBackoff: Duration

    private var lastConnectAt: Date?
    private var consecutiveConnects: Int = 0
    private var lastConnectingSeenAt: Date?
    private var lastDisconnectAt: Date?
    private var consecutiveDisconnects: Int = 0
    private var lastState: ConnectionState = .unknown

    /// State observed at the moment the most recent action was issued. While
    /// the observed state still equals this snapshot, we hold off on further
    /// actions until the relevant backoff timer expires.
    private var stateAtLastConnect: ConnectionState?
    private var stateAtLastDisconnect: ConnectionState?

    public init(
        controller: VpnControlling,
        stateSink: StateSink,
        desired: DesiredStateProviding,
        time: TimeSource = SystemTimeSource(),
        connectingGrace: Duration = .seconds(15),
        initialBackoff: Duration = .seconds(8),
        maxBackoff: Duration = .seconds(300)
    ) {
        self.controller = controller
        self.stateSink = stateSink
        self.desired = desired
        self.time = time
        self.connectingGrace = connectingGrace
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
    }

    public func handle(_ state: ConnectionState) async {
        let prev = lastState
        lastState = state
        stateSink.update(state)

        // If the observed state has changed since we issued an action, that
        // action either took effect (or is still in progress). Reset backoff
        // counters so a future need to act gets a fresh attempt.
        if state != prev {
            if let snap = stateAtLastConnect, state != snap { stateAtLastConnect = nil }
            if let snap = stateAtLastDisconnect, state != snap { stateAtLastDisconnect = nil }
        }

        if desired.desiredOn {
            await reconcileDesiredOn(state)
        } else {
            await reconcileDesiredOff(state)
        }
    }

    public func reconcile() async {
        await handle(lastState)
    }

    public func consume(_ stream: AsyncStream<ConnectionState>) async {
        for await state in stream {
            await handle(state)
        }
    }

    // MARK: - Private

    private func reconcileDesiredOn(_ state: ConnectionState) async {
        switch state {
        case .connected:
            // Goal achieved.
            resetBackoff()
        case .unknown:
            // Don't act on unknown state.
            break
        case .connecting:
            let now = time.now()
            if lastConnectingSeenAt == nil { lastConnectingSeenAt = now }
            // Only re-poke connect if we've been stuck in .connecting longer
            // than connectingGrace AND no recent action is still settling.
            if let firstSeen = lastConnectingSeenAt,
               now.timeIntervalSince(firstSeen) >= connectingGrace.seconds,
               canIssueConnect(now: now, currentState: state) {
                await issueConnect(snapshotState: state)
            }
        case .disconnected, .disabled:
            lastConnectingSeenAt = nil
            if canIssueConnect(now: time.now(), currentState: state) {
                await issueConnect(snapshotState: state)
            }
        }
    }

    private func reconcileDesiredOff(_ state: ConnectionState) async {
        switch state {
        case .connected, .connecting:
            if canIssueDisconnect(now: time.now(), currentState: state) {
                await issueDisconnect(snapshotState: state)
            }
        case .disconnected, .disabled, .unknown:
            consecutiveDisconnects = 0
            lastDisconnectAt = nil
            stateAtLastDisconnect = nil
        }
    }

    private func canIssueConnect(now: Date, currentState: ConnectionState) -> Bool {
        // If we have a snapshot of state-at-action and the current state still
        // equals it, the action hasn't taken effect yet — wait for backoff.
        if let snap = stateAtLastConnect, snap == currentState {
            guard let last = lastConnectAt else { return true }
            return now.timeIntervalSince(last) >= currentBackoff(consecutive: consecutiveConnects)
        }
        return true
    }

    private func canIssueDisconnect(now: Date, currentState: ConnectionState) -> Bool {
        if let snap = stateAtLastDisconnect, snap == currentState {
            guard let last = lastDisconnectAt else { return true }
            return now.timeIntervalSince(last) >= currentBackoff(consecutive: consecutiveDisconnects)
        }
        return true
    }

    private func issueConnect(snapshotState: ConnectionState) async {
        Self.log.info("issueConnect: state=\(String(describing: snapshotState))")
        do {
            try await controller.connect()
        } catch {
            Self.log.error("connect failed: \(error.localizedDescription)")
        }
        lastConnectAt = time.now()
        consecutiveConnects += 1
        lastConnectingSeenAt = nil
        stateAtLastConnect = snapshotState
    }

    private func issueDisconnect(snapshotState: ConnectionState) async {
        Self.log.info("issueDisconnect: state=\(String(describing: snapshotState))")
        do {
            try await controller.disconnect()
        } catch {
            Self.log.error("disconnect failed: \(error.localizedDescription)")
        }
        lastDisconnectAt = time.now()
        consecutiveDisconnects += 1
        stateAtLastDisconnect = snapshotState
    }

    private func resetBackoff() {
        lastConnectAt = nil
        consecutiveConnects = 0
        lastConnectingSeenAt = nil
        stateAtLastConnect = nil
    }

    private func currentBackoff(consecutive: Int) -> TimeInterval {
        let n = max(consecutive - 1, 0)
        let factor = pow(2.0, Double(n))
        let exponential = initialBackoff.seconds * factor
        return min(exponential, maxBackoff.seconds)
    }
}

extension Duration {
    fileprivate var seconds: TimeInterval {
        let comps = self.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
    }
}
