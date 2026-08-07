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
    let subrole: (Node) -> String?
    let value: (Node) -> String?
    let title: (Node) -> String?
    let children: (Node) -> [Node]
    let isMinimizable: (Node) -> Bool
    /// The window's own close button. Read as a window attribute rather than
    /// found by walking, so it costs one AX message and can't match a close
    /// control nested somewhere inside the window's content.
    let closeButton: (Node) -> Node?
}

extension GPWindowAccessors where Node == AXUIElement {
    static let live = GPWindowAccessors(
        role: AX.role,
        subrole: AX.subrole,
        value: AX.value,
        title: AX.title,
        children: AX.children,
        isMinimizable: { AX.attribute($0, kAXMinimizeButtonAttribute as String, as: AXUIElement.self) != nil },
        closeButton: { AX.attribute($0, kAXCloseButtonAttribute as String, as: AXUIElement.self) }
    )
}

enum GPWindowParser {
    private static let buttonRole = kAXButtonRole as String

    /// Window-frame buttons: pressing one is never a dialog response.
    private static let frameButtonSubroles: Set<String> = [
        kAXCloseButtonSubrole as String,
        kAXMinimizeButtonSubrole as String,
        kAXZoomButtonSubrole as String,
        kAXFullScreenButtonSubrole as String,
    ]

    /// The button that dismisses this window, or `nil` if the window must not be
    /// auto-dismissed. Eligibility and button choice are one question because
    /// answering it costs a tree walk of a live AX process — asking twice per
    /// window per tick doubled the worst-case time spent against a wedged GP.
    ///
    /// Two window types are never dismissed:
    /// - AXSystemDialog: the GP status-item panel (pressing its button closes the panel mid-connect).
    /// - Minimizable windows with an action button: the main GP app window, whose
    ///   button is Connect/Disconnect. The session-timeout alert is *also* a
    ///   minimizable AXStandardWindow, so minimizability alone can't separate the
    ///   two — but it has no action button, only traffic lights, and gets closed
    ///   rather than pressed. That also bounds the blast radius if this ever
    ///   misjudges: a minimizable window can only be closed, never actioned.
    static func dismissButton<N>(in window: N, using ax: GPWindowAccessors<N>) -> N? {
        guard (ax.subrole(window) ?? "") != (kAXSystemDialogSubrole as String) else { return nil }
        let action = AX.findNode(
            window,
            children: ax.children,
            where: { ax.role($0) == buttonRole && !frameButtonSubroles.contains(ax.subrole($0) ?? "") }
        )
        if let action {
            return ax.isMinimizable(window) ? nil : action
        }
        // No action button (or the walk timed out looking for one — `findNode`
        // reports both as nil). Either way, close the window; do NOT fail closed
        // on a timed-out walk. The session-timeout alert has no action button,
        // so proving its absence needs a full-tree DFS through the web area, and
        // it only appears while GP is wedged — exactly when that DFS blows its
        // budget. Failing closed there left the alert up forever, the one case
        // this function exists to handle. Closing the main app window instead is
        // still gated downstream: `shouldDismissPopup` presses only on
        // disconnect/timeout body text, which the main window never has.
        return ax.closeButton(window)
    }

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

/// Walks the GlobalProtect process via Accessibility and returns its
/// auto-dismissable windows as `PopupWindow` snapshots. Each snapshot's
/// `pressPrimary` closure presses the button `GPWindowParser.dismissButton`
/// picked for that window.
///
/// Window classification and title/body extraction are delegated to
/// `GPWindowParser`, which is unit-tested independently using `GPFakeNode` stubs.
public final class GlobalProtectWindowProvider: WindowProvider, @unchecked Sendable {
    private static let bundleID = GlobalProtectInstallation.bundleID
    private let verifier = GPCodeSignatureVerifier()

    public init() {}

    public func currentWindows() -> [PopupWindow] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first,
              verifier.verify(app: app) else {
            return []
        }
        let appElement = AX.appElement(app.processIdentifier)
        return AX.windows(appElement).compactMap { window in
            guard let button = GPWindowParser.dismissButton(in: window, using: .live) else { return nil }
            return PopupWindow(
                title: GPWindowParser.title(in: window, using: .live),
                bodyText: GPWindowParser.bodyText(in: window, using: .live),
                pressPrimary: { AX.press(button) }
            )
        }
    }
}
