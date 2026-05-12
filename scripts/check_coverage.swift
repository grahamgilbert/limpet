#!/usr/bin/env swift
//
// Reads `coverage.json` (output of `xcrun xccov view --report --json …`),
// computes line coverage for files under each of the supplied path
// prefixes, and exits non-zero if any prefix's coverage is below the
// threshold.
//
// Usage:
//   swift scripts/check_coverage.swift coverage.json 0.85 limpet/Engine/ limpet/State/

import Foundation

guard CommandLine.arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: check_coverage <coverage.json> <threshold> <prefix> [prefix ...]\n".utf8))
    exit(2)
}

let jsonPath = CommandLine.arguments[1]
guard let threshold = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("threshold must be a number between 0 and 1\n".utf8))
    exit(2)
}
let prefixes = Array(CommandLine.arguments.dropFirst(3))

guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else {
    FileHandle.standardError.write(Data("cannot read \(jsonPath)\n".utf8))
    exit(2)
}
guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    FileHandle.standardError.write(Data("\(jsonPath) is not a JSON object\n".utf8))
    exit(2)
}

// xccov JSON structure: {"targets": [{"files": [{"path": "...", "executableLines": N, "coveredLines": N}]}]}
//
// Files excluded from the gate — these are thin platform/AX wrappers that
// can only run against a live macOS GUI session with GlobalProtect installed
// and Accessibility granted. They're covered by the manual verification plan,
// not by unit tests.
let excludedSubstrings: [String] = [
    "AXHelpers.swift",
    "VpnController.swift",                  // AccessibilityVpnController
    "GlobalProtectWindowProvider.swift",    // AX-driven WindowProvider
    "SMAppServiceLoginItem.swift",          // SMAppService wrapper
    "InstallLocation.swift",                // NSAlert + NSWorkspace UI flow
    "GlobalProtectInstallation.swift",      // NSAlert UI flow
    "LoginItemNotifier.swift",              // UNUserNotificationCenter wrapper
    "Updater.swift",                        // SPUStandardUpdaterController wrapper
]

struct PrefixStats { var executable = 0; var covered = 0 }
var stats: [String: PrefixStats] = Dictionary(uniqueKeysWithValues: prefixes.map { ($0, PrefixStats()) })

if let targets = root["targets"] as? [[String: Any]] {
    for target in targets {
        guard let files = target["files"] as? [[String: Any]] else { continue }
        for file in files {
            guard let path = file["path"] as? String,
                  let exec = file["executableLines"] as? Int,
                  let cov = file["coveredLines"] as? Int else { continue }
            if excludedSubstrings.contains(where: { path.contains($0) }) { continue }
            for prefix in prefixes where path.contains(prefix) {
                stats[prefix]!.executable += exec
                stats[prefix]!.covered += cov
            }
        }
    }
}

var failed = false
print("Coverage gate: ≥ \(Int(threshold * 100))%")
for prefix in prefixes {
    let s = stats[prefix] ?? PrefixStats()
    if s.executable == 0 {
        print("  \(prefix) — no executable lines found, skipping")
        continue
    }
    let frac = Double(s.covered) / Double(s.executable)
    let pct = String(format: "%.1f%%", frac * 100)
    let ok = frac >= threshold ? "✅" : "❌"
    print("  \(ok) \(prefix) \(pct) (\(s.covered)/\(s.executable))")
    if frac < threshold { failed = true }
}

if failed { exit(1) }
