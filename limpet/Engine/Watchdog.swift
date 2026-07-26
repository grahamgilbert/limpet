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
///   each action: no further action of the same kind is issued until the
///   window has elapsed, *regardless* of what states were observed in
///   between. A GP that flaps disconnected → connecting → disconnected
///   every few seconds (typical after wake-from-sleep) must not earn a
///   fresh click on every flap — each click opens GP's popover, so that
///   reads to the user as a window flickering open and shut.
/// - On successive attempts that never reach the goal, we widen the settle
///   window via exponential backoff up to `maxBackoff`. Reaching the goal
///   state resets it, so a genuine later drop reconnects immediately.
public actor Watchdog {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "watchdog")

    private let controller: VpnControlling
    private let stateSink: StateSink
    private let desired: DesiredStateProviding
    private let time: TimeSource
    private let notifier: SecurityNotifying

    private let connectingGrace: Duration
    private let initialBackoff: Duration
    private let maxBackoff: Duration

    private var lastConnectAt: Date?
    private var consecutiveConnects: Int = 0
    private var lastConnectingSeenAt: Date?
    private var lastDisconnectAt: Date?
    private var consecutiveDisconnects: Int = 0
    private var lastState: ConnectionState = .unknown
    // Prevents a notification storm when GP stays in a persistently bad signature state.
    private var signatureNotificationFired = false

    public init(
        controller: VpnControlling,
        stateSink: StateSink,
        desired: DesiredStateProviding,
        time: TimeSource = SystemTimeSource(),
        notifier: SecurityNotifying = SystemLoginItemNotifier(),
        connectingGrace: Duration = .seconds(15),
        initialBackoff: Duration = .seconds(8),
        maxBackoff: Duration = .seconds(300)
    ) {
        self.controller = controller
        self.stateSink = stateSink
        self.desired = desired
        self.time = time
        self.notifier = notifier
        self.connectingGrace = connectingGrace
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
    }

    public func handle(_ state: ConnectionState) async {
        lastState = state
        stateSink.update(state)

        if desired.desiredOn {
            await reconcileDesiredOn(state)
        } else {
            await reconcileDesiredOff(state)
        }
    }

    /// Re-evaluates the most recently observed state.
    ///
    /// Load-bearing, not a convenience: the status stream is *deduplicated*, so
    /// a GP that settles into `.disconnected` and stays there produces no
    /// further events. Without this, an action deferred by the settle window
    /// would never be reconsidered and the VPN would stay down indefinitely.
    public func reconcile() async {
        await handle(lastState)
    }

    /// Drives `reconcile()` on a timer for the lifetime of the app. `interval`
    /// bounds how long past a settle window a deferred retry can sit.
    public func runPeriodicReconcile(every interval: Duration) async {
        while !Task.isCancelled {
            try? await time.sleep(for: interval)
            if Task.isCancelled { break }
            await reconcile()
        }
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
               canIssueConnect(now: now) {
                await issueConnect(state)
            }
        case .disconnected, .disabled:
            lastConnectingSeenAt = nil
            if canIssueConnect(now: time.now()) {
                await issueConnect(state)
            }
        }
    }

    private func reconcileDesiredOff(_ state: ConnectionState) async {
        switch state {
        case .connected, .connecting:
            if canIssueDisconnect(now: time.now()) {
                await issueDisconnect(state)
            }
        case .disconnected, .disabled, .unknown:
            consecutiveDisconnects = 0
            lastDisconnectAt = nil
        }
    }

    /// Deliberately ignores the observed state — see the settle-window note on
    /// the type. Intermediate flapping is not evidence the last click worked.
    private func canIssueConnect(now: Date) -> Bool {
        guard let last = lastConnectAt else { return true }
        return now.timeIntervalSince(last) >= currentBackoff(consecutive: consecutiveConnects)
    }

    private func canIssueDisconnect(now: Date) -> Bool {
        guard let last = lastDisconnectAt else { return true }
        return now.timeIntervalSince(last) >= currentBackoff(consecutive: consecutiveDisconnects)
    }

    private func issueConnect(_ observedState: ConnectionState) async {
        Self.log.info("issueConnect: state=\(String(describing: observedState))")
        do {
            try await controller.connect()
        } catch {
            Self.log.error("connect failed: \(error.localizedDescription)")
            handleControllerError(error)
        }
        lastConnectAt = time.now()
        consecutiveConnects += 1
        lastConnectingSeenAt = nil
    }

    private func issueDisconnect(_ observedState: ConnectionState) async {
        Self.log.info("issueDisconnect: state=\(String(describing: observedState))")
        do {
            try await controller.disconnect()
        } catch {
            Self.log.error("disconnect failed: \(error.localizedDescription)")
            handleControllerError(error)
        }
        lastDisconnectAt = time.now()
        consecutiveDisconnects += 1
    }

    private func handleControllerError(_ error: Error) {
        guard case VpnControlError.signatureVerificationFailed = error,
              !signatureNotificationFired else { return }
        signatureNotificationFired = true
        notifier.notifyGlobalProtectSignatureInvalid()
    }

    private func resetBackoff() {
        lastConnectAt = nil
        consecutiveConnects = 0
        lastConnectingSeenAt = nil
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
