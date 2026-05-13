// Copyright 2026 Graham Gilbert. Licensed under the Apache License,
// Version 2.0. See LICENSE in the repo root for details.

import Foundation
import Security

// Requirement pinned to Palo Alto Networks' Developer ID; validated against a known-good install
// (`codesign -dv /Applications/GlobalProtect.app`).
let gpCodeRequirementString =
    #"anchor apple generic and identifier "com.paloaltonetworks.GlobalProtect.client" and certificate leaf[subject.OU] = "PXPZ95SK77""#

/// Returns `true` iff the process with the given PID is the genuine GlobalProtect client
/// signed by Palo Alto Networks (Team ID PXPZ95SK77).
func verifyGPCodeSignature(pid: pid_t) -> Bool {
    var codeRef: SecCode?
    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
          let code = codeRef else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(
        gpCodeRequirementString as CFString, [], &requirement
    ) == errSecSuccess, let req = requirement else { return false }
    return SecCodeCheckValidity(code, [], req) == errSecSuccess
}
