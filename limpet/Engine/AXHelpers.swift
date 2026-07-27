// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import ApplicationServices
import Foundation

enum AX {
    // ponytail: fixed 2s; expose as a pref if some install proves consistently slower.
    /// Upper bound, in seconds, on any single Accessibility call. Without this,
    /// AX messaging to a hung GlobalProtect blocks the caller indefinitely — and
    /// since the controller runs its AX calls on the main thread, that freezes
    /// limpet's UI ("not responding"). 2s is generous for GP's normally-instant
    /// AX replies while still bounding a hang.
    static let messagingTimeout: Float = 2

    /// Wall-clock budget for a whole multi-call AX operation.
    ///
    /// `messagingTimeout` bounds one message. A tree walk makes hundreds, so
    /// against a slow GlobalProtect the bound compounds: a single `connect()`
    /// was observed occupying a thread for 45 minutes of CPU while GP sat at
    /// 100%. Callers thread a deadline through so the *operation* is bounded
    /// too, and — unlike racing a timer task — this actually stops the work
    /// instead of abandoning a thread that is still blocked in `mach_msg`.
    struct Deadline: Sendable {
        private let expiry: ContinuousClock.Instant

        init(after duration: Duration) {
            expiry = ContinuousClock.now.advanced(by: duration)
        }

        var isExpired: Bool { ContinuousClock.now >= expiry }
    }

    /// Backstop budget for a single tree walk by a caller that didn't pass its
    /// own. Deliberately *not* optional: an opt-in bound only protects whoever
    /// remembered it, and the walk that most needed one — the popup dismisser's,
    /// via `GlobalProtectWindowProvider` — was the one without it. Sibling of
    /// `setGlobalMessagingTimeout()`, which bounds a single message process-wide.
    static let walkBudget: Duration = .seconds(10)

    /// Fresh stop-condition for one walk. A default argument, so each call gets
    /// its own budget rather than sharing a deadline fixed at startup.
    static func walkBudgetStop(_ duration: Duration = walkBudget) -> () -> Bool {
        let deadline = Deadline(after: duration)
        return { deadline.isExpired }
    }

    /// Creates the AX element for a process and pins its messaging timeout.
    /// Child elements copied from this app element inherit the timeout.
    static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Sets the process-wide default AX messaging timeout. Call once at launch so
    /// any element that isn't derived from `appElement(_:)` is also bounded.
    static func setGlobalMessagingTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

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

    static func subrole(_ element: AXUIElement) -> String? {
        string(element, kAXSubroleAttribute as String)
    }

    static func title(_ element: AXUIElement) -> String? {
        string(element, kAXTitleAttribute as String)
    }

    /// Title with value fallback — some GP buttons (e.g. in the Connection Failed
    /// web-rendered screen) expose their label in kAXValueAttribute rather than
    /// kAXTitleAttribute.
    static func buttonLabel(_ element: AXUIElement) -> String? {
        title(element) ?? value(element)
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
    ///
    /// Pass a `deadline` whenever the target app might be unresponsive: each
    /// step here is a live AX message, so an unbounded walk over a wedged app is
    /// what pins a thread for minutes.
    static func find(
        _ root: AXUIElement,
        deadline: Deadline? = nil,
        where match: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        // An explicit operation-level deadline wins; otherwise fall back to the
        // per-walk backstop so no walk is ever unbounded.
        let shouldStop: () -> Bool = deadline.map { budget in { budget.isExpired } } ?? walkBudgetStop()
        return findNode(
            root,
            children: { children($0) },
            shouldStop: shouldStop,
            where: match
        )
    }

    /// Generic iterative DFS used by `find`. Extracted so it can be tested
    /// without needing real `AXUIElement` instances.
    ///
    /// Returns `nil` if `shouldStop` trips before a match — indistinguishable
    /// from "not found", which is the right behaviour for every caller here:
    /// they all treat a miss as "can't do it right now" and retry later.
    static func findNode<Node>(
        _ root: Node,
        children childrenOf: (Node) -> [Node],
        shouldStop: () -> Bool = walkBudgetStop(),
        where match: (Node) -> Bool
    ) -> Node? {
        var stack = [root]
        while !stack.isEmpty {
            if shouldStop() { return nil }
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

/// Watches `AXIsProcessTrusted` and publishes changes.
///
/// macOS has no notification for TCC changes, so we poll. 5 seconds is
/// imperceptible to the user — the permission window's `.onChange` already
/// handles the fast path when it's open.
///
/// The poll runs **off** the main thread. `AXIsProcessTrustedWithOptions` is a
/// synchronous XPC call into `tccd`, and unlike element messaging it is *not*
/// bounded by `AXUIElementSetMessagingTimeout` — so if TCC or the accessibility
/// subsystem stalls, polling it on the main actor parks the runloop and limpet
/// goes "not responding" while its background work carries on as normal.
@MainActor
@Observable
public final class AccessibilityTrustWatcher {
    public var isTrusted: Bool = AX.isProcessTrusted(prompt: false)

    public init() {
        // Detached, so the blocking call lands on a background thread. The last
        // value is tracked in the loop's own scope so a steady state — which is
        // essentially always, TCC changes at most once in a session — costs no
        // main-actor traffic at all.
        let initial = isTrusted
        Task.detached(priority: .utility) { [weak self] in
            // Declared inside the task so it is plainly task-local state, not a
            // mutable capture whose safety depends on region isolation.
            var last = initial
            while true {
                try? await Task.sleep(for: .seconds(5))
                let now = AX.isProcessTrusted(prompt: false)
                // Liveness check first: an unchanged value used to `continue`
                // before this, so a released watcher left the task polling TCC
                // every 5s for the life of the process.
                guard let self else { return }
                guard now != last else { continue }
                last = now
                await MainActor.run { self.isTrusted = now }
            }
        }
    }
}
