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

    public var description: String {
        switch self {
        case .globalProtectNotRunning: "GlobalProtect is not running"
        case .accessibilityNotTrusted: "limpet does not have Accessibility permission"
        case .statusItemNotFound: "GlobalProtect menu-bar status item not found"
        case .popoverDidNotOpen: "GlobalProtect popover did not open after click"
        case .buttonNotFound(let name): "Could not find '\(name)' in GlobalProtect UI"
        }
    }
}

/// Drives the GlobalProtect menu-bar UI via Accessibility to issue Connect /
/// Disconnect actions.
@MainActor
public final class AccessibilityVpnController: VpnControlling {
    private static let log = Logger(subsystem: "com.grahamgilbert.limpet", category: "controller")
    private static let bundleID = "com.paloaltonetworks.GlobalProtect.client"

    private let disconnectComment: String

    public init(disconnectComment: String = "limpet user toggle") {
        self.disconnectComment = disconnectComment
    }

    public func connect() async throws {
        Self.log.info("connect: requested")
        try await openPopoverIfNeeded()
        try pressButton(matching: ["Connect", "Enable", "Reconnect"])
        Self.log.info("connect: button pressed")
    }

    public func disconnect() async throws {
        Self.log.info("disconnect: requested")
        try await openPopoverIfNeeded()
        try pressButton(matching: ["Disconnect", "Disable"])
        Self.log.info("disconnect: button pressed")
        try? await Task.sleep(for: .milliseconds(700))
        fillDisconnectCommentAndConfirm()
    }

    // MARK: - Private

    private func gpAppElement() throws -> AXUIElement {
        guard AX.isProcessTrusted(prompt: false) else {
            Self.log.error("Accessibility is not trusted")
            throw VpnControlError.accessibilityNotTrusted
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            Self.log.error("GlobalProtect is not running")
            throw VpnControlError.globalProtectNotRunning
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func popoverIsOpen() -> Bool {
        guard let app = try? gpAppElement() else { return false }
        let windows = AX.windows(app)
        Self.log.debug("popoverIsOpen: \(windows.count) GP windows")
        return !windows.isEmpty
    }

    private func openPopoverIfNeeded() async throws {
        if popoverIsOpen() {
            Self.log.info("popover already open")
            return
        }
        Self.log.info("popover closed; opening via status item")
        try clickStatusItem()
        for attempt in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if popoverIsOpen() {
                Self.log.info("popover opened after \(attempt + 1) polls")
                return
            }
        }
        Self.log.error("popover did not open within 2s")
        throw VpnControlError.popoverDidNotOpen
    }

    /// Try to press GP's status item. First attempt: walk the GP app's
    /// own menu-bar extras. Fallback: scan the system-wide AX for any
    /// menu-bar item whose title or description references GlobalProtect.
    private func clickStatusItem() throws {
        if let item = findGPStatusItemInOwnMenuBar() {
            Self.log.info("status item found via GP's own menubar")
            if AX.press(item) { return }
            Self.log.error("status item press failed (own menubar)")
        }
        if let item = findGPStatusItemSystemWide() {
            Self.log.info("status item found via system-wide AX")
            if AX.press(item) { return }
            Self.log.error("status item press failed (system-wide)")
        }
        throw VpnControlError.statusItemNotFound
    }

    private func findGPStatusItemInOwnMenuBar() -> AXUIElement? {
        guard let app = try? gpAppElement() else { return nil }
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            app, kAXExtrasMenuBarAttribute as CFString, &ref
        )
        guard result == .success, let value = ref,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Self.log.debug("kAXExtrasMenuBarAttribute err=\(result.rawValue)")
            return nil
        }
        // swiftlint:disable:next force_cast
        let menubar = value as! AXUIElement
        let kids = AX.children(menubar)
        Self.log.debug("extras menubar children=\(kids.count)")
        return kids.first
    }

    private func findGPStatusItemSystemWide() -> AXUIElement? {
        // System-wide AX root, walk its menubars looking for an item whose
        // attributes mention GlobalProtect. On Tahoe the menubar extras live
        // under the Control Center process; system-wide search reaches them.
        let systemWide = AXUIElementCreateSystemWide()
        return AX.find(systemWide) { element in
            let role = AX.role(element) ?? ""
            guard role == "AXMenuExtra" || role == kAXMenuBarItemRole as String else {
                return false
            }
            let title = AX.title(element) ?? ""
            let desc = AX.string(element, kAXDescriptionAttribute as String) ?? ""
            let match = title.localizedCaseInsensitiveContains("globalprotect")
                || desc.localizedCaseInsensitiveContains("globalprotect")
            return match
        }
    }

    private func pressButton(matching titles: [String]) throws {
        let app = try gpAppElement()
        for window in AX.windows(app) {
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

    private func fillDisconnectCommentAndConfirm() {
        guard let app = try? gpAppElement() else { return }
        for window in AX.windows(app) {
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
