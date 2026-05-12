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
        let status = SMAppService.mainApp.status
        Self.log.debug("SMAppService.mainApp.status = \(status.rawValue) (\(Self.describe(status)))")
        switch status {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return false
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
