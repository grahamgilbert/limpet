// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Testing
@testable import limpet

// MARK: - Test stub

/// Minimal AX tree node for testing GPWindowParser without real AXUIElements.
struct GPFakeNode {
    var role: String?
    var value: String?
    var title: String?
    var children: [GPFakeNode]

    init(role: String? = nil, value: String? = nil, title: String? = nil, children: [GPFakeNode] = []) {
        self.role = role
        self.value = value
        self.title = title
        self.children = children
    }
}

extension GPWindowAccessors where Node == GPFakeNode {
    static let fake = GPWindowAccessors(
        role: { $0.role },
        value: { $0.value },
        title: { $0.title },
        children: { $0.children }
    )
}

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
