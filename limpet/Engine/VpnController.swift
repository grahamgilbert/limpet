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

    public var description: String {
        switch self {
        case .globalProtectNotRunning: "GlobalProtect is not running"
        case .accessibilityNotTrusted: "limpet does not have Accessibility permission"
        case .statusItemNotFound: "GlobalProtect menu-bar status item not found"
        case .popoverDidNotOpen: "GlobalProtect popover did not open after click"
        case .buttonNotFound(let name): "Could not find '\(name)' in GlobalProtect UI"
        case .signatureVerificationFailed: "GlobalProtect process failed code-signature verification"
        }
    }
}

/// Drives the GlobalProtect menu-bar UI via Accessibility to issue Connect /
/// Disconnect actions.
@MainActor
public final class AccessibilityVpnController: VpnControlling {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "controller")
    private static let bundleID = GlobalProtectInstallation.bundleID

    private let disconnectComment: String
    private let verifier = GPCodeSignatureVerifier()

    public init(disconnectComment: String = "limpet user toggle") {
        self.disconnectComment = disconnectComment
    }

    public func connect() async throws {
        Self.log.info("connect: requested")
        let appElement = try await openPopoverIfNeeded()
        try pressButton(matching: ["Connect", "Enable", "Reconnect"], in: appElement)
        Self.log.info("connect: button pressed")
    }

    public func disconnect() async throws {
        Self.log.info("disconnect: requested")
        let appElement = try await openPopoverIfNeeded()
        try pressButton(matching: ["Disconnect", "Disable"], in: appElement)
        Self.log.info("disconnect: button pressed")
        try? await Task.sleep(for: .milliseconds(700))
        fillDisconnectCommentAndConfirm(in: appElement)
    }

    // MARK: - Private

    private func verifiedGPApp() throws -> NSRunningApplication {
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
        return app
    }

    /// Resolves and verifies GP once, then opens the popover if needed.
    /// Returns the AXUIElement for the GP app, ready for all subsequent AX calls.
    private func openPopoverIfNeeded() async throws -> AXUIElement {
        let app = try verifiedGPApp()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if !AX.windows(appElement).isEmpty {
            Self.log.info("popover already open")
            return appElement
        }
        Self.log.info("popover closed; opening via status item")
        try clickStatusItem(appElement: appElement, verifiedApp: app)
        for attempt in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let windows = AX.windows(appElement)
            Self.log.debug("popoverIsOpen: \(windows.count) GP windows")
            if !windows.isEmpty {
                Self.log.info("popover opened after \(attempt + 1) polls")
                return appElement
            }
        }
        Self.log.error("popover did not open within 2s")
        throw VpnControlError.popoverDidNotOpen
    }

    // GP's menu extra is only reachable via kAXExtrasMenuBarAttribute on the GP
    // process itself — confirmed by live AX probe on Tahoe. It is not present in
    // the Control Center subtree or via system-wide search.
    private func clickStatusItem(appElement: AXUIElement, verifiedApp _: NSRunningApplication) throws {
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

    private func pressButton(matching titles: [String], in appElement: AXUIElement) throws {
        for window in AX.windows(appElement) {
            if let button = AX.find(window, where: { element in
                guard AX.role(element) == kAXButtonRole as String else { return false }
                guard let title = AX.title(element) else { return false }
                return titles.contains { title.localizedCaseInsensitiveContains($0) }
            }) {
                if AX.press(button) { return }
                Self.log.error("button press returned false for titles=\(titles)")
            }
        }
        Self.log.error("no button matching \(titles) in any GP window")
        throw VpnControlError.buttonNotFound(titles.joined(separator: " / "))
    }

    private func fillDisconnectCommentAndConfirm(in appElement: AXUIElement) {
        for window in AX.windows(appElement) {
            if let textArea = AX.find(window, where: { element in
                let role = AX.role(element)
                return role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
            }) {
                _ = AX.setValue(textArea, disconnectComment)
                Self.log.info("filled disconnect comment")
            }
            if let okButton = AX.find(window, where: { element in
                guard AX.role(element) == kAXButtonRole as String else { return false }
                guard let title = AX.title(element) else { return false }
                return ["OK", "Continue", "Disconnect"].contains(title)
            }) {
                _ = AX.press(okButton)
                Self.log.info("pressed OK on disconnect sheet")
                return
            }
        }
    }
}
