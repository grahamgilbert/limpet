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
