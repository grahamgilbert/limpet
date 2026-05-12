// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import OSLog
import ServiceManagement

/// Real `LoginItemRegistering` backed by `SMAppService.mainApp`.
///
/// `isRegistered` returns true for any state where the system intends to
/// launch us at login: `.enabled` (active) or `.requiresApproval` (the user
/// needs to flip a switch in System Settings → General → Login Items, but
/// limpet *is* registered as a login item).
public struct SMAppServiceLoginItem: LoginItemRegistering {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "loginitem")

    public init() {}

    public var isRegistered: Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound, .unknown: false
        }
    }

    public var status: LoginItemStatus {
        let raw = SMAppService.mainApp.status
        Self.log.debug("SMAppService.mainApp.status = \(raw.rawValue) (\(Self.describe(raw)))")
        switch raw {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
        Self.log.info("SMAppService.register: status=\(Self.describe(SMAppService.mainApp.status))")
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
        Self.log.info("SMAppService.unregister: status=\(Self.describe(SMAppService.mainApp.status))")
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
