# limpet

Like the mollusc it's named after, limpet sticks your GlobalProtect VPN session to the network and won't let go — silently reconnecting after drops and dismissing the "you got disconnected" / "connectivity issues" / "session timeout" popups.

## Why

GlobalProtect 6.2.x on macOS:

1. After certain network blips, gives up reconnecting instead of retrying.
2. Throws a modal dialog every time the connection drops — you have to dismiss it manually before the agent will try again.

limpet fixes both.

## Features

- **VPN On** desired-state toggle. When on, limpet reconnects GlobalProtect any time it drops. When off, GP stays disconnected.
- **Live status** in the menubar — connected / connecting / disconnected / disabled.
- **Auto-dismiss** the GP disconnect / connectivity-issues / session-timeout popup.
- **Start at login** via `SMAppService`.

## Requirements

- macOS 26 (Tahoe)
- GlobalProtect 6.2+ at `/Applications/GlobalProtect.app`

## Install

1. Download the latest **`limpet-X.Y.Z.dmg`** from [Releases](https://github.com/grahamgilbert/limpet/releases/latest).
2. Open the DMG, drag **limpet.app** to **Applications**.
3. Launch limpet from `/Applications/`.

The app is signed with a Developer ID and notarized by Apple, so Gatekeeper opens it without warnings. Once installed, limpet checks for updates daily via Sparkle — toggle it off in Preferences if you'd rather check manually.

### Building from source

```sh
git clone https://github.com/grahamgilbert/limpet.git
cd limpet
xcodebuild -scheme limpet -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/limpet-*/Build/Products/Release/limpet.app /Applications/
```

Building from source requires a Developer ID Application certificate in your keychain, or you can ad-hoc sign by passing `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=` to `xcodebuild`.

## First launch

1. Open `/Applications/limpet.app`.
2. limpet shows a permission window — click **Grant Permission**.
3. macOS shows the standard Accessibility prompt; click **Open System Settings**.
4. Toggle limpet on in the Accessibility list.
5. The permission window closes automatically. limpet now lives in the menubar.

limpet uses Accessibility to control GlobalProtect — no Automation, Full Disk Access, or other privileges.

## Using it

Click the shell icon in the menubar:

- **VPN On** — flip to disconnect/reconnect. While on, limpet keeps GP connected even after network drops.
- **Start at Login** — flip to launch limpet automatically when you log in.
- **Quit limpet** — stops the app.

The menubar icon and the **Connected / Disconnected / Connecting** label always reflect GlobalProtect's actual state, read live from `/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log`.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — how limpet works internally.
- [Development](docs/DEVELOPMENT.md) — building, testing, linting.
- [Releasing](docs/RELEASING.md) — cutting a signed, notarized release.
- [Permissions](docs/PERMISSIONS.md) — exactly what limpet uses, and why.
- [Limitations](docs/LIMITATIONS.md) — known gotchas and edge cases.

## License

[Apache 2.0](LICENSE).
