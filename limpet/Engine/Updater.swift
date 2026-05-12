import Foundation
import Observation
import Sparkle

/// SwiftUI-friendly wrapper around `SPUStandardUpdaterController`. Surfaces
/// the toggle "automatically check for updates" as an `@Observable` property
/// and exposes a `checkForUpdates()` method bound to a button.
///
/// Sparkle 2 handles the update prompt, signature verification, download,
/// and in-place install. We just need to feed it an appcast URL (set in
/// Info.plist as `SUFeedURL`) and an EdDSA public key (`SUPublicEDKey`).
@MainActor
@Observable
public final class Updater {
    private let controller: SPUStandardUpdaterController

    /// Indirection so SwiftUI re-renders when Sparkle's defaults change.
    public var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    public init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Default automatic update checks to on for first-time users. Sparkle
        // persists user choices in NSUserDefaults under SUEnableAutomaticChecks,
        // so subsequent runs respect what they've toggled.
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            controller.updater.automaticallyChecksForUpdates = true
        }
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        // Daily check cadence.
        self.controller.updater.updateCheckInterval = 86_400
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    public var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    public var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
