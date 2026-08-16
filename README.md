# Edifier MR5 — Omarchy shell plugin

Control an [Edifier MR5](https://edifier.com) studio monitor over Bluetooth LE
from your [Omarchy](https://omarchy.org) bar — volume, sound mode, and the
9-band custom EQ curve — without the phone app.

The protocol is unofficial: it was reverse-engineered from the Edifier
ConneX Android app (decompiled + the app's own encrypted product/command
catalog decrypted with a key found in the app itself). It is not affiliated
with or endorsed by Edifier. It's known to work with the MR5; other Edifier
"box" products using the same `lib_connect` protocol family may work too but
haven't been tested.

## Features

- **Volume** — live slider, synced with the physical knob and the ConneX app
- **Sound Mode** — Monitor / Music / Custom, matching the speaker's own LED colors (red / green / white)
- **Custom EQ** — the speaker's 9-band graphic EQ (62 Hz–16 kHz), drag to adjust
- **Presets** — save/apply multiple custom curves locally (the speaker itself only holds one live curve; presets are pushed onto it on demand), plus a text share-code to hand a curve to someone else
- **Firmware version check** — informational only, see [Firmware updates](#firmware-updates) below
- A persistent background daemon holds the BLE connection open, so opening the panel is instant instead of reconnecting every time

## Requirements

- An Omarchy system running the Quickshell-based Omarchy shell
- `python-bleak` (BLE library): `sudo pacman -S python-bleak`
- `bluetoothd` (BlueZ) running, as usual on Omarchy

## Install

```sh
git clone https://github.com/<you>/omarchy-edifier-mr5 ~/.config/omarchy/plugins/local.edifier-mr5
omarchy plugin enable local.edifier-mr5 --section right
```

First connection does a one-time BLE scan for a device advertising manufacturer
ID `0x07E0` (Edifier) or named "EDIFIER BLE"; the found address is cached in
`~/.config/edifier-mr5/config.json` so future connects are instant. Put the
speaker in Bluetooth pairing mode (button on the back) for the first scan if
it isn't found — you do not need to pair it with your phone or this machine
via the normal OS Bluetooth pairing flow, the BLE control channel is separate
from that.

## Usage

Click the speaker icon in the bar. `r` refreshes, `s` opens/saves settings,
`Esc` closes. In Custom mode, drag any band to adjust the curve; presets and
a share-code exporter/importer live below the band sliders.

## Known limitations

- **BLE reconnects can be flaky.** If the daemon can't reconnect after a
  disconnect, the "Hard reconnect" button in Settings power-cycles the
  Bluetooth adapter, which reliably fixes it (but briefly disrupts any other
  Bluetooth devices on the machine).
- **Input source switching isn't implemented.** The wire command exists but
  its value mapping (which byte = XLR/RCA/AUX/Bluetooth) wasn't reliably
  pinned down; it's not exposed in the UI.
- **Firmware updates are not flashable from here, by design** — see below.

## Firmware updates

This plugin shows your installed firmware version next to the latest version
in Edifier's own product catalog, informational only. It does **not** flash
firmware. The MR5's OTA update sequence was located in the decompiled app
(`ota_ready` / `ota_start_master` / `ota_start_sub` commands) but the actual
chunked-transfer handshake was not reverse-engineered, and there's no way to
obtain the real firmware binary outside Edifier's own servers. Getting either
of those wrong mid-flash risks bricking the speaker with no confirmed
recovery path — a different risk class than a wrong volume/EQ byte, which is
trivially harmless. Use the official ConneX app for firmware updates.

## How it works

```
Panel.qml / Service.qml   — Omarchy shell bar widget (Quickshell/QML)
        │  spawns, one JSON command per call
        ▼
scripts/edifier_ctl.py    — thin CLI, talks to the daemon over a Unix socket
        │
        ▼
scripts/edifier_daemon.py — persistent process, holds the one BLE connection,
                             serializes all reads/writes, auto-reconnects
        │  bleak (BLE)
        ▼
scripts/edifier_protocol.py — packet framing + the reverse-engineered command set
```

The daemon exists because reconnecting fresh on every command turned out to
be unreliable for this speaker's BLE peripheral (BlueZ needed a power-cycle
to recover after repeated reconnects); one long-lived connection avoids that.

### Protocol summary

Packets: `[0xAA][appCode][commandIndex][lenHi][lenLo][payload...][checksum]`,
checksum = sum of all preceding bytes mod 256, written to GATT characteristic
`48090002-1a48-11e9-ab14-d663bd873d93` on service
`48093a01-1a48-11e9-ab14-d663bd873d93`; responses arrive as notifications on
`48090001-1a48-11e9-ab14-d663bd873d93`. The MR5 advertises manufacturer ID
`0x07E0` (2016) with its classic-Bluetooth MAC + protocol version + encryption
flag as manufacturer data.

See `scripts/edifier_protocol.py` for the full command table and the custom
EQ curve's byte layout (reverse-engineered and verified live against a real
unit).

## License

MIT — see [LICENSE](LICENSE).
