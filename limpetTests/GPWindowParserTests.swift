// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Testing
@testable import limpet

// MARK: - Test stub

/// Minimal AX tree node for testing GPWindowParser without real AXUIElements.
struct GPFakeNode {
    var role: String?
    var subrole: String?
    var value: String?
    var title: String?
    var children: [GPFakeNode]
    var isMinimizable: Bool

    init(role: String? = nil, subrole: String? = nil, value: String? = nil, title: String? = nil, children: [GPFakeNode] = [], isMinimizable: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.value = value
        self.title = title
        self.children = children
        self.isMinimizable = isMinimizable
    }

    /// Stands in for the live `kAXCloseButtonAttribute`: a direct child with the
    /// close-button subrole, which is where AX exposes the real traffic light.
    var closeButton: GPFakeNode? {
        children.first { $0.subrole == "AXCloseButton" }
    }
}

extension GPWindowAccessors where Node == GPFakeNode {
    static let fake = GPWindowAccessors(
        role: { $0.role },
        subrole: { $0.subrole },
        value: { $0.value },
        title: { $0.title },
        children: { $0.children },
        isMinimizable: { $0.isMinimizable },
        closeButton: { $0.closeButton }
    )
}

/// The session-timeout alert as GP 6.x actually renders it: a minimizable
/// AXStandardWindow whose only buttons are the traffic lights.
let sessionTimeoutWindow = GPFakeNode(subrole: "AXStandardWindow", title: "GlobalProtect", children: [
    GPFakeNode(role: "AXScrollArea", children: [
        GPFakeNode(role: "AXWebArea", children: [
            GPFakeNode(role: "AXStaticText",
                       value: "Your GlobalProtect session has been disconnected due to network connectivity issues or session timeouts."),
        ]),
    ]),
    GPFakeNode(role: "AXButton", subrole: "AXCloseButton"),
    GPFakeNode(role: "AXButton", subrole: "AXZoomButton"),
    GPFakeNode(role: "AXButton", subrole: "AXMinimizeButton"),
    GPFakeNode(role: "AXStaticText", value: "GlobalProtect"),
], isMinimizable: true)

// MARK: - Title extraction

@Suite("GPWindowParser — title extraction")
struct GPWindowParserTitleTests {

    @Test("uses kAXTitleAttribute when non-empty")
    func usesWindowTitle() {
        let window = GPFakeNode(title: "GlobalProtect")
        #expect(GPWindowParser.title(in: window, using: .fake) == "GlobalProtect")
    }

    @Test("falls back to first static text when title is empty string")
    func fallsBackWhenTitleEmpty() {
        let window = GPFakeNode(title: "", children: [
            GPFakeNode(role: "AXStaticText", value: "GlobalProtect"),
            GPFakeNode(role: "AXStaticText", value: "Gateway US West"),
        ])
        #expect(GPWindowParser.title(in: window, using: .fake) == "GlobalProtect")
    }

    @Test("falls back to first static text when title is nil")
    func fallsBackWhenTitleNil() {
        let window = GPFakeNode(title: nil, children: [
            GPFakeNode(role: "AXStaticText", value: "GlobalProtect"),
        ])
        #expect(GPWindowParser.title(in: window, using: .fake) == "GlobalProtect")
    }

    @Test("returns nil when title absent and no static text children")
    func nilWhenNoTitle() {
        let window = GPFakeNode(title: nil, children: [
            GPFakeNode(role: "AXButton"),
        ])
        #expect(GPWindowParser.title(in: window, using: .fake) == nil)
    }
}

// MARK: - Body text extraction

@Suite("GPWindowParser — body text extraction")
struct GPWindowParserBodyTests {

    @Test("classic layout: scroll area → container → static text")
    func classicLayout() {
        let body = GPFakeNode(role: "AXStaticText", value: "You have been disconnected.")
        let container = GPFakeNode(role: "AXGroup", children: [body])
        let scrollArea = GPFakeNode(role: "AXScrollArea", children: [container])
        let window = GPFakeNode(children: [scrollArea])
        #expect(GPWindowParser.bodyText(in: window, using: .fake) == "You have been disconnected.")
    }

