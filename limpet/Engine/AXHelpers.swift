// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import ApplicationServices
import Foundation

enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type = T.self) -> T? {
        var raw: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard err == .success else { return nil }
        return raw as? T
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name, as: String.self) ?? (attribute(element, name, as: NSString.self) as String?)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String, as: [AXUIElement].self) ?? []
    }

    static func windows(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXWindowsAttribute as String, as: [AXUIElement].self) ?? []
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    static func title(_ element: AXUIElement) -> String? {
        string(element, kAXTitleAttribute as String)
    }

    static func value(_ element: AXUIElement) -> String? {
        string(element, kAXValueAttribute as String)
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func setValue(_ element: AXUIElement, _ string: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, string as CFString) == .success
    }

    /// Walks a subtree depth-first, returning the first descendant for which
    /// `match` returns `true`. Iterative to avoid stack overflow on deep AX trees.
    static func find(_ root: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        findNode(root, children: { children($0) }, where: match)
    }

    /// Generic iterative DFS used by `find`. Extracted so it can be tested
    /// without needing real `AXUIElement` instances.
    static func findNode<Node>(_ root: Node, children childrenOf: (Node) -> [Node], where match: (Node) -> Bool) -> Node? {
        var stack = [root]
        while !stack.isEmpty {
            let node = stack.removeLast()
            if match(node) { return node }
            stack.append(contentsOf: childrenOf(node).reversed())
        }
        return nil
    }

    static func isProcessTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts: [CFString: Bool] = [key: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}

import AppKit

/// Opens System Settings directly to Privacy & Security → Accessibility.
@MainActor
public func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}

/// Opens System Settings → General → Login Items & Extensions.
@MainActor
public func openLoginItemsSettings() {
    // The dedicated Login Items pane URL on macOS 13+.
    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

/// Watches `AXIsProcessTrusted` on a 1-second tick and publishes changes.
/// macOS doesn't notify when permission flips, so we poll.
@MainActor
@Observable
public final class AccessibilityTrustWatcher {
    public var isTrusted: Bool = AX.isProcessTrusted(prompt: false)

    public init() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = AX.isProcessTrusted(prompt: false)
                if now != self.isTrusted { self.isTrusted = now }
            }
        }
    }
}
