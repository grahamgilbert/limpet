import Foundation
import Testing
@testable import limpet

@Suite("parsePanGPSLine")
struct ParsePanGPSLineTests {
    @Test("connected continuation line", arguments: [
        " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.",
        " m_bHibernate is 1, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 1.",
    ])
    func connected(line: String) {
        #expect(parsePanGPSLine(line) == .connected)
    }

    @Test("disconnected — agent enabled, not connected, not retrying")
    func disconnected() {
        let line = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0."
        #expect(parsePanGPSLine(line) == .disconnected)
    }

    @Test("connecting — agent enabled, not connected, retry=1")
    func connecting() {
        let line = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 1, IsConnected() is 0, IsVPNInRetry() is 1."
        #expect(parsePanGPSLine(line) == .connecting)
    }

    @Test("disabled — agent disabled overrides everything", arguments: [
        " m_bHibernate is 0, m_bAgentEnabled is 0, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.",
        " m_bHibernate is 0, m_bAgentEnabled is 0, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 0.",
    ])
    func disabled(line: String) {
        #expect(parsePanGPSLine(line) == .disabled)
    }

    @Test("non-state lines return nil", arguments: [
        "",
        "P 967-T259   05/11/2026 18:01:06:742 Debug( 366): receive sig 20",
        "P 967-T32987 05/11/2026 18:01:09:952 Debug(7974): NetworkConnectionMonitorThread: m_state = 0, m_bOnDemand=1, m_bAgentEnabled=1, m_bJustResumed is 0,",
        "P 967-T32987 05/11/2026 18:01:09:981 Debug(8031): NetworkConnectionMonitorThread: Detected route change, but skip network discovery.",
        "garbage",
        " m_bHibernate is 0, no other flags here",
    ])
    func nonState(line: String) {
        #expect(parsePanGPSLine(line) == nil)
    }

    @Test("real fixtures match expected states", arguments: [
        ("pangps_connected", ConnectionState.connected),
        ("pangps_disconnected", ConnectionState.disconnected),
        ("pangps_retry", ConnectionState.connecting),
        ("pangps_disabled", ConnectionState.disabled),
    ])
    func fixtures(name: String, expected: ConnectionState) throws {
        let path = try fixturePath(name)
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let lastParsed = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parsePanGPSLine(String($0)) }
            .last
        #expect(lastParsed == expected)
    }

    @Test("mixed run yields the final state from the last parseable line")
    func mixedRun() throws {
        let path = try fixturePath("pangps_mixed_run")
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let parsed = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parsePanGPSLine(String($0)) }
        #expect(parsed == [.disconnected, .connecting, .connected])
    }

    @Test("connected wins over retry when both flags are 1 (real GP never does this, but parse should be deterministic)")
    func connectedBeatsRetry() {
        let line = " m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 1, IsVPNInRetry() is 1."
        #expect(parsePanGPSLine(line) == .connected)
    }
}

private final class TestBundleMarker {}

private func fixturePath(_ name: String) throws -> String {
    let bundle = Bundle(for: TestBundleMarker.self)
    if let url = bundle.url(forResource: name, withExtension: "txt") {
        return url.path
    }
    if let url = bundle.url(forResource: "Fixtures/\(name)", withExtension: "txt") {
        return url.path
    }
    throw FixtureMissingError(name: name)
}

private struct FixtureMissingError: Error, CustomStringConvertible {
    let name: String
    var description: String { "Missing fixture: \(name)" }
}
