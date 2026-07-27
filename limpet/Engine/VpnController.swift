// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

@preconcurrency import ApplicationServices
import AppKit
import Foundation
import OSLog

public enum VpnControlError: Error, CustomStringConvertible {
    case globalProtectNotRunning
    case accessibilityNotTrusted
    case statusItemNotFound
    case popoverDidNotOpen
    case buttonNotFound(String)
    case signatureVerificationFailed
    case timedOut

    public var description: String {
        switch self {
        case .globalProtectNotRunning: "GlobalProtect is not running"
        case .accessibilityNotTrusted: "limpet does not have Accessibility permission"
        case .statusItemNotFound: "GlobalProtect menu-bar status item not found"
        case .popoverDidNotOpen: "GlobalProtect popover did not open after click"
        case .buttonNotFound(let name): "Could not find '\(name)' in GlobalProtect UI"
        case .signatureVerificationFailed: "GlobalProtect process failed code-signature verification"
        case .timedOut: "GlobalProtect stopped responding to Accessibility requests"
        }
    }
}

/// Drives the GlobalProtect menu-bar UI via Accessibility to issue Connect /
/// Disconnect actions.
///
/// An `actor`, deliberately **not** `@MainActor`. Every method here is a long
/// chain of synchronous AX messages, and a slow GlobalProtect makes each one
/// take up to `AX.messagingTimeout`. Running that on the main actor froze
/// limpet's UI outright ("not responding") while GP was pegged at 100% CPU.
/// AX is safe off-main; only `NSWorkspace` focus handling needs the main actor,
/// and that is hopped explicitly.
///
/// Actor isolation also serialises the two callers — the watchdog and the user's
/// menu-bar toggle — so they can never drive GP's UI at the same time.
public actor AccessibilityVpnController: VpnControlling {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "controller")
    private static let bundleID = GlobalProtectInstallation.bundleID

    private let disconnectComment: String
    /// Returns the portal address to pre-fill before connecting, or empty to skip.
    private let portalAddress: @Sendable @MainActor () -> String
    private let operationTimeout: Duration
    private let verifier = GPCodeSignatureVerifier()

    public init(
        disconnectComment: String = "limpet user toggle",
        operationTimeout: Duration = .seconds(20),
        portalAddress: @escaping @Sendable @MainActor () -> String = { "" }
    ) {
        self.disconnectComment = disconnectComment
        self.operationTimeout = operationTimeout
        self.portalAddress = portalAddress
    }

    public func connect() async throws {
        Self.log.info("connect: requested")
        let deadline = AX.Deadline(after: operationTimeout)
        let previousPID = await Self.frontmostPID()
        defer { Self.restoreFocus(to: previousPID) }

        let appElement = try await openPopoverIfNeeded(deadline: deadline)
        if try await fillPortalIfNeeded(in: appElement, deadline: deadline) {
            // GP may briefly dismiss and recreate the panel after a programmatic
            // value change. Re-poll for the panel the same way we do after opening.
            var settled = false
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if !panelWindows(appElement, deadline: deadline).isEmpty { settled = true; break }
            }
            if !settled {
                Self.log.error("panel disappeared after portal fill")
                throw VpnControlError.popoverDidNotOpen
            }
        }
        try deadline.check()
        // When GP is stuck in Connecting... there is no Connect button — fall back
        // to the hamburger menu's "Refresh Connection" item instead.
        do {
            try pressButton(matching: ["Connect", "Enable", "Reconnect"], in: appElement, deadline: deadline)
            Self.log.info("connect: button pressed")
        } catch {
            try deadline.check()
            Self.log.info("connect: no Connect button, trying Refresh Connection via options menu")
            try await pressOptionsMenuItem("Refresh Connection", in: appElement, deadline: deadline)
            Self.log.info("connect: Refresh Connection pressed")
        }
    }

    public func disconnect() async throws {
        Self.log.info("disconnect: requested")
        let deadline = AX.Deadline(after: operationTimeout)
        let previousPID = await Self.frontmostPID()
        defer { Self.restoreFocus(to: previousPID) }

        let appElement = try await openPopoverIfNeeded(deadline: deadline)
        try pressButton(matching: ["Disconnect", "Disable"], in: appElement, deadline: deadline)
        Self.log.info("disconnect: button pressed")
        try? await Task.sleep(for: .milliseconds(700))
        fillDisconnectCommentAndConfirm(in: appElement, deadline: deadline)
    }

    // MARK: - Focus

    /// Read and restore via pid rather than holding `NSRunningApplication`, which
    /// is not `Sendable` and so cannot cross back out of the main actor.
    private static func frontmostPID() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    private static func restoreFocus(to pid: pid_t?) {
        guard let pid else { return }
        Task { @MainActor in
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    // MARK: - Private

    private func verifiedGPPid() throws -> pid_t {
        guard AX.isProcessTrusted(prompt: false) else {
            Self.log.error("Accessibility is not trusted")
            throw VpnControlError.accessibilityNotTrusted
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            Self.log.error("GlobalProtect is not running")
            throw VpnControlError.globalProtectNotRunning
        }
        guard verifier.verify(app: app) else {
            Self.log.error("GlobalProtect pid=\(app.processIdentifier) failed code-signature check")
            throw VpnControlError.signatureVerificationFailed
        }
        return app.processIdentifier
    }

    /// Resolves and verifies GP once, then opens the popover if needed.
    /// Returns the AXUIElement for the GP app, ready for all subsequent AX calls.
    private func openPopoverIfNeeded(deadline: AX.Deadline) async throws -> AXUIElement {
        let pid = try verifiedGPPid()
        let appElement = AX.appElement(pid)
        // Only non-dialog windows indicate the status-item popover is open.
        // After sleep/wake GP often shows a disconnection alert (AXDialog subrole)
        // before the popover has been opened; treating that alert as "popover open"
        // causes pressButton to search the alert and fail to find Connect.
        if !panelWindows(appElement, deadline: deadline).isEmpty {
            Self.log.info("popover already open")
            return appElement
        }
        try deadline.check()
        Self.log.info("popover closed; opening via status item")
        try clickStatusItem(appElement: appElement)
        for attempt in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            try deadline.check()
            let windows = panelWindows(appElement, deadline: deadline)
            Self.log.debug("popoverIsOpen: \(windows.count) GP panel windows")
            if !windows.isEmpty {
                Self.log.info("popover opened after \(attempt + 1) polls")
                return appElement
            }
        }
        Self.log.error("popover did not open within 2s")
        throw VpnControlError.popoverDidNotOpen
    }

    /// Returns the GP status-item panel window(s).
    /// Excludes AXDialog alert popups (disconnection alerts, session-timeout alerts)
    /// which appear before the panel is open and must not be treated as the panel.
    /// AXSystemDialog is kept because the GP panel itself uses that subrole.
    private func panelWindows(_ appElement: AXUIElement, deadline: AX.Deadline) -> [AXUIElement] {
        guard !deadline.isExpired else { return [] }
        return AX.windows(appElement).filter {
            (AX.subrole($0) ?? "") != (kAXDialogSubrole as String)
        }
    }

    // GP's menu extra is only reachable via kAXExtrasMenuBarAttribute on the GP
    // process itself — confirmed by live AX probe on Tahoe. It is not present in
    // the Control Center subtree or via system-wide search.
    private func clickStatusItem(appElement: AXUIElement) throws {
        guard let menubar = AX.attribute(appElement, kAXExtrasMenuBarAttribute as String, as: AXUIElement.self) else {
            Self.log.error("kAXExtrasMenuBarAttribute not available")
            throw VpnControlError.statusItemNotFound
        }
        guard let item = AX.children(menubar).first else {
            Self.log.error("extras menubar is empty")
            throw VpnControlError.statusItemNotFound
        }
        guard AX.press(item) else {
            Self.log.error("status item press failed")
            throw VpnControlError.statusItemNotFound
        }
    }

    private func pressButton(matching titles: [String], in appElement: AXUIElement, deadline: AX.Deadline) throws {
        let windows = AX.windows(appElement)
        Self.log.info("pressButton: \(windows.count) windows to search")
        for (wi, window) in windows.enumerated() {
            try deadline.check()
            var allLabels: [String] = []
            var matchedButton: AXUIElement?
            _ = AX.find(window, deadline: deadline, where: { element in
                guard AX.role(element) == kAXButtonRole as String else { return false }
                let label = AX.buttonLabel(element) ?? "<nil>"
                allLabels.append(label)
                if matchedButton == nil && titles.contains(where: { label.localizedCaseInsensitiveContains($0) }) {
                    matchedButton = element
                }
                return false
            })
            Self.log.info("pressButton: window[\(wi)] buttons=\(allLabels)")
            if let button = matchedButton {
                if AX.press(button) { return }
                Self.log.error("button press returned false for titles=\(titles)")
            }
        }
        Self.log.error("no button matching \(titles) in any GP window")
        throw VpnControlError.buttonNotFound(titles.joined(separator: " / "))
    }

    @discardableResult
    private func pressOptionsMenuItem(_ item: String, in appElement: AXUIElement, deadline: AX.Deadline) async throws {
        for window in panelWindows(appElement, deadline: deadline) {
            try deadline.check()
            guard let menu = AX.find(window, deadline: deadline, where: { AX.role($0) == kAXPopUpButtonRole as String }) else { continue }
            guard AX.press(menu) else { continue }
            try? await Task.sleep(for: .milliseconds(200))
            if let menuItem = AX.findNode(menu, children: AX.children, shouldStop: { deadline.isExpired }, where: {
                AX.role($0) == kAXMenuItemRole as String &&
                (AX.title($0) ?? "").localizedCaseInsensitiveContains(item)
            }) {
                if AX.press(menuItem) {
                    Self.log.info("pressed menu item '\(item)'")
                    return
                }
            }
        }
        throw VpnControlError.buttonNotFound(item)
    }

    /// Writes the configured portal address, but **only if it differs** from
    /// what's already in the field.
    ///
    /// Returns `true` only when a write actually happened, because a write makes
    /// GP tear down and recreate its panel — visible to the user as the window
    /// flickering — and costs the caller a settle wait. Re-writing an identical
    /// value on every attempt bought that flicker for nothing.
    private func fillPortalIfNeeded(in appElement: AXUIElement, deadline: AX.Deadline) async throws -> Bool {
        let addr = await MainActor.run { self.portalAddress() }
        guard !addr.isEmpty else { return false }
        for window in panelWindows(appElement, deadline: deadline) {
            try deadline.check()
            if let field = AX.find(window, deadline: deadline, where: { element in
                AX.role(element) == kAXTextFieldRole as String
            }) {
                if AX.value(field) == addr {
                    Self.log.info("portal address already set; leaving panel alone")
                    return false
                }
                _ = AX.setValue(field, addr)
                Self.log.info("filled portal address")
                return true
            }
        }
        return false
    }

    private func fillDisconnectCommentAndConfirm(in appElement: AXUIElement, deadline: AX.Deadline) {
        for window in AX.windows(appElement) {
            if deadline.isExpired { return }
            if let textArea = AX.find(window, deadline: deadline, where: { element in
                let role = AX.role(element)
                return role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
            }) {
                _ = AX.setValue(textArea, disconnectComment)
                Self.log.info("filled disconnect comment")
            }
            if let okButton = AX.find(window, deadline: deadline, where: { element in
                guard AX.role(element) == kAXButtonRole as String else { return false }
                guard let label = AX.buttonLabel(element) else { return false }
                return ["OK", "Continue", "Disconnect"].contains(label)
            }) {
                _ = AX.press(okButton)
                Self.log.info("pressed OK on disconnect sheet")
                return
            }
        }
    }
}

extension AX.Deadline {
    /// Throws once the budget is spent, so a caller mid-sequence stops issuing
    /// further AX messages to an app that isn't answering.
    func check() throws {
        if isExpired { throw VpnControlError.timedOut }
    }
}
