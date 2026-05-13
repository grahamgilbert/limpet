// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import UserNotifications

/// Real implementation backed by `UNUserNotificationCenter`. Authorization is
/// requested lazily on first use — if denied, the call silently no-ops.
public struct SystemLoginItemNotifier: LoginItemNotifying, SecurityNotifying {
    public init() {}

    public func notifyRequiresApproval() {
        post(
            identifier: "limpet.loginItemRequiresApproval",
            title: "limpet needs approval",
            body: "Open System Settings → General → Login Items & Extensions and turn limpet on so it can launch at login."
        )
    }

    public func notifyGlobalProtectSignatureInvalid() {
        post(
            identifier: "limpet.globalProtectSignatureInvalid",
            title: "Security warning — GlobalProtect",
            body: "A process claiming to be GlobalProtect failed code-signature verification. limpet has stopped controlling it. Check your system for unauthorized software."
        )
    }

    private func post(identifier: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request)
        }
    }
}
