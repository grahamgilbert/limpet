// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Testing
@testable import limpet

@Suite("Watchdog reconciliation")
struct WatchdogTests {
    @Test("desired-on, sees .disconnected → calls connect once")
    func desiredOnDisconnectedConnectsOnce() async {
        let (dog, controller, _, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1)
    }

    @Test("desired-on, sees .connecting → does not click")
    func desiredOnConnectingNoOp() async {
        let (dog, controller, _, _, _) = makeDog(desiredOn: true)
        await dog.handle(.connecting)
        #expect(controller.connectCount == 0)
        #expect(controller.disconnectCount == 0)
    }

    @Test("desired-on, sees .connected → does not click")
    func desiredOnConnectedNoOp() async {
        let (dog, controller, _, _, _) = makeDog(desiredOn: true)
        await dog.handle(.connected)
        #expect(controller.connectCount == 0)
    }

    @Test("desired-off, sees .connected → calls disconnect")
    func desiredOffConnectedDisconnects() async {
        let (dog, controller, _, _, _) = makeDog(desiredOn: false)
        await dog.handle(.connected)
        #expect(controller.disconnectCount == 1)
    }

    @Test("desired-off, sees .connecting → calls disconnect")
    func desiredOffConnectingDisconnects() async {
        let (dog, controller, _, _, _) = makeDog(desiredOn: false)
        await dog.handle(.connecting)
        #expect(controller.disconnectCount == 1)
    }

    @Test("desired-off, sees .disconnected → no-op")
    func desiredOffDisconnectedNoOp() async {
        let (dog, controller, _, _, _) = makeDog(desiredOn: false)
        await dog.handle(.disconnected)
        #expect(controller.disconnectCount == 0)
    }

    @Test("desired-on, sees .disabled → calls connect")
    func desiredOnDisabledConnects() async {
        let (dog, controller, _, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disabled)
        #expect(controller.connectCount == 1)
    }

    @Test("rapid .disconnected events → backoff prevents click storm")
    func backoffPreventsClickStorm() async {
        let (dog, controller, time, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected) // attempt #1
        #expect(controller.connectCount == 1)

        // Same state, no time has elapsed → backoff blocks the second click.
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1)

