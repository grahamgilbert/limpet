// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import AppKit
import Foundation

/// Detects whether GlobalProtect is installed. limpet is useless without it,
/// so on launch we surface a clear message instead of silently watchdog-ing
/// a state that will never change.
enum GlobalProtectInstallation {
    static let bundleID = "com.paloaltonetworks.GlobalProtect.client"

    /// Standard install path on macOS. PAN doesn't ship a portable copy, so
    /// any install lands here.
    private static let appPath = "/Applications/GlobalProtect.app"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
    }

    /// Show a blocking alert if GP isn't installed and quit. Returns `true`
    /// if the alert was shown (and so the caller should skip wiring up the
    /// rest of the app).
    @MainActor
    @discardableResult
    static func warnIfMissing() -> Bool {
        guard !isInstalled else { return false }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "GlobalProtect is not installed"
        alert.informativeText = """
            limpet keeps the GlobalProtect VPN client connected and dismisses \
            its disconnect popups, so it can't do anything without GlobalProtect \
            installed at /Applications/GlobalProtect.app.

            Install GlobalProtect from your IT department or Palo Alto's portal, \
            then launch limpet again.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Install Page")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let url = URL(string: "https://docs.paloaltonetworks.com/globalprotect") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
        return true
    }
}
