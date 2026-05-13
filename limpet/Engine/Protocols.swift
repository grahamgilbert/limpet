// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

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

public protocol AppNotifying: Sendable {
    func notifyRequiresApproval()
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
