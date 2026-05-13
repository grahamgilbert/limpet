// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Observation
import Sparkle

private enum AppcastURL {
    static let stable = "https://raw.githubusercontent.com/grahamgilbert/limpet/main/appcast.xml"
    static let prerelease = "https://raw.githubusercontent.com/grahamgilbert/limpet/main/appcast-prerelease.xml"
}

// Sparkle calls feedURLString before every update check, so toggling the
// prerelease preference takes effect at the next check without a restart.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var wantsPrereleases: () -> Bool = { false }

    func feedURLString(for updater: SPUUpdater) -> String? {
        wantsPrereleases() ? AppcastURL.prerelease : AppcastURL.stable
    }
}

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
    private let delegate = UpdaterDelegate()

    /// Indirection so SwiftUI re-renders when Sparkle's defaults change.
    public var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    public init(defaults: UserDefaults = .standard) {
        let key = Preferences.installPrereleasesKey
        delegate.wantsPrereleases = { defaults.bool(forKey: key) }
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        // Default automatic update checks to on for first-time users. Sparkle
        // persists user choices in NSUserDefaults under SUEnableAutomaticChecks,
        // so subsequent runs respect what they've toggled.
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil {
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
