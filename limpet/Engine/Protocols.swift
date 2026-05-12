import Foundation

public protocol VpnControlling: Sendable {
    func connect() async throws
    func disconnect() async throws
}

public protocol VpnStatusStreaming: Sendable {
    var stream: AsyncStream<ConnectionState> { get }
}

public protocol PopupDismissing: Sendable {
    /// Run one scan-and-dismiss pass. Returns `true` if a popup was dismissed.
    @discardableResult
    func tick() async -> Bool
}

public protocol LoginItemRegistering: Sendable {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}
