// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Testing
@testable import limpet

@Suite("Watchdog reconciliation")
struct WatchdogTests {
    @Test("desired-on, sees .disconnected → calls connect once")
    func desiredOnDisconnectedConnectsOnce() async {
        let (dog, controller, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1)
    }

    @Test("desired-on, sees .connecting → does not click")
    func desiredOnConnectingNoOp() async {
        let (dog, controller, _, _) = makeDog(desiredOn: true)
        await dog.handle(.connecting)
        #expect(controller.connectCount == 0)
        #expect(controller.disconnectCount == 0)
    }

    @Test("desired-on, sees .connected → does not click")
    func desiredOnConnectedNoOp() async {
        let (dog, controller, _, _) = makeDog(desiredOn: true)
        await dog.handle(.connected)
        #expect(controller.connectCount == 0)
    }

    @Test("desired-off, sees .connected → calls disconnect")
    func desiredOffConnectedDisconnects() async {
        let (dog, controller, _, _) = makeDog(desiredOn: false)
        await dog.handle(.connected)
        #expect(controller.disconnectCount == 1)
    }

    @Test("desired-off, sees .connecting → calls disconnect")
    func desiredOffConnectingDisconnects() async {
        let (dog, controller, _, _) = makeDog(desiredOn: false)
        await dog.handle(.connecting)
        #expect(controller.disconnectCount == 1)
    }

    @Test("desired-off, sees .disconnected → no-op")
    func desiredOffDisconnectedNoOp() async {
        let (dog, controller, _, _) = makeDog(desiredOn: false)
        await dog.handle(.disconnected)
        #expect(controller.disconnectCount == 0)
    }

    @Test("desired-on, sees .disabled → calls connect")
    func desiredOnDisabledConnects() async {
        let (dog, controller, _, _) = makeDog(desiredOn: true)
        await dog.handle(.disabled)
        #expect(controller.connectCount == 1)
    }

    @Test("rapid .disconnected events → backoff prevents click storm")
    func backoffPreventsClickStorm() async {
        let (dog, controller, time, _) = makeDog(desiredOn: true)
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
        let (dog, controller, time, _) = makeDog(desiredOn: true)
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
        let (dog, controller, time, _) = makeDog(desiredOn: true)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 1)

        time.advance(by: 0.1)
        await dog.handle(.connected)
        // No click; backoff is reset.

        time.advance(by: 0.1)
        await dog.handle(.disconnected)
        #expect(controller.connectCount == 2) // immediate, despite tiny gap
    }

    @Test("desired-on .connecting does not click until grace expires")
    func connectingGrace() async {
        let (dog, controller, time, _) = makeDog(desiredOn: true, connectingGrace: .seconds(15))
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
        let (dog, _, _, sink) = makeDog(desiredOn: true)
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
        let (dog, controller, time, _) = makeDog(desiredOn: false)
        await dog.handle(.connected)
        #expect(controller.disconnectCount == 1)

        await dog.handle(.connected)
        #expect(controller.disconnectCount == 1)

        time.advance(by: 2.5)
        await dog.handle(.connected)
        #expect(controller.disconnectCount == 2)
    }
}

private func makeDog(
    desiredOn: Bool,
    connectingGrace: Duration = .seconds(15),
    initialBackoff: Duration = .seconds(2)
) -> (Watchdog, RecordingVpnController, FakeTimeSource, RecordingStateSink) {
    let controller = RecordingVpnController()
    let sink = RecordingStateSink()
    let desired = StaticDesiredState(desiredOn)
    let time = FakeTimeSource()
    let dog = Watchdog(
        controller: controller,
        stateSink: sink,
        desired: desired,
        time: time,
        connectingGrace: connectingGrace,
        initialBackoff: initialBackoff
    )
    return (dog, controller, time, sink)
}
