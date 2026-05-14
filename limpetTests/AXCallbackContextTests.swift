// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Testing
@testable import limpet

// Regression test: concurrent AXObserver notifications were spawning a new
// tick() Task each time, causing many concurrent AX tree walks and high energy
// usage. scheduleTickIfIdle() must only allow one tick in flight at a time.
@Suite("AXCallbackContext")
struct AXCallbackContextTests {

    @Test("scheduleTickIfIdle runs tick exactly once for a single call")
    func singleCallRunsOneTick() async {
        let counter = TickCounter()
        let dismisser = CountingDismisser(counter: counter)
        let ctx = AXCallbackContext(dismisser: dismisser, isEnabled: { true })

        ctx.scheduleTickIfIdle()
        // Give the task time to complete
        try? await Task.sleep(for: .milliseconds(100))

        #expect(counter.count == 1)
    }

    @Test("scheduleTickIfIdle drops concurrent calls while a tick is in flight")
    func concurrentCallsCoalesceToOneTick() async {
        let gate = AsyncGate()
        let counter = TickCounter()
        let dismisser = GatedDismisser(counter: counter, gate: gate)
        let ctx = AXCallbackContext(dismisser: dismisser, isEnabled: { true })

        // First call — starts a tick that blocks on the gate
        ctx.scheduleTickIfIdle()
        // Rapid subsequent calls should all be dropped
        for _ in 0..<10 { ctx.scheduleTickIfIdle() }

        // Unblock the in-flight tick
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(counter.count == 1)
    }

    @Test("scheduleTickIfIdle allows a new tick after the previous one finishes")
    func allowsNewTickAfterCompletion() async {
        let counter = TickCounter()
        let dismisser = CountingDismisser(counter: counter)
        let ctx = AXCallbackContext(dismisser: dismisser, isEnabled: { true })

        ctx.scheduleTickIfIdle()
        try? await Task.sleep(for: .milliseconds(100))
        ctx.scheduleTickIfIdle()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(counter.count == 2)
    }

    @Test("scheduleTickIfIdle respects isEnabled=false")
    func doesNotTickWhenDisabled() async {
        let counter = TickCounter()
        let dismisser = CountingDismisser(counter: counter)
        let ctx = AXCallbackContext(dismisser: dismisser, isEnabled: { false })

        ctx.scheduleTickIfIdle()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(counter.isEmpty)
    }
}

// MARK: - Helpers

private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    var isEmpty: Bool { lock.withLock { _count == 0 } }
    func increment() { lock.withLock { _count += 1 } }
}

private final class CountingDismisser: PopupDismissing, @unchecked Sendable {
    private let counter: TickCounter
    init(counter: TickCounter) { self.counter = counter }
    func tick() async -> Bool { counter.increment(); return false }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _isOpen = false
    var isOpen: Bool { lock.withLock { _isOpen } }
    func open() { lock.withLock { _isOpen = true } }
}

private final class GatedDismisser: PopupDismissing, @unchecked Sendable {
    private let counter: TickCounter
    private let gate: AsyncGate
    init(counter: TickCounter, gate: AsyncGate) {
        self.counter = counter
        self.gate = gate
    }
    func tick() async -> Bool {
        counter.increment()
        while !gate.isOpen {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
