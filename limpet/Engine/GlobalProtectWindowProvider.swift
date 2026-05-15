// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

@preconcurrency import ApplicationServices
import AppKit
import Foundation

// MARK: - Generic window parsing (testable without real AXUIElements)

/// Accessors for a node in a GP popup AX tree.
/// Parameterised so the parser works with both live `AXUIElement` trees and
/// `GPFakeNode` stubs in unit tests.
struct GPWindowAccessors<Node>: @unchecked Sendable {
    let role: (Node) -> String?
    let value: (Node) -> String?
    let title: (Node) -> String?
    let children: (Node) -> [Node]
}

extension GPWindowAccessors where Node == AXUIElement {
    static let live = GPWindowAccessors(
        role: AX.role,
        value: AX.value,
        title: AX.title,
        children: AX.children
    )
}

enum GPWindowParser {
    /// Returns the window title, falling back to the first top-level
    /// AXStaticText value when kAXTitleAttribute is empty (idle-timeout popup
    /// layout renders the title as a static text node, not a window attribute).
    static func title<N>(in window: N, using ax: GPWindowAccessors<N>) -> String? {
        if let t = ax.title(window), !t.isEmpty { return t }
        return ax.children(window)
            .first(where: { ax.role($0) == kAXStaticTextRole as String })
            .flatMap { ax.value($0) }
    }

    /// Finds the body text of a GP popup window.
    ///
    /// GP renders popups in two layouts:
    /// - Classic alert: `scroll area → container → static text`
    /// - Idle-timeout: `scroll area → AXWebArea → static text`
    ///
    /// Falls back to DFS through non-static-text window children.
    static func bodyText<N>(in window: N, using ax: GPWindowAccessors<N>) -> String? {
        let children = ax.children(window)
        if let scrollArea = children.first(where: { ax.role($0) == kAXScrollAreaRole as String }) {
            for child in ax.children(scrollArea) {
                // Classic path: scroll area → container → static text
                if let staticText = ax.children(child).first(where: { ax.role($0) == kAXStaticTextRole as String })
                    ?? (ax.role(child) == kAXStaticTextRole as String ? child : nil),
                   let value = ax.value(staticText) {
                    return value
                }
                // Web-rendered path: scroll area → AXWebArea → static text
                if ax.role(child) == "AXWebArea",
                   let staticText = AX.findNode(child, children: ax.children, where: { ax.role($0) == kAXStaticTextRole as String }),
                   let value = ax.value(staticText) {
                    return value
                }
            }
        }
        // Deep fallback: skip direct window children (title/subtitle nodes)
        for child in children where ax.role(child) != kAXStaticTextRole as String {
            if let staticText = AX.findNode(child, children: ax.children, where: { ax.role($0) == kAXStaticTextRole as String }),
               let value = ax.value(staticText) {
                return value
            }
        }
        return nil
    }
}

// MARK: - Live provider

/// Walks the GlobalProtect process via Accessibility and returns its windows
/// as `PopupWindow` snapshots. Each snapshot's `pressPrimary` closure presses
/// the **first button** in the window — which matches gp-bye's
/// "click button 1 of w" behavior.
///
/// Window title/body extraction is delegated to `GPWindowParser` which is
/// unit-tested independently using `GPFakeNode` stubs.
public final class GlobalProtectWindowProvider: WindowProvider, @unchecked Sendable {
    private static let bundleID = GlobalProtectInstallation.bundleID
    private let verifier = GPCodeSignatureVerifier()

    public init() {}

    public func currentWindows() -> [PopupWindow] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first,
              verifier.verify(app: app) else {
            return []
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return AX.windows(appElement).map { window in
            let title = GPWindowParser.title(in: window, using: .live)
            let body = GPWindowParser.bodyText(in: window, using: .live)
            let firstButton = AX.find(window, where: { AX.role($0) == kAXButtonRole as String })
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
}
