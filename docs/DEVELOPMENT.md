# Development

## Requirements

- macOS 26 (Tahoe)
- Xcode 26+
- A Developer ID Application certificate in your keychain (for signed builds)
- SwiftLint (`brew install swiftlint`)

## Build

```sh
xcodebuild -project limpet.xcodeproj -scheme limpet -configuration Debug build
```

The signed `.app` lands in `~/Library/Developer/Xcode/DerivedData/limpet-*/Build/Products/Debug/`.

## Test

```sh
xcodebuild -project limpet.xcodeproj -scheme limpet -destination 'platform=macOS' -enableCodeCoverage YES test
```

Tests use Swift Testing (`import Testing` / `@Test`) — not XCTest. Fakes in `limpetTests/Fakes/` let the engine run without GP installed.

## Lint

```sh
swiftlint
```

CI uses `swiftlint --strict`.

## Coverage

CI gates merges on ≥85 % line coverage on `limpet/Engine/` and `limpet/State/`. The check is in `scripts/check_coverage.swift`.

Files explicitly excluded from the gate (because they only run against a live macOS GUI with GP installed):
- `AXHelpers.swift`
- `VpnController.swift` — `AccessibilityVpnController`
- `GlobalProtectWindowProvider.swift`
- `SMAppServiceLoginItem.swift`

These are covered by the manual verification plan in [LIMITATIONS.md](LIMITATIONS.md).

To run coverage locally:

```sh
xcodebuild ... -resultBundlePath /tmp/limpet.xcresult test
xcrun xccov view --report --json /tmp/limpet.xcresult > /tmp/coverage.json
swift scripts/check_coverage.swift /tmp/coverage.json 0.85 limpet/Engine/ limpet/State/
```

## Code signing

The project signs with `Developer ID Application` (manual style) using team `9D8XP85393`. Adjust to your own team in `limpet.xcodeproj/project.pbxproj` if you fork.

A stable code-signing identity is required so macOS preserves Accessibility permission across rebuilds. Ad-hoc signing breaks the TCC entry on every build.

## Iterating

Rebuilds change the binary's signature *content* but not its designated requirement, so Accessibility permission persists. To pick up code changes on the running app:

```sh
xcodebuild -project limpet.xcodeproj -scheme limpet -configuration Debug build && \
  killall limpet 2>/dev/null; \
  rm -rf /Applications/limpet.app && \
  cp -R ~/Library/Developer/Xcode/DerivedData/limpet-*/Build/Products/Debug/limpet.app /Applications/ && \
  open /Applications/limpet.app
```

Always run from `/Applications/` — TCC and `SMAppService` both behave poorly with apps at transient DerivedData paths.

## Logs

```sh
log show --last 5m --predicate 'subsystem == "com.grahamgilbert.limpet"' --style compact --info
```

Useful categories:
- `controller` — connect/disconnect attempts
- `loginitem` — SMAppService state
- `watchdog` — reconciliation decisions
- `monitor` — log tailing

## CI

`.github/workflows/test.yml` runs build, test, coverage gate, and SwiftLint on every push and PR.
`.github/workflows/build.yml` runs a Release build on `main`.
