// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Testing
@testable import limpet

@Suite("PopupDismisser")
struct PopupDismisserTests {
    @Test("disconnected text matches and dismisses")
    func disconnectedMatches() async {
        #expect(shouldDismissPopup(title: "GlobalProtect", body: "GlobalProtect: You have been disconnected from the network.") == true)
    }

    @Test("connectivity issues text matches")
    func connectivityIssuesMatches() {
        #expect(shouldDismissPopup(title: "GlobalProtect", body: "Detected connectivity issues with the gateway.") == true)
    }

    @Test("session timeout text matches")
    func sessionTimeoutMatches() {
        #expect(shouldDismissPopup(title: "GlobalProtect", body: "Your session timeout has expired.") == true)
    }

    @Test("case-insensitive body match")
    func caseInsensitive() {
        #expect(shouldDismissPopup(title: "GlobalProtect", body: "DISCONNECTED FROM VPN") == true)
    }

    @Test("non-matching title is ignored")
    func nonMatchingTitle() {
        #expect(shouldDismissPopup(title: "Some Other App", body: "you got disconnected") == false)
        #expect(shouldDismissPopup(title: nil, body: "you got disconnected") == false)
    }

    @Test("benign body in GlobalProtect window is ignored")
    func benignBody() {
        #expect(shouldDismissPopup(title: "GlobalProtect", body: "Welcome to GlobalProtect") == false)
        #expect(shouldDismissPopup(title: "GlobalProtect", body: nil) == false)
    }

    @Test("PopupDismisserImpl presses primary on a matching window")
    func dismisserImplPressesOnMatch() async {
        let provider = FakeWindowProvider()
        let counter = FakeWindowProvider.WindowCounter()
        provider.setWindows([
            PopupWindow(title: "GlobalProtect", bodyText: "you have been disconnected") {
                counter.increment(); return true
            }
        ])
        let dismisser = PopupDismisserImpl(provider: provider)
        let result = await dismisser.tick()
        #expect(result == true)
        #expect(counter.pressed == 1)
    }

    @Test("PopupDismisserImpl skips non-matching windows")
    func dismisserImplSkipsNonMatching() async {
        let provider = FakeWindowProvider()
        let counter = FakeWindowProvider.WindowCounter()
        provider.setWindows([
            PopupWindow(title: "GlobalProtect", bodyText: "Welcome") {
                counter.increment(); return true
            },
            PopupWindow(title: "Other", bodyText: "you have been disconnected") {
                counter.increment(); return true
            }
        ])
        let dismisser = PopupDismisserImpl(provider: provider)
        let result = await dismisser.tick()
        #expect(result == false)
        #expect(counter.pressed == 0)
    }

    @Test("PopupDismisserImpl returns false when press fails (e.g. button gone)")
    func pressFailureReturnsFalse() async {
        let provider = FakeWindowProvider()
        provider.setWindows([
            PopupWindow(title: "GlobalProtect", bodyText: "you have been disconnected") {
                false // press failed
            }
        ])
        let dismisser = PopupDismisserImpl(provider: provider)
        let result = await dismisser.tick()
        #expect(result == false)
    }

    @Test("multiple matching windows in one tick all get pressed")
    func multipleMatches() async {
        let provider = FakeWindowProvider()
        let counter = FakeWindowProvider.WindowCounter()
        provider.setWindows([
            PopupWindow(title: "GlobalProtect", bodyText: "you have been disconnected") {
                counter.increment(); return true
            },
            PopupWindow(title: "GlobalProtect", bodyText: "session timeout") {
                counter.increment(); return true
            }
        ])
        let dismisser = PopupDismisserImpl(provider: provider)
        _ = await dismisser.tick()
        #expect(counter.pressed == 2)
    }
}

// MARK: - PopupDismisserLoop

@Suite("PopupDismisserLoop")
struct PopupDismisserLoopTests {
    @Test("start/stop: tick is called while running, not after stop")
    func startStop() async throws {
        let counter = TickCounter()
        let loop = PopupDismisserLoop(
            dismisser: counter,
            time: SystemTimeSource(),
            fallbackInterval: .milliseconds(10)
        )
        loop.start()
        try await Task.sleep(for: .milliseconds(80))
        let countWhileRunning = counter.count
        #expect(countWhileRunning > 0)

        loop.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.count == countWhileRunning)
    }

    @Test("isEnabled=false suppresses tick calls")
    func disabledSkipsTick() async throws {
        let counter = TickCounter()
        let loop = PopupDismisserLoop(
            dismisser: counter,
            time: SystemTimeSource(),
            fallbackInterval: .milliseconds(10),
            isEnabled: { false }
        )
        loop.start()
        try await Task.sleep(for: .milliseconds(80))
        loop.stop()
        #expect(counter.count == 0) // swiftlint:disable:this empty_count
    }

    @Test("stop is idempotent")
    func stopIdempotent() async throws {
        let loop = PopupDismisserLoop(
            dismisser: TickCounter(),
            time: SystemTimeSource(),
            fallbackInterval: .milliseconds(50)
        )
        loop.start()
        try await Task.sleep(for: .milliseconds(20))
        loop.stop()
        loop.stop() // should not crash
    }

    @Test("deinit cancels the loop")
    func deinitCancels() async throws {
        let counter = TickCounter()
        var loop: PopupDismisserLoop? = PopupDismisserLoop(
            dismisser: counter,
            time: SystemTimeSource(),
            fallbackInterval: .milliseconds(10)
        )
        loop?.start()
        try await Task.sleep(for: .milliseconds(50))
        loop = nil  // triggers deinit → task cancel
        let countAtDeinit = counter.count
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.count == countAtDeinit)
    }
}

/// Simple `PopupDismissing` that just counts ticks.
private final class TickCounter: PopupDismissing, @unchecked Sendable {
    private let lock = AsyncSafeLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }

    func tick() async -> Bool {
        lock.withLock { _count += 1 }
        return false
    }
}
