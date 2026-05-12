// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Testing
@testable import limpet

@Suite("Preferences + DesiredStateProxy")
struct PreferencesTests {
    @Test @MainActor
    func defaultsTrueOnFirstLaunch() throws {
        let prefs = Preferences(defaults: freshDefaults(), loginItem: FakeLoginItem())
        #expect(prefs.desiredOn == true)
    }

    @Test @MainActor
    func persistsDesiredOn() throws {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults, loginItem: FakeLoginItem())
        prefs.desiredOn = false

        let prefs2 = Preferences(defaults: defaults, loginItem: FakeLoginItem())
        #expect(prefs2.desiredOn == false)
    }

    @Test @MainActor
    func firstLaunchAutoRegistersLoginItem() {
        let defaults = freshDefaults()
        let login = FakeLoginItem(initiallyRegistered: false)
        let prefs = Preferences(defaults: defaults, loginItem: login)

        #expect(prefs.startAtLogin == true)
        #expect(login.isRegistered == true)
        #expect(defaults.bool(forKey: "limpet.hasLaunchedBefore") == true)
    }

    @Test @MainActor
    func subsequentLaunchesRespectExistingState() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "limpet.hasLaunchedBefore")

        let login = FakeLoginItem(initiallyRegistered: false)
        let prefs = Preferences(defaults: defaults, loginItem: login)

        #expect(prefs.startAtLogin == false)
        #expect(login.isRegistered == false)
    }

    @Test @MainActor
    func startAtLoginRegistersAndUnregisters() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "limpet.hasLaunchedBefore")

        let login = FakeLoginItem(initiallyRegistered: false)
        let prefs = Preferences(defaults: defaults, loginItem: login)

        #expect(prefs.startAtLogin == false)
        prefs.startAtLogin = true
        #expect(login.isRegistered == true)
        #expect(prefs.startAtLogin == true)

        prefs.startAtLogin = false
        #expect(login.isRegistered == false)
    }

    @Test @MainActor
    func startAtLoginSurfacesError() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "limpet.hasLaunchedBefore")

        let login = FakeLoginItem()
        login.failOnRegister = FakeError("can't register")
        let prefs = Preferences(defaults: defaults, loginItem: login)

        prefs.startAtLogin = true
        #expect(prefs.lastLoginItemError != nil)
        #expect(login.isRegistered == false)
    }

    @Test @MainActor
    func notifiesWhenLoginItemEntersRequiresApproval() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "limpet.hasLaunchedBefore")

        let login = FakeLoginItem(initialStatus: .enabled)
        let notifier = RecordingLoginItemNotifier()
        let prefs = Preferences(defaults: defaults, loginItem: login, notifier: notifier)

        #expect(notifier.calls == 0)

        login.setStatus(.requiresApproval)
        prefs.refreshLoginItemState()

        #expect(notifier.calls == 1)

        // Subsequent refreshes while still in requiresApproval shouldn't re-notify.
        prefs.refreshLoginItemState()
        #expect(notifier.calls == 1)

        // Recover, then re-enter requiresApproval — should fire again.
        login.setStatus(.enabled)
        prefs.refreshLoginItemState()
        login.setStatus(.requiresApproval)
        prefs.refreshLoginItemState()
        #expect(notifier.calls == 2)
    }

    @Test @MainActor
    func desiredStateProxyReadsThrough() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults, loginItem: FakeLoginItem())
        let proxy = prefs.desiredStateProxy()

        prefs.desiredOn = true
        #expect(proxy.desiredOn == true)
        prefs.desiredOn = false
        #expect(proxy.desiredOn == false)
    }
}

private func freshDefaults() -> UserDefaults {
    let suite = "limpet-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}
