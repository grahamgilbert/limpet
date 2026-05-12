// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Observation
import ServiceManagement

/// User preferences exposed to SwiftUI. Owned by `@MainActor`.
///
/// `desiredOn` is mirrored to `UserDefaults` so it survives relaunches and
/// can be read off-main-actor by `Watchdog` via `DesiredStateProxy`.
///
/// `startAtLogin` is a live read-through / write-through to
/// `SMAppService.mainApp` (or a faked impl in tests).
@MainActor
@Observable
public final class Preferences {
    private let defaults: UserDefaults
    private let loginItem: LoginItemRegistering
    fileprivate nonisolated static let desiredOnKey = "limpet.desiredOn"
    fileprivate nonisolated static let hasLaunchedBeforeKey = "limpet.hasLaunchedBefore"

    public var desiredOn: Bool {
        didSet { defaults.set(desiredOn, forKey: Self.desiredOnKey) }
    }

    /// `true` once limpet has successfully launched at least once.
    public var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Self.hasLaunchedBeforeKey) }
        set { defaults.set(newValue, forKey: Self.hasLaunchedBeforeKey) }
    }

    /// Stored, observable mirror of the system's login-item state. The setter
    /// calls `SMAppService` and re-reads to ensure UI reflects reality even
    /// when registration silently fails.
    public var startAtLogin: Bool {
        didSet {
            guard !suppressLoginItemSync, startAtLogin != oldValue else { return }
            applyStartAtLogin(startAtLogin)
        }
    }

    /// Mirrors `loginItem.status` so SwiftUI can show a "needs approval" hint.
    public var loginItemStatus: LoginItemStatus

    public var lastLoginItemError: String?

    private var suppressLoginItemSync = false

    /// Side-effect notifier; injectable so tests don't fire system notifications.
    private let notifier: LoginItemNotifying

    public init(
        defaults: UserDefaults = .standard,
        loginItem: LoginItemRegistering = SMAppServiceLoginItem(),
        notifier: LoginItemNotifying = SystemLoginItemNotifier()
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.notifier = notifier
        if defaults.object(forKey: Self.desiredOnKey) == nil {
            defaults.set(true, forKey: Self.desiredOnKey)
        }
        self.desiredOn = defaults.bool(forKey: Self.desiredOnKey)

        // First-launch defaults: opt the user into Start at Login on the very
        // first run so the VPN watchdog actually keeps the VPN up across
        // reboots without them having to opt in. We only do this once.
        let firstLaunch = !defaults.bool(forKey: Self.hasLaunchedBeforeKey)
        if firstLaunch && !loginItem.isRegistered {
            try? loginItem.register()
        }
        self.startAtLogin = loginItem.isRegistered
        self.loginItemStatus = loginItem.status
        if firstLaunch {
            defaults.set(true, forKey: Self.hasLaunchedBeforeKey)
        }

        // Periodic resync so the toggle reflects the OS even if the user
        // changed it externally (System Settings → General → Login Items).
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshLoginItemState()
            }
        }
    }

    private func applyStartAtLogin(_ wanted: Bool) {
        do {
            if wanted {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            lastLoginItemError = nil
        } catch {
            lastLoginItemError = "\(error)"
        }
        // Re-read the actual state so the UI reflects what the system did,
        // even if it differs from what we asked for. Suppress didSet while
        // we sync so we don't loop back through SMAppService.
        let actual = loginItem.isRegistered
        loginItemStatus = loginItem.status
        if actual != wanted {
            suppressLoginItemSync = true
            self.startAtLogin = actual
            suppressLoginItemSync = false
        }
    }

    /// Re-reads the system's actual login-item state and updates the
    /// observable property if it has drifted (e.g. user toggled it in
    /// System Settings). Call when the menu reopens.
    public func refreshLoginItemState() {
        let newStatus = loginItem.status
        if newStatus != loginItemStatus {
            let oldStatus = loginItemStatus
            loginItemStatus = newStatus
            if newStatus == .requiresApproval && oldStatus != .requiresApproval {
                notifier.notifyRequiresApproval()
            }
        }
        let actual = loginItem.isRegistered
        guard actual != startAtLogin else { return }
        suppressLoginItemSync = true
        startAtLogin = actual
        suppressLoginItemSync = false
    }

    /// Returns a `Sendable` proxy the `Watchdog` actor can read from off-main.
    /// Reads pass through to `UserDefaults`, which is thread-safe.
    public func desiredStateProxy() -> DesiredStateProxy {
        let snapshot = UncheckedDefaults(defaults)
        return DesiredStateProxy {
            snapshot.value.bool(forKey: Preferences.desiredOnKey)
        }
    }
}

private struct UncheckedDefaults: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}

/// `Sendable` adapter that gives the `Watchdog` a non-isolated read of
/// `desiredOn`.
public final class DesiredStateProxy: DesiredStateProviding, @unchecked Sendable {
    private let read: @Sendable () -> Bool

    public init(_ read: @escaping @Sendable () -> Bool) {
        self.read = read
    }

    public var desiredOn: Bool { read() }
}
