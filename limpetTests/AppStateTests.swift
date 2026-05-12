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
}
