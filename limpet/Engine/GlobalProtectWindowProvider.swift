// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Walks the GlobalProtect process via Accessibility and returns its windows
/// as `PopupWindow` snapshots. Each snapshot's `pressPrimary` closure presses
/// the **first button** in the window — which matches gp-bye's
/// "click button 1 of w" behavior.
///
/// This file is intentionally excluded from coverage thresholds: it can only
/// run against a live macOS GUI session with GlobalProtect installed and
/// Accessibility permission granted, so it's covered by manual verification,
/// not by unit tests.
public final class GlobalProtectWindowProvider: WindowProvider, @unchecked Sendable {
    private static let bundleID = "com.paloaltonetworks.GlobalProtect.client"
    private let verifier = GPCodeSignatureVerifier()

    public init() {}

    public func currentWindows() -> [PopupWindow] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first,
              verifier.verify(app: app) else {
            return []
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return AX.windows(appElement).map { window in
            let title = AX.title(window)
            let body = Self.findStaticTextValue(in: window)
            let firstButton = Self.findFirstButton(in: window)
            return PopupWindow(
                title: title,
                bodyText: body,
                pressPrimary: { [firstButton] in
                    guard let firstButton else { return false }
                    return AX.press(firstButton)
                }
            )
        }
    }

    /// Mirrors AppleScript's `static text 1 of UI element 1 of scroll area 1 of w`.
    /// Falls back to depth-first search for any static text if that exact
    /// path doesn't match (GP's AX tree shifts between releases).
    private static func findStaticTextValue(in window: AXUIElement) -> String? {
        if let scrollArea = AX.children(window).first(where: { AX.role($0) == kAXScrollAreaRole as String }),
           let firstChild = AX.children(scrollArea).first,
           let staticText = AX.children(firstChild).first(where: { AX.role($0) == kAXStaticTextRole as String })
                ?? (AX.role(firstChild) == kAXStaticTextRole as String ? firstChild : nil),
           let value = AX.value(staticText) {
            return value
        }
        if let staticText = AX.find(window, where: { AX.role($0) == kAXStaticTextRole as String }),
           let value = AX.value(staticText) {
            return value
        }
        return nil
    }

    private static func findFirstButton(in window: AXUIElement) -> AXUIElement? {
        AX.find(window, where: { AX.role($0) == kAXButtonRole as String })
    }
}
