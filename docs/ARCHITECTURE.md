# Architecture

```
   +-------------------+        AsyncStream<ConnectionState>       +----------+
   |  PanGPS.log       |  ───►  LogTailingStatusMonitor   ───────► | Watchdog |
   +-------------------+                                            +----┬─────+
                                                                         │
                                                                         │ desired vs. actual
                                                                         ▼
   +-------------------+         AX clicks via
   |  GlobalProtect UI |  ◄─── AccessibilityVpnController  ──── connect()/disconnect()
   +-------------------+
                 ▲
                 │ AX press
                 │
   +---------------------+
   |  PopupDismisserLoop |  one tick/sec, looks for "disconnected/connectivity/timeout" popups
   +---------------------+
```

## Status monitoring

GlobalProtect on macOS exposes no public CLI or IPC, so we read its log to derive connection state.

`/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log` contains a `NetworkConnectionMonitorThread` line emitted every few seconds, with `m_bAgentEnabled`, `IsConnected()`, and `IsVPNInRetry()` flags. `LogTailingStatusMonitor`:

1. Tails the file with a poll loop.
2. Handles log rotation (PanGPS.log → PanGPS.1.log) by detecting inode changes and reopening.
3. Parses each line via `parsePanGPSLine` — pure function, easy to unit-test.
4. Emits a `ConnectionState` (`.connected`, `.connecting`, `.disconnected`, `.disabled`, `.unknown`) over an `AsyncStream`, **deduplicated** so only transitions reach the watchdog.

## Control

`AccessibilityVpnController` drives GP's UI via the macOS Accessibility API:

1. Find the GP app via `NSRunningApplication` (bundle id `com.paloaltonetworks.GlobalProtect.client`).
2. If GP's popover isn't open, click its menubar status item via `kAXExtrasMenuBarAttribute` (with system-wide AX search as fallback for Tahoe's Control Center hosting).
3. Find the Connect / Disconnect button in the popover by case-insensitive title match and `AXPress` it.
4. On disconnect, fill the "reason for disconnect" sheet (which appears because `agent-user-override = with-comment` in PAN's config) and press OK.

## Reconciliation

`Watchdog` is an `actor` that consumes the status stream and reconciles desired vs. actual state.

| desired | observed | action |
|---------|----------|--------|
| on | connected | none |
| on | connecting | wait `connectingGrace` (15 s) before re-clicking |
| on | disconnected/disabled | click Connect |
| off | connected/connecting | click Disconnect |
| off | disconnected/disabled | none |

After issuing any action, the watchdog records a **state snapshot**. As long as the next observation matches the snapshot (i.e. nothing happened yet), no further action is issued until exponential backoff (8 s, doubling, capped at 5 min) elapses. As soon as the observed state changes, the snapshot clears and the watchdog reconciles fresh.

This prevents click-storms when GP is slow to respond or the user toggles repeatedly.

## Popup dismissal

`PopupDismisserImpl` runs once per second:

1. Enumerate GP's AX windows.
2. For each window titled `"GlobalProtect"`, read its body text.
3. If the body contains `"disconnected"`, `"connectivity issues"`, or `"session timeout"`, press the first button in the window.

The pattern matches the original `gp-bye.applescript` but lives in-process so we only need one Accessibility permission grant.

## Project layout

```
limpet/                     SwiftUI app
├── limpetApp.swift         @main, scenes, wires engine to UI
├── Engine/
│   ├── ConnectionState.swift     Enum + parsePanGPSLine() (pure)
│   ├── TimeSource.swift          Clock indirection for tests
│   ├── Protocols.swift           VpnControlling, VpnStatusStreaming, …
│   ├── VpnStatusMonitor.swift    Log tailer + rotation
│   ├── VpnController.swift       Accessibility-driven connect/disconnect
│   ├── PopupDismisser.swift      AX-driven popup auto-dismiss
│   ├── GlobalProtectWindowProvider.swift  AX window enumeration
│   ├── Watchdog.swift            Reconciliation actor
│   └── AXHelpers.swift           Tiny wrappers around AX C API
├── State/
│   ├── AppState.swift            @Observable connection state
│   ├── Preferences.swift         desiredOn + startAtLogin
│   └── SMAppServiceLoginItem.swift   Real LoginItemRegistering impl
└── UI/
    ├── StatusIcon.swift
    ├── MenuBarContent.swift
    └── PermissionWindow.swift

limpetTests/                Swift Testing (`import Testing`)
├── ParsePanGPSLineTests.swift
├── LogTailingStatusMonitorTests.swift
├── WatchdogTests.swift
├── PopupDismisserTests.swift
├── AppStateTests.swift
├── PreferencesTests.swift
├── StatusIconTests.swift
├── Fakes/                  RecordingVpnController, FakeTimeSource, …
└── Fixtures/               Real PanGPS log snippets
```
