// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import AppKit
import Foundation
import Security

/// Verifies that a process is the genuine GlobalProtect client signed by Palo Alto Networks.
///
/// The cache key is the `NSRunningApplication` object identity, not the PID alone, so a reused
/// PID from a new process always triggers a fresh `SecCodeCheckValidity` call.
final class GPCodeSignatureVerifier {
    // Requirement pinned to Palo Alto Networks' Developer ID; validated against a known-good
    // install (`codesign -dv /Applications/GlobalProtect.app`).
    private static let requirementString =
        #"anchor apple generic and identifier "com.paloaltonetworks.GlobalProtect.client" and certificate leaf[subject.OU] = "PXPZ95SK77""#

    // Exposed for the unit test that validates the requirement string parses correctly.
    static let requirementStringForTesting = requirementString

    // Parsed once — SecRequirementCreateWithString is not free.
    // nonisolated(unsafe) is safe: this is a write-once lazy initialiser over a constant string.
    private nonisolated(unsafe) static let requirement: SecRequirement? = {
        var req: SecRequirement?
        SecRequirementCreateWithString(requirementString as CFString, [], &req)
        return req
    }()

    // Keyed by PID for O(1) lookup; value is the specific NSRunningApplication that was verified.
    // A different object at the same PID (reuse after exit) bypasses the cache.
    private var verified: [pid_t: NSRunningApplication] = [:]

    func verify(app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if let cached = verified[pid], cached === app, !cached.isTerminated {
            return true
        }
        verified.removeValue(forKey: pid)
        guard let req = Self.requirement else { return false }
        var codeRef: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef else { return false }
        let valid = SecCodeCheckValidity(code, [], req) == errSecSuccess
        if valid { verified[pid] = app }
        return valid
    }
}
