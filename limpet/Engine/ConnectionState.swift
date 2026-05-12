import Foundation

public enum ConnectionState: Equatable, Sendable, CustomStringConvertible {
    case connected
    case connecting
    case disconnected
    case disabled
    case unknown

    public var description: String {
        switch self {
        case .connected: "connected"
        case .connecting: "connecting"
        case .disconnected: "disconnected"
        case .disabled: "disabled"
        case .unknown: "unknown"
        }
    }
}

/// Parses a single line from `PanGPS.log` into a `ConnectionState`.
///
/// The line of interest is the *continuation* line of the periodic
/// `NetworkConnectionMonitorThread` record, which on macOS GP 6.2.8 looks like:
///
///     ` m_bHibernate is 0, m_bAgentEnabled is 1, m_bDisconnect is 0, IsConnected() is 0, IsVPNInRetry() is 0.`
///
/// (The header line, with `m_state = …, m_bOnDemand=…`, doesn't contain the
/// agent-enabled flag in its trailing form, so we key off the continuation.)
///
/// Returns `nil` for any line that doesn't carry the four flags.
public func parsePanGPSLine(_ line: String) -> ConnectionState? {
    let agent = extractFlag(line, key: "m_bAgentEnabled is")
    let connected = extractFlag(line, key: "IsConnected() is")
    let retry = extractFlag(line, key: "IsVPNInRetry() is")

    guard let agent, let connected, let retry else { return nil }

    if agent == 0 { return .disabled }
    if connected == 1 { return .connected }
    if retry == 1 { return .connecting }
    return .disconnected
}

private func extractFlag(_ line: String, key: String) -> Int? {
    guard let range = line.range(of: key) else { return nil }
    let after = line[range.upperBound...]
    let trimmed = after.drop { $0 == " " }
    let digits = trimmed.prefix { $0.isNumber }
    return Int(digits)
}
