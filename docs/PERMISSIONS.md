# Permissions

## Accessibility — required

limpet needs Accessibility permission to control the GlobalProtect UI. Without it, limpet falls back to read-only status display and can't connect, disconnect, or dismiss popups.

It's used to:

1. Click GP's menubar status item to open the popover.
2. Press the **Connect** / **Disconnect** button in the popover.
3. Fill in and confirm the "reason for disconnect" sheet that GP presents when `agent-user-override = with-comment` is configured.
4. Press OK on GP's disconnected / connectivity-issues / session-timeout dialogs.

Granted in **System Settings → Privacy & Security → Accessibility**. limpet adds itself to the list automatically when you click **Grant Permission** on first launch.

## Login Item — optional

If you enable **Start at Login**, limpet registers itself with `SMAppService.mainApp`. macOS lists it in **System Settings → General → Login Items & Extensions**. You can disable it from either the menu or System Settings.

## App Sandbox — disabled

The macOS App Sandbox is disabled because:

- GP's logs at `/Library/Logs/PaloAltoNetworks/GlobalProtect/` aren't reachable from inside a sandbox container.
- Accessibility scripting requires system-wide reach.

This is the same model 1Password, iTerm, Dropbox, and most menubar utilities use.

## Hardened Runtime — enabled

limpet ships with the hardened runtime enabled. Combined with Developer ID code signing, this lets macOS pin the Accessibility permission to limpet's stable designated requirement so the grant persists across rebuilds and updates.

## What limpet does NOT request

- **Automation** — limpet uses the Accessibility API directly, not AppleScript.
- **Full Disk Access** — limpet only reads `/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log`, which is world-readable.
- **Network** — limpet doesn't talk to the network. It reads a log file and clicks UI buttons.
- **Screen Recording, Camera, Microphone, Contacts, Calendar** — none of these.