    @Test("classic layout: scroll area → static text (no container)")
    func classicNoContainer() {
        let body = GPFakeNode(role: "AXStaticText", value: "Connectivity issues detected.")
        let scrollArea = GPFakeNode(role: "AXScrollArea", children: [body])
        let window = GPFakeNode(children: [scrollArea])
        #expect(GPWindowParser.bodyText(in: window, using: .fake) == "Connectivity issues detected.")
    }

    // Idle-timeout popup layout observed on macOS 15 + GP 6.x:
    // AXWindow → [AXStaticText "GlobalProtect", AXButton, AXStaticText "Gateway US West",
    //             AXScrollArea → AXWebArea → AXStaticText "<body>", AXButton "More Notifications"]
    @Test("web-rendered layout: scroll area → web area → static text")
    func webRenderedLayout() {
        let bodyText = "Your endpoint has reached the specified time to remain idle. You will be logged out of GlobalProtect."
        let body = GPFakeNode(role: "AXStaticText", value: bodyText)
        let webArea = GPFakeNode(role: "AXWebArea", children: [body])
        let scrollArea = GPFakeNode(role: "AXScrollArea", children: [webArea])
        let window = GPFakeNode(children: [
            GPFakeNode(role: "AXStaticText", value: "GlobalProtect"),
            GPFakeNode(role: "AXButton"),
            GPFakeNode(role: "AXStaticText", value: "Gateway US West"),
            scrollArea,
        ])
        #expect(GPWindowParser.bodyText(in: window, using: .fake) == bodyText)
    }

    @Test("returns nil when no scroll area and no nested static text")
    func nilWhenNoBody() {
        let window = GPFakeNode(children: [
            GPFakeNode(role: "AXStaticText", value: "GlobalProtect"),
            GPFakeNode(role: "AXButton"),
        ])
        #expect(GPWindowParser.bodyText(in: window, using: .fake) == nil)
    }

    @Test("deep fallback skips direct window static text children")
    func directStaticTextChildrenSkipped() {
        let body = GPFakeNode(role: "AXStaticText", value: "Session timeout.")
        let group = GPFakeNode(role: "AXGroup", children: [body])
        let window = GPFakeNode(children: [
            GPFakeNode(role: "AXStaticText", value: "GlobalProtect"),
            group,
        ])
        #expect(GPWindowParser.bodyText(in: window, using: .fake) == "Session timeout.")
    }
}

// MARK: - Window eligibility + dismiss button selection

@Suite("GPWindowParser — dismissButton")
struct GPWindowParserDismissButtonTests {

    /// Alert shape: an OK button plus traffic lights, not minimizable.
    private func alert(subrole: String?, isMinimizable: Bool = false) -> GPFakeNode {
        GPFakeNode(subrole: subrole, children: [
            GPFakeNode(role: "AXButton", subrole: "AXCloseButton"),
            GPFakeNode(role: "AXButton", title: "OK"),
        ], isMinimizable: isMinimizable)
    }

    @Test("AXSystemDialog is rejected — this is the GP status-item panel, not a popup")
    func axSystemDialogRejected() {
        #expect(GPWindowParser.dismissButton(in: alert(subrole: "AXSystemDialog"), using: .fake) == nil)
    }

    @Test("AXDialog alert presses its action button")
    func axDialogAccepted() {
        #expect(GPWindowParser.dismissButton(in: alert(subrole: "AXDialog"), using: .fake)?.title == "OK")
    }

    @Test("AXStandardWindow non-minimizable is accepted — disconnection alerts use this subrole")
    func standardWindowAlertAccepted() {
        #expect(GPWindowParser.dismissButton(in: alert(subrole: "AXStandardWindow"), using: .fake)?.title == "OK")
    }

    @Test("nil subrole is accepted")
    func nilSubroleAccepted() {
        #expect(GPWindowParser.dismissButton(in: alert(subrole: nil), using: .fake)?.title == "OK")
    }

    @Test("unknown subrole is accepted")
    func unknownSubroleAccepted() {
        #expect(GPWindowParser.dismissButton(in: alert(subrole: "AXFloatingWindow"), using: .fake)?.title == "OK")
    }

