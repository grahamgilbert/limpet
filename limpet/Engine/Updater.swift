// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Observation
import Sparkle

private enum AppcastURL {
    static let stable = "https://raw.githubusercontent.com/grahamgilbert/limpet/main/appcast.xml"
    static let prerelease = "https://raw.githubusercontent.com/grahamgilbert/limpet/main/appcast-prerelease.xml"
}

// Because Sparkle re-invokes feedURLString per check, the delegate closure
// makes feed selection live without restarting the updater.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let wantsPrereleases: @Sendable () -> Bool

    init(wantsPrereleases: @escaping @Sendable () -> Bool) {
        self.wantsPrereleases = wantsPrereleases
    }

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
    // Sparkle holds its delegate weakly, so we must retain it here.
    private let delegate: UpdaterDelegate
    private static let sparkleAutoChecksKey = "SUEnableAutomaticChecks"

    /// Indirection so SwiftUI re-renders when Sparkle's defaults change.
    public var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    public init(wantsPrereleases: @escaping @Sendable () -> Bool = { false }) {
        let delegate = UpdaterDelegate(wantsPrereleases: wantsPrereleases)
        self.delegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        // Default automatic update checks to on for first-time users. Sparkle
        // persists user choices in NSUserDefaults under SUEnableAutomaticChecks,
        // so subsequent runs respect what they've toggled.
        if UserDefaults.standard.object(forKey: Self.sparkleAutoChecksKey) == nil {
            controller.updater.automaticallyChecksForUpdates = true
        }
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
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
