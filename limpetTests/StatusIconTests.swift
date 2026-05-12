import Testing
@testable import limpet

@Suite("ConnectionState UI helpers")
struct StatusIconTests {
    @Test("menuLabel covers every case", arguments: [
        (ConnectionState.connected, "Connected"),
        (ConnectionState.connecting, "Connecting…"),
        (ConnectionState.disconnected, "Disconnected"),
        (ConnectionState.disabled, "GlobalProtect disabled"),
        (ConnectionState.unknown, "Status unknown"),
    ])
    func menuLabels(state: ConnectionState, expected: String) {
        #expect(state.menuLabel == expected)
    }

    @Test("menuBarSystemImage covers every case", arguments: [
        ConnectionState.connected,
        .connecting,
        .disconnected,
        .disabled,
        .unknown,
    ])
    func everyStateHasASymbol(state: ConnectionState) {
        #expect(!state.menuBarSystemImage.isEmpty)
    }

    @Test("description matches enum case name", arguments: [
        (ConnectionState.connected, "connected"),
        (.connecting, "connecting"),
        (.disconnected, "disconnected"),
        (.disabled, "disabled"),
        (.unknown, "unknown"),
    ])
    func descriptions(state: ConnectionState, expected: String) {
        #expect(state.description == expected)
    }
}
