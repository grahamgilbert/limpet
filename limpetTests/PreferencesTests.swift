import Foundation
import Testing
@testable import limpet

@Suite("Preferences + DesiredStateProxy")
struct PreferencesTests {
    @Test @MainActor
    func defaultsTrueOnFirstLaunch() throws {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults, loginItem: FakeLoginItem())
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
    func startAtLoginRegistersAndUnregisters() {
        let login = FakeLoginItem(initiallyRegistered: false)
        let prefs = Preferences(defaults: freshDefaults(), loginItem: login)

        #expect(prefs.startAtLogin == false)
        prefs.startAtLogin = true
        #expect(login.isRegistered == true)
        #expect(prefs.startAtLogin == true)

        prefs.startAtLogin = false
        #expect(login.isRegistered == false)
    }

    @Test @MainActor
    func startAtLoginSurfacesError() {
        let login = FakeLoginItem()
        login.failOnRegister = FakeError("can't register")
        let prefs = Preferences(defaults: freshDefaults(), loginItem: login)
        prefs.startAtLogin = true
        #expect(prefs.lastLoginItemError != nil)
        #expect(login.isRegistered == false)
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
