# Limitations & known issues

## GP UI changes between releases

`AccessibilityVpnController` walks GlobalProtect's AX tree by button title and window structure. PAN occasionally renames buttons or restructures the popover between minor releases. If a future GP version moves things around, the controller may need an update.

The button matcher already accepts case-insensitive substrings of `Connect / Enable / Reconnect` and `Disconnect / Disable`, which covers the variants seen in 6.2.x.

## Hard-coded disconnect reason

When `agent-user-override = with-comment` is set in GP's config, disconnecting prompts for a reason. limpet fills it with a fixed string (`"limpet user toggle"`). If your org's policy uses a different sheet structure or requires specific wording, edit `AccessibilityVpnController.fillDisconnectCommentAndConfirm`.

## Admin-disabled GP

If your admin pushes `disable-globalprotect = 1`, limpet observes `.disabled` in the log and clicks Connect, which won't help. limpet doesn't manage GP admin policies.

## Log path assumed at default location

limpet reads `/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log`. PAN could move this in a future version. The path is a constant in `VpnStatusMonitor.swift`.

## Single-user only

limpet runs in the user session and reads logs that PanGPS writes for the active user. It doesn't manage GP for other logged-in users on the same Mac.

## macOS 26 only

The deployment target is macOS 26 (Tahoe). Backporting is straightforward but not maintained. Lower the deployment target in `limpet.xcodeproj` and replace any Tahoe-only API uses (`@Observable`, Swift 6 `Sendable`-related changes) as needed.

## Manual verification

Some code paths can't run on a CI runner because they need:
- GlobalProtect installed
- Accessibility permission granted
- A live macOS GUI session

Specifically: `AccessibilityVpnController`, `GlobalProtectWindowProvider`, `AXHelpers`, and `SMAppServiceLoginItem`.

These are excluded from CI coverage and verified manually before tagging a release:

1. **Build** — `xcodebuild` succeeds, app launches as menubar-only.
2. **Permissions** — Permission window shows, Grant Permission auto-adds limpet to the Accessibility list.
3. **Status accuracy** — kill PanGPS, observe limpet transitions through `.connecting` → `.connected` correctly.
4. **Toggle off → on** — disconnect/connect via limpet matches GP UI state.
5. **Network drop** — toggle Wi-Fi off and on, watch GP retry, watchdog should not click-storm.
6. **Start at Login** — toggle, log out, log in, verify state persists.
7. **Popup dismissal** — force a disconnect popup (e.g. drop Wi-Fi mid-session), verify it auto-dismisses within ~1 s.
8. **Quit** — no leftover processes (`pgrep -f limpet`).