    @Test("minimizable window with an action button is rejected — this is the main GP app window")
    func standardWindowMainAppRejected() {
        let mainWindow = GPFakeNode(subrole: "AXStandardWindow", children: [
            GPFakeNode(role: "AXButton", subrole: "AXCloseButton"),
            GPFakeNode(role: "AXButton", title: "Disconnect"),
        ], isMinimizable: true)
        #expect(GPWindowParser.dismissButton(in: mainWindow, using: .fake) == nil)
    }

    @Test("minimizable window with only traffic lights is closed — the session-timeout alert")
    func sessionTimeoutClosed() {
        #expect(GPWindowParser.dismissButton(in: sessionTimeoutWindow, using: .fake)?.subrole == "AXCloseButton")
    }

    @Test("prefers an action button over the close button")
    func prefersActionButton() {
        #expect(GPWindowParser.dismissButton(in: alert(subrole: nil), using: .fake)?.title == "OK")
    }

    @Test("returns nil when the window has no buttons at all")
    func nilWhenNoButtons() {
        let window = GPFakeNode(children: [GPFakeNode(role: "AXStaticText", value: "hi")])
        #expect(GPWindowParser.dismissButton(in: window, using: .fake) == nil)
    }
}

// MARK: - Integration: parser feeds shouldDismissPopup correctly

@Suite("GPWindowParser + shouldDismissPopup integration")
struct GPWindowParserIntegrationTests {

    @Test("idle-timeout popup layout is dismissed")
    func idleTimeoutDismissed() {
        let window = GPFakeNode(title: "", children: [
            GPFakeNode(role: "AXStaticText", value: "GlobalProtect"),
            GPFakeNode(role: "AXButton"),
            GPFakeNode(role: "AXStaticText", value: "Gateway US West"),
            GPFakeNode(role: "AXScrollArea", children: [
                GPFakeNode(role: "AXWebArea", children: [
                    GPFakeNode(role: "AXStaticText",
                               value: "Your endpoint has reached the specified time to remain idle. You will be logged out of GlobalProtect."),
                ]),
            ]),
        ])
        let title = GPWindowParser.title(in: window, using: .fake)
        let body = GPWindowParser.bodyText(in: window, using: .fake)
        #expect(shouldDismissPopup(title: title, body: body) == true)
    }

    @Test("classic disconnect popup layout is dismissed")
    func classicDisconnectDismissed() {
        let window = GPFakeNode(title: "GlobalProtect", children: [
            GPFakeNode(role: "AXScrollArea", children: [
                GPFakeNode(role: "AXGroup", children: [
                    GPFakeNode(role: "AXStaticText", value: "You have been disconnected from the network."),
                ]),
            ]),
        ])
        let title = GPWindowParser.title(in: window, using: .fake)
        let body = GPWindowParser.bodyText(in: window, using: .fake)
        #expect(shouldDismissPopup(title: title, body: body) == true)
    }

    @Test("session-timeout standard window is eligible and dismissed")
    func sessionTimeoutDismissed() {
        let title = GPWindowParser.title(in: sessionTimeoutWindow, using: .fake)
        let body = GPWindowParser.bodyText(in: sessionTimeoutWindow, using: .fake)
        #expect(GPWindowParser.dismissButton(in: sessionTimeoutWindow, using: .fake) != nil)
        #expect(shouldDismissPopup(title: title, body: body) == true)
    }

    @Test("non-matching window is not dismissed")
    func nonMatchingNotDismissed() {
        let window = GPFakeNode(title: "GlobalProtect", children: [
            GPFakeNode(role: "AXScrollArea", children: [
                GPFakeNode(role: "AXGroup", children: [
                    GPFakeNode(role: "AXStaticText", value: "Welcome to GlobalProtect."),
                ]),
            ]),
        ])
        let title = GPWindowParser.title(in: window, using: .fake)
        let body = GPWindowParser.bodyText(in: window, using: .fake)
        #expect(shouldDismissPopup(title: title, body: body) == false)
    }
}