        // Advance enough for the (initialBackoff = 2s) window.
        time.advance(by: 2.5)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 2)
    }

    @Test("backoff doubles between consecutive failures, capped at maxBackoff")
    func backoffExponential() async {
        let (dog, controller, time, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected) // attempt #1, lastConnectAt = t0

        time.advance(by: 2)             // 2s — at the boundary of initial backoff
        await dog.handle(.disconnected) // attempt #2 (consecutive=2 → next delay = 4s)
        #expect(controller.connectCount == 2)

        time.advance(by: 3)             // <4s, blocked
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 2)

        time.advance(by: 1.1)           // total 4.1s, allowed
        await dog.handle(.disconnected) // attempt #3, next delay = 8s
        #expect(controller.connectCount == 3)
    }

    @Test("seeing .connected resets the backoff so the next .disconnected reconnects immediately")
    func connectedResetsBackoff() async {
        let (dog, controller, time, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1)

        time.advance(by: 0.1)
        await dog.handle(.connected)
        // No click; backoff is reset.

        time.advance(by: 0.1)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 2) // immediate, despite tiny gap
    }

    @Test("flapping disconnected → connecting → disconnected does not bypass backoff")
    func flappingDoesNotBypassBackoff() async {
        // Wake-from-sleep signature: GP oscillates rather than sitting still.
        // Each connect click opens GP's popover, so a click per flap reads to
        // the user as a window flickering open and shut.
        let (dog, controller, time, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1)

        // 5 flaps × 0.2s = 1.0s, comfortably inside the 2s initial backoff.
        for _ in 0..<5 {
            time.advance(by: 0.1)
            await dog.handle(.connecting)   // GP tries
            time.advance(by: 0.1)
            await dog.handle(.disconnected) // ...and gives up again
        }
        #expect(controller.connectCount == 1, "backoff must survive intermediate transitions")

        time.advance(by: 1.5) // t = 2.5s, past initialBackoff
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 2)
    }

    @Test("a retry blocked by the settle window is retried once the window expires")
    func blockedRetryIsReconsidered() async {
        // The state stream is deduplicated: if GP settles into .disconnected and
        // stays there, no further events arrive. A retry that was blocked by the
        // settle window must therefore be reconsidered on a timer, or the VPN
        // stays down forever.
        let (dog, controller, time, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1)

        time.advance(by: 0.1)
        await dog.handle(.connecting)   // GP tries
        time.advance(by: 0.1)
        await dog.handle(.disconnected) // ...and gives up. Blocked by the window.
        #expect(controller.connectCount == 1)

        // No further stream events will ever arrive — GP just sits disconnected.
        time.advance(by: 2.5)
        await dog.reconcile()
        #expect(controller.connectCount == 2, "timer-driven reconcile must retry the last state")
    }

    @Test("concurrent handle() calls do not issue overlapping control actions")
    func noReentrantControlActions() async {
        // `await controller.connect()` releases the actor's isolation, so a
        // second caller (the reconcile ticker vs. the event stream) can reach
        // the backoff check while the first attempt is still in flight. Two
        // overlapping AX conversations against GP is what pressed Connect and
        // then fell through to "Refresh Connection" on a live session.
        let controller = SlowVpnController(delay: .milliseconds(80))
        let dog = Watchdog(
            controller: controller,
            stateSink: RecordingStateSink(),
            desired: StaticDesiredState(true),
            time: FakeTimeSource(),
            notifier: RecordingLoginItemNotifier(),
            initialBackoff: .seconds(2)
        )

        await withTaskGroup { group in
            group.addTask { await dog.handle(.disconnected) }
            group.addTask { await dog.handle(.disconnected) }
        }

        #expect(controller.connectCount == 1, "the second caller must not overlap the in-flight attempt")
    }

    @Test("an in-flight action blocks a new one even after the settle window expires")
    func inFlightBlocksEvenAfterWindowExpires() async {
        // A hung GP can keep connect() running longer than the settle window.
        // Recording the attempt time doesn't cover that case — the window really
        // has expired — so the in-flight guard has to.
        let controller = SlowVpnController(delay: .milliseconds(300))
        let dog = Watchdog(
            controller: controller,
            stateSink: RecordingStateSink(),
            desired: StaticDesiredState(true),
            time: SystemTimeSource(), // a real clock, so the window truly expires
            notifier: RecordingLoginItemNotifier(),
            initialBackoff: .milliseconds(20)
        )

        await withTaskGroup { group in
            group.addTask { await dog.handle(.disconnected) }
            group.addTask {
                // Arrive after the 20ms window has expired, but while the first
                // attempt's 300ms AX conversation is still running.
                try? await Task.sleep(for: .milliseconds(100))
                await dog.handle(.disconnected)
            }
        }

        #expect(controller.connectCount == 1, "must not start a second conversation mid-flight")
    }

    @Test("desired-on .connecting does not click until grace expires")
    func connectingGrace() async {
        let (dog, controller, time, _, _) = makeDog(desiredOn: true, connectingGrace: .seconds(15))
        await dog.handle(.connecting)
        #expect(controller.connectCount == 0)

        time.advance(by: 5)
        await dog.handle(.connecting)
        #expect(controller.connectCount == 0)

        time.advance(by: 11) // total 16s
        await dog.handle(.connecting)
        #expect(controller.connectCount == 1)
    }

    @Test("state sink receives every observed state in order")
    func stateSinkRecords() async {
        let (dog, _, _, sink, _) = makeDog(desiredOn: true)
        await dog.handle(.unknown)
        await dog.handle(.connecting)
        await dog.handle(.connected)
        #expect(sink.states == [.unknown, .connecting, .connected])
    }

    @Test("controller failure does not crash watchdog and still applies backoff")
    func failureStillBackoffs() async {
        let controller = RecordingVpnController()
        controller.failNext = FakeError("boom")
        let sink = RecordingStateSink()
        let desired = StaticDesiredState(true)
        let time = FakeTimeSource()
        let dog = Watchdog(controller: controller, stateSink: sink, desired: desired, time: time, initialBackoff: .seconds(2))

        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1) // attempt counted even on throw
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1) // blocked by backoff

        time.advance(by: 2.5)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 2)
    }

    @Test("consume() iterates a stream and reconciles each state")
    func consumeStream() async {
        let controller = RecordingVpnController()
        let sink = RecordingStateSink()
        let desired = StaticDesiredState(true)
        let time = FakeTimeSource()
        let dog = Watchdog(controller: controller, stateSink: sink, desired: desired, time: time, initialBackoff: .seconds(2))

        var continuation: AsyncStream<ConnectionState>.Continuation!
        let stream = AsyncStream<ConnectionState> { continuation = $0 }

        let task = Task {
            await dog.consume(stream)
        }

        continuation.yield(.disconnected)
        await Task.yield()
        // Give the consume loop a moment to run on the actor.
        try? await Task.sleep(for: .milliseconds(50))
        continuation.finish()
        await task.value

        #expect(controller.connectCount >= 1)
        #expect(sink.states.contains(.disconnected))
    }

    @Test("desired-off backoff also rate-limits disconnect calls")
    func disconnectBackoff() async {
        let (dog, controller, time, _, _) = makeDog(desiredOn: false)
        await dog.handle(.connected)
        #expect(controller.disconnectCount == 1)

        await dog.handle(.connected)
        #expect(controller.disconnectCount == 1)

        time.advance(by: 2.5)
        await dog.handle(.connected)
        #expect(controller.disconnectCount == 2)
    }

    @Test("signatureVerificationFailed on connect fires security notification")
    func signatureFailureOnConnectNotifies() async {
        let notifier = RecordingLoginItemNotifier()
        let (dog, controller, _, _, _) = makeDog(desiredOn: true, notifier: notifier)
        controller.failNext = VpnControlError.signatureVerificationFailed
        await dog.handle(.disconnected)
        #expect(notifier.signatureInvalidCalls == 1)
    }

    @Test("signatureVerificationFailed on disconnect fires security notification")
    func signatureFailureOnDisconnectNotifies() async {
        let notifier = RecordingLoginItemNotifier()
        let (dog, controller, _, _, _) = makeDog(desiredOn: false, notifier: notifier)
        controller.failNext = VpnControlError.signatureVerificationFailed
        await dog.handle(.connected)
        #expect(notifier.signatureInvalidCalls == 1)
    }

    @Test("signature notification fires only once even after repeated failures")
    func signatureNotificationFiredOnlyOnce() async {
        let notifier = RecordingLoginItemNotifier()
        let (dog, controller, time, _, _) = makeDog(desiredOn: true, notifier: notifier)
        controller.failNext = VpnControlError.signatureVerificationFailed
        await dog.handle(.disconnected)    // fires notification
        time.advance(by: 2.5)
        controller.failNext = VpnControlError.signatureVerificationFailed
        await dog.handle(.disconnected)    // backoff elapsed → retries, but no second notification
        #expect(notifier.signatureInvalidCalls == 1)
    }

    @Test("non-signature errors do not fire security notification")
    func otherErrorsDoNotNotify() async {
        let notifier = RecordingLoginItemNotifier()
        let (dog, controller, _, _, _) = makeDog(desiredOn: true, notifier: notifier)
        controller.failNext = FakeError("network timeout")
        await dog.handle(.disconnected)
        #expect(notifier.signatureInvalidCalls == 0)
    }
}

