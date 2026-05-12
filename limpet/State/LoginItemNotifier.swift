// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import UserNotifications

/// Surfaces login-item state transitions as user-visible notifications.
/// Injectable so tests don't fire real system notifications.
public protocol LoginItemNotifying: Sendable {
    func notifyRequiresApproval()
}

/// Real implementation backed by `UNUserNotificationCenter`. Authorization is
/// requested lazily on first use — if denied, the call silently no-ops.
public struct SystemLoginItemNotifier: LoginItemNotifying {
    public init() {}

    public func notifyRequiresApproval() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "limpet needs approval"
            content.body = "Open System Settings → General → Login Items & Extensions and turn limpet on so it can launch at login."
            let request = UNNotificationRequest(
                identifier: "limpet.loginItemRequiresApproval",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
