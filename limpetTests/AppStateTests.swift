// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Testing
@testable import limpet

@Suite("AppState")
struct AppStateTests {
    @Test @MainActor
    func defaultStateIsUnknown() {
        let s = AppState()
        #expect(s.connection == .unknown)
        #expect(s.lastError == nil)
    }

    @Test @MainActor
    func customInitialState() {
        let s = AppState(connection: .connected)
        #expect(s.connection == .connected)
    }

    @Test @MainActor
    func mutationsAreVisible() {
        let s = AppState()
        s.connection = .connecting
        #expect(s.connection == .connecting)
        s.lastError = "kaboom"
        #expect(s.lastError == "kaboom")
    }

    @Test
    func updateFromBackgroundIsThreadSafe() async {
        let s = await AppState()
        s.update(.connected)
        // The update is hopped onto the main actor — wait briefly.
        try? await Task.sleep(for: .milliseconds(50))
        let value = await s.connection
        #expect(value == .connected)
    }

    @Test
    func setReconnectingFromBackgroundIsApplied() async {
        let s = await AppState()
        s.setReconnecting(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await s.isReconnecting)
        s.setReconnecting(false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await !s.isReconnecting)
    }

    @Test @MainActor
    func activityFollowsPendingIntentAndReconnecting() {
        let s = AppState(connection: .connected)
        #expect(s.activity == nil)
        s.pendingDesiredOn = false
        #expect(s.activity == .disconnecting)
        s.pendingDesiredOn = nil
        s.isReconnecting = true
        #expect(s.activity == .connecting)
    }

    @Test @MainActor
    func blinkRunsOnlyWhileActive() async {
        let s = AppState(connection: .connected)
        s.trackBlink()
        #expect(!s.blinkDim)

        s.isReconnecting = true
        try? await Task.sleep(for: .milliseconds(700))
        #expect(s.blinkDim)

        s.isReconnecting = false
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!s.blinkDim)
    }
}
