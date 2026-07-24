// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import ApplicationServices
import Foundation
import Testing
@testable import limpet

@Suite("AX messaging timeout")
struct AXMessagingTimeoutTests {
    @Test("timeout is a bounded, non-zero value")
    func timeoutIsSane() {
        // A timeout of 0 silently reverts AX messaging to the unbounded default —
        // the exact main-thread freeze this guards against. Keep it small + positive.
        #expect(AX.messagingTimeout > 0)
        #expect(AX.messagingTimeout <= 10)
    }

    @Test("appElement produces a reference the messaging API accepts")
    func appElementIsValid() {
        let element = AX.appElement(getpid())
        // No public getter exists for the messaging timeout, so re-setting it is
        // the only observable proof that appElement returned a valid AX reference.
        #expect(AXUIElementSetMessagingTimeout(element, AX.messagingTimeout) == .success)
    }

    @Test("setGlobalMessagingTimeout applies without error")
    func globalTimeoutApplies() {
        AX.setGlobalMessagingTimeout()
        #expect(AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AX.messagingTimeout) == .success)
    }
}

@Suite("AX.findNode")
struct AXHelpersTests {
    // Simple tree node for testing without needing real AXUIElements.
    private struct Node {
        let value: Int
        let children: [Node]
    }

    private func find(_ root: Node, where match: (Node) -> Bool) -> Node? {
        AX.findNode(root, children: { $0.children }, where: match)
    }

    @Test("finds root when it matches")
    func findsRoot() {
        let tree = Node(value: 1, children: [])
        #expect(find(tree, where: { $0.value == 1 })?.value == 1)
    }

    @Test("finds a direct child")
    func findsDirectChild() {
        let tree = Node(value: 1, children: [Node(value: 2, children: []), Node(value: 3, children: [])])
        #expect(find(tree, where: { $0.value == 3 })?.value == 3)
    }

    @Test("finds a deeply nested node")
    func findsDeepNode() {
        let tree = Node(value: 0, children: [
            Node(value: 1, children: [
                Node(value: 2, children: [
                    Node(value: 3, children: [
                        Node(value: 99, children: [])
                    ])
                ])
            ])
        ])
        #expect(find(tree, where: { $0.value == 99 })?.value == 99)
    }

    @Test("returns nil when no node matches")
    func returnsNilOnMiss() {
        let tree = Node(value: 1, children: [Node(value: 2, children: [])])
        #expect(find(tree, where: { $0.value == 42 }) == nil)
    }

    @Test("returns first match in DFS order")
    func returnsFirstDFSMatch() {
        // Tree:      1
        //           / \
        //          2   3
        //         /
        //        4
        // DFS order: 1, 2, 4, 3 — first node with value > 1 should be 2.
        let tree = Node(value: 1, children: [
            Node(value: 2, children: [Node(value: 4, children: [])]),
            Node(value: 3, children: [])
        ])
        #expect(find(tree, where: { $0.value > 1 })?.value == 2)
    }

    @Test("handles a 2000-level deep chain without stack overflow")
    func veryDeepTreeDoesNotCrash() {
        // Regression test: recursive DFS crashed limpet with EXC_BAD_ACCESS
        // (stack overflow) when GlobalProtect's AX tree was ~2500 nodes deep.
        var node = Node(value: 2000, children: [])
        for i in stride(from: 1999, through: 0, by: -1) {
            node = Node(value: i, children: [node])
        }
        #expect(find(node, where: { $0.value == 2000 })?.value == 2000)
    }
}