/// A controller whose `connect()` genuinely suspends, opening the actor
/// reentrancy window that an instantly-returning fake hides.
private final class SlowVpnController: VpnControlling, @unchecked Sendable {
    private let delay: Duration
    private let lock = AsyncSafeLock()
    private var _connectCount = 0

    init(delay: Duration) { self.delay = delay }

    var connectCount: Int { lock.withLock { _connectCount } }

    func connect() async throws {
        lock.withLock { _connectCount += 1 }
        try? await Task.sleep(for: delay)
    }

    func disconnect() async throws {
        try? await Task.sleep(for: delay)
    }
}

private func makeDog(
    desiredOn: Bool,
    connectingGrace: Duration = .seconds(15),
    initialBackoff: Duration = .seconds(2),
    notifier: RecordingLoginItemNotifier = RecordingLoginItemNotifier()
) -> (Watchdog, RecordingVpnController, FakeTimeSource, RecordingStateSink, RecordingLoginItemNotifier) {
    let controller = RecordingVpnController()
    let sink = RecordingStateSink()
    let desired = StaticDesiredState(desiredOn)
    let time = FakeTimeSource()
    let dog = Watchdog(
        controller: controller,
        stateSink: sink,
        desired: desired,
        time: time,
        notifier: notifier,
        connectingGrace: connectingGrace,
        initialBackoff: initialBackoff
    )
    return (dog, controller, time, sink, notifier)
}
