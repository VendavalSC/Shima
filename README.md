<p align="center"><img src="docs/assets/icon.png" width="128" alt="Shima icon"></p>

<h1 align="center">Shima</h1>
<p align="center"><b>島 — an island for your Mac's notch.</b><br>Free, open source, and made to feel like something Apple would ship.</p>
<p align="center"><a href="https://github.com/VendavalSC/Shima/releases/latest">Download</a></p>

<p align="center"><img src="docs/assets/shots/open-player.png" width="440" alt="Now Playing in the open notch"></p>

## What it does

- **Now Playing** — artwork, a waveform tinted by the cover, a scrubber, and output switching.
- **Pages you swipe through** — Calendar, a Timer with a ruler you slide, System stats and a file Shelf. Two-finger swipe; reorder them in Settings.
- **Notifications in the notch** — macOS's banner steps aside, and you can **reply** to chats right there.
- **Live activities** — AirPods connecting (with Apple's own spinning model and battery), charging, Caps Lock, Focus, and drives with an Eject button.
- **Notch or island** — hang from the top edge, or float like iPhone's Dynamic Island. Per display, on every display.
- **Light on your Mac** — no polling loops; idle at ~0% CPU.

## Requirements

macOS 26 or later. Works with or without a camera notch.

## Install

Download `Shima.zip` from [Releases](https://github.com/VendavalSC/Shima/releases/latest), unzip, and move Shima to Applications.
Shima isn't notarized yet, so the first time: right-click it → **Open** → **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Shima.app
```

## Permissions (all optional)

| Feature | Permission |
|---|---|
| Notifications, replies, Caps Lock | Accessibility |
| Focus changes | Full Disk Access |
| Calendar page and Up Next | Calendars |

Nothing leaves your Mac.

## Build it yourself

Only the Command Line Tools are needed, no Xcode:

```bash
./build.sh && open build/Shima.app
```

To keep permissions across rebuilds, create a self-signed **Code Signing** certificate named `Shima Development` in Keychain Access (or put another name in `.signing-identity`).

## License

[GPL-3.0](LICENSE)
