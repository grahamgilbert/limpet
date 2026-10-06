// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Testing
@testable import limpet

@Suite("VPNToggleState — toggle position and spinner gating")
struct VPNToggleStateTests {

    // MARK: - connectionIsOn / displayedOn (no pending manual action)

    @Test("connected and connecting read as on; others read as off")
    func connectionIsOnMapping() {
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .connected).connectionIsOn)
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .connecting).connectionIsOn)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .disconnected).connectionIsOn)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .disabled).connectionIsOn)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .unknown).connectionIsOn)
    }

    @Test("with no pending action, displayed toggle follows the real connection")
    func displayedFollowsRealityWhenNotPending() {
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .connected).displayedOn)
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .connecting).displayedOn)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .disconnected).displayedOn)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .unknown).displayedOn)
    }

    // MARK: - displayedOn optimistic override

    @Test("a pending manual action wins over the real connection state")
    func pendingIntentOverridesReality() {
        // User just asked to turn ON while reality is still disconnected.
        #expect(VPNToggleState(pendingDesiredOn: true, connection: .disconnected).displayedOn)
        // User just asked to turn OFF while reality is still connected.
        #expect(!VPNToggleState(pendingDesiredOn: false, connection: .connected).displayedOn)
    }

    // MARK: - isPending (spinner gating)

    @Test("spinner shows whenever a manual action is pending, regardless of state")
    func spinnerShowsWhilePending() {
        for state in [ConnectionState.connected, .connecting, .disconnected, .disabled, .unknown] {
            #expect(VPNToggleState(pendingDesiredOn: true, connection: state).isPending)
            #expect(VPNToggleState(pendingDesiredOn: false, connection: state).isPending)
        }
    }

    @Test("spinner shows during a watchdog-driven connect with no pending manual action")
    func spinnerShowsWhileConnectingWithoutPending() {
        // This is the regression the change targets: auto-reconnect surfaces
        // .connecting with pendingDesiredOn == nil, and must still spin.
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .connecting).isPending)
    }

    @Test("spinner is hidden once connected (or otherwise settled) with no pending action")
    func spinnerHiddenWhenSettled() {
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .connected).isPending)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .disconnected).isPending)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .disabled).isPending)
        #expect(!VPNToggleState(pendingDesiredOn: nil, connection: .unknown).isPending)
    }
}

@Suite("VPNToggleState — activity")
struct VPNToggleActivityTests {
    @Test("pending off reads as disconnecting even while still connected")
    func disconnecting() {
        #expect(VPNToggleState(pendingDesiredOn: false, connection: .connected).activity == .disconnecting)
    }

    @Test("pending on, GP retry and watchdog connect all read as connecting")
    func connecting() {
        #expect(VPNToggleState(pendingDesiredOn: true, connection: .disconnected).activity == .connecting)
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .connecting).activity == .connecting)
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .disconnected, isReconnecting: true).activity == .connecting)
    }

    @Test("settled states have no activity")
    func settled() {
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .connected).activity == nil)
        #expect(VPNToggleState(pendingDesiredOn: nil, connection: .disconnected).activity == nil)
    }

    @Test("paused hides all activity, even while GP is still connecting")
    func pausedHasNoActivity() {
        let paused = VPNToggleState(pendingDesiredOn: nil, connection: .connecting, isPaused: true)
        #expect(paused.activity == nil)
        #expect(!paused.isPending)
    }
}
