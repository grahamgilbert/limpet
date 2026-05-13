// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

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
            gpCodeRequirementString as CFString, [], &req
        )
        #expect(status == errSecSuccess)
        #expect(req != nil)
    }

    // MARK: - Invalid / unknown PID

    @Test("non-existent PID returns false")
    func nonExistentPIDReturnsFalse() {
        // PID 0 is the kernel on macOS; SecCodeCopyGuestWithAttributes won't
        // return a code object that satisfies the Palo Alto requirement.
        #expect(verifyGPCodeSignature(pid: 0) == false)
    }

    @Test("negative PID returns false")
    func negativePIDReturnsFalse() {
        #expect(verifyGPCodeSignature(pid: -1) == false)
    }

    // MARK: - Current process (not signed by Palo Alto Networks)

    @Test("current test-runner process fails Palo Alto requirement")
    func testRunnerFailsGPRequirement() {
        // The test runner is signed by Apple/Xcode tools, not Palo Alto Networks.
        // Verifying it must return false — it's the core confused-deputy guard.
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(verifyGPCodeSignature(pid: pid) == false)
    }

    // MARK: - VpnControlError description

    @Test("signatureVerificationFailed has a non-empty description")
    func errorDescription() {
        let err = VpnControlError.signatureVerificationFailed
        #expect(err.description.isEmpty == false)
    }
}
