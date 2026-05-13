// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import AppKit
import Foundation
import Security
import Testing
@testable import limpet

@Suite("GPCodeSignatureVerifier")
struct GPCodeSignatureVerifierTests {

    // MARK: - Requirement string

    @Test("requirement string is a valid SecRequirement")
    func requirementStringIsValid() {
        var req: SecRequirement?
        let status = SecRequirementCreateWithString(
            GPCodeSignatureVerifier.requirementStringForTesting as CFString, [], &req
        )
        #expect(status == errSecSuccess)
        #expect(req != nil)
    }

    // MARK: - Current process (not signed by Palo Alto Networks)

    @Test("current test-runner process fails Palo Alto requirement")
    func testRunnerFailsGPRequirement() {
        // The test runner is signed by Apple/Xcode tools, not Palo Alto Networks.
        // Verifying it must return false — it's the core confused-deputy guard.
        guard let self_ = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).first else { return }
        #expect(GPCodeSignatureVerifier().verify(app: self_) == false)
    }

    @Test("cache hit for a rejected app still returns false")
    func cacheHitForRejectedAppReturnsFalse() {
        // A rejected app must not be cached, so repeated calls must both return false.
        guard let self_ = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).first else { return }
        let v = GPCodeSignatureVerifier()
        let first = v.verify(app: self_)
        let second = v.verify(app: self_)   // exercises the non-cached rejection path
        #expect(first == false)
        #expect(second == false)
    }

    // MARK: - VpnControlError description

    @Test("signatureVerificationFailed has a non-empty description")
    func errorDescription() {
        let err = VpnControlError.signatureVerificationFailed
        #expect(err.description.isEmpty == false)
    }
}
