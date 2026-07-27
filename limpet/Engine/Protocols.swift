// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation

public protocol VpnControlling: Sendable {
    /// - Parameter allowRefreshFallback: permit "Refresh Connection" when no
    ///   Connect button exists. Only correct when GP is believed *stuck*: if GP
    ///   is merely mid-connect there is also no Connect button, and refreshing
    ///   then tears down a session that was about to come up.
    func connect(allowRefreshFallback: Bool) async throws
    func disconnect() async throws
}

public extension VpnControlling {
    /// A plain connect never refreshes. Callers that know GP is stuck opt in.
    func connect() async throws {
        try await connect(allowRefreshFallback: false)
    }
}

public protocol VpnStatusStreaming: Sendable {
    var stream: AsyncStream<ConnectionState> { get }
}

public protocol PopupDismissing: Sendable {
    /// Run one scan-and-dismiss pass. Returns `true` if a popup was dismissed.
    @discardableResult
    func tick() async -> Bool
}

public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    /// limpet asked the OS to register, but the user must approve in
    /// System Settings → General → Login Items & Extensions before it
    /// will actually launch at login.
    case requiresApproval
    case notFound
    case unknown
}

public protocol LoginItemNotifying: Sendable {
    func notifyRequiresApproval()
}

public protocol SecurityNotifying: Sendable {
    func notifyGlobalProtectSignatureInvalid()
}

public protocol LoginItemRegistering: Sendable {
    /// `true` for any state that means "the system intends to launch us at
    /// login": .enabled or .requiresApproval. Use `status` to distinguish.
    var isRegistered: Bool { get }
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}
