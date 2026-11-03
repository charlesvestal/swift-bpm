# swift-bpm

[![CI](https://github.com/charlesvestal/swift-bpm/actions/workflows/ci.yml/badge.svg)](https://github.com/charlesvestal/swift-bpm/actions/workflows/ci.yml)

Blood-pressure tracking for macOS (SwiftUI, SwiftData, Swift Charts). It
downloads readings from a Hartmann Veroval BPM25 over USB or any monitor that
implements the standard Bluetooth Blood Pressure Service, and also takes manual
entry and CSV import. It exports CSV and PDF reports.

## Layout

- `Sources/BPMKit` – Swift package library, no UI
  - `Readings/` – `DeviceReading`, the `ReadingSource` protocol, the dedup key, CSV codec, BP categories
  - `Veroval/` – BPM25 wire protocol and `BPM25Source`
  - `Bluetooth/` – 0x2A35 measurement decoder and `BluetoothBPSource` (CoreBluetooth)
  - `Serial/` – termios serial port and IOKit lookup of ports by USB ID
- `Sources/bpm-probe` – CLI that dumps the raw BPM25 protocol
- `App/BPTracker` – the macOS app (sandboxed; serial, Bluetooth and user-selected-file entitlements)
- `App/BPTrackerTests` – importer, dedup, CSV and PDF tests, plus an opt-in hardware test
- `project.yml` – XcodeGen spec; run `xcodegen generate` after adding files

## Building and testing

```sh
swift test                                   # BPMKit
xcodegen generate
xcodebuild -scheme BPTracker -destination 'platform=macOS' test
# with a BPM25 attached and in PC mode, from inside the sandbox:
TEST_RUNNER_BPM25_HARDWARE_TEST=1 xcodebuild -scheme BPTracker -destination 'platform=macOS' \
  test -only-testing:BPTrackerTests/BPM25HardwareTests
```

## Features

- Profiles; each monitor user is linked to a profile or set to "Don't import".
- Veroval BPM25 auto-import over USB when the monitor is in PC mode; Bluetooth
  Blood Pressure Service import; manual entry.
- Overview: summary tiles, trend chart with configurable thresholds, readings
  table with MAP and pulse pressure. Readings can be edited, moved, hidden
  (kept but left out of analysis) or deleted, with undo.
- Categories per reading from ESH 2023 (default, as on European monitors such
  as Veroval) or ACC/AHA 2017, chosen in Settings › Analysis.
- Statistics: average or median by time of day, category distribution, and
  daily/weekly/monthly ranges. Back-to-back readings can be averaged.
- Measurement week: the ESH home-monitoring protocol (7 days, two readings
  each morning and evening, day 1 excluded) with reminders, per-session
  progress, the home average against 135/85, and a PDF report.
- Periods: rolling (7/30/90 days, 1 year, all) or calendar week/month/year
  with paging.
- CSV import/export, import from other apps' exports (presets for Beurer,
  Medisana, Microlife, OMRON, Sanitas, Veroval, or a custom column mapping),
  PDF report (export or share), and daily CSV backups that keep the newest N.
- Apple Health, via an iPhone shortcut: HealthKit has no store on the Mac, so
  new readings of one profile are written to an iCloud Drive folder (one new
  file per batch, lines like `2026-11-02 07:05,128,82,66`). A shortcut logs
  them with Log Health Sample and deletes each file. It skips a reading when
  Health already has a systolic sample in the same minute (it compares
  formatted start times, since the Find filter's "between" only works by day),
  and logs heart rate only when the pulse is above 0. Run it by hand or from a
  Time of Day automation; the Mac side checks for new readings every minute
  while the app runs. The shortcut ships with the app (Settings › Apple Health ›
  Add to Shortcuts) and is generated and signed by `Tools/make-health-shortcut.py`;
  it reads iCloud Drive › Shortcuts › Blood Pressure.

## Releases

`Tools/release.sh` builds a Developer ID-signed Release and zips it; with
`NOTARY_PROFILE=<profile>` it also notarizes and staples, and with `INSTALL=1`
it installs to /Applications. The icon is drawn by `Tools/make-icon.swift`.

## Data model

- Profiles hold readings. Each device user (BPM25 user 1/2, or a Bluetooth
  monitor's user ID) is linked to a profile; the first import asks which one,
  and Settings can relink later (moving that user's readings with it).
- Readings are deduplicated by device + device user + timestamp to the minute
  (`ReadingKey`). The BPM25's index byte shifts as readings are added, so it is
  not used. Manual readings use a per-profile device ID.
- CSV export keeps the device ID and user, so re-importing a CSV, or later
  downloading the same readings from the monitor, does not duplicate them.

## Running the probe

```sh
swift build
.build/debug/bpm-probe --list        # see serial devices and their USB IDs
.build/debug/bpm-probe               # auto-picks the first 067b:2303 bridge
.build/debug/bpm-probe --port /dev/cu.usbserial-XXXX --no-close
```

Put the monitor in PC/transfer mode first. The probe sends `A5 F9 01 01 FB`,
hex-dumps the full response with timing, decodes it using the documented
layout (marking anything implausible rather than dropping it), tests a few
checksum guesses against the trailing byte, then does the same for
`A6 F9 01 01 FB`. Raw responses are saved to `probe-captures/` (gitignored)
so they can become test fixtures.

## BPM25 protocol

Checked against a real BPM25 on 2026-11-02 (captures with readings for both
users). Items marked *unconfirmed* still need a capture that exercises them.

- PL2303 bridge, USB `067b:2303`; 19200 baud 8N1, no flow control.
- Request `A5 F9 01 01 FB`: the device streams its stored readings for both
  users in one reply, user 1 first. The last
  request byte is the sum of the middle three (`F9+01+01 = FB`).
- Request `A6 F9 01 01 FB`: ends the session. The device sends no reply, even
  with user-2 readings stored.
- Response: header `A6 F9 <count>`, `count` × 14-byte records, then a checksum
  byte. Confirmed: the checksum is the sum of every byte after the first,
  modulo 256 (the same rule as the requests).
- Record, big-endian: `[0]` user (1 or 2), `[1]` index (per user, newest = 1;
  it shifts when readings are added, so it can't identify a reading), `[2-3]` systolic, `[4-5]`
  diastolic (16-bit width *unconfirmed*: no value above 255 seen yet), `[6]`
  flags (bit 0 = irregular heartbeat: another tool reports IHB for the same
  reading, though no symbol was noticed on the device display), `[7]` pulse,
  `[8]` month, `[9]` day, `[10-11]` year, `[12]` hour, `[13]` minute.
  Times are device local time with no time zone.

### Sources

These projects were read as protocol documentation only. No code was copied
from them (they are GPL/AGPL licensed):

- [codeberg.org/LazyT/ubpm](https://codeberg.org/LazyT/ubpm) – Veroval BPM25/GCE604 plugin, and the
  migration presets (column layouts and date formats of vendor CSV exports) behind
  `ColumnMapping.presets`
- [github.com/JimKnopfIoT/harbour-svero](https://github.com/JimKnopfIoT/harbour-svero)
- [github.com/ignisf/vdc_export](https://github.com/ignisf/vdc_export) – this one covers the
  Veroval *duo control*, which uses a separate ASCII protocol over CDC-ACM
  (`?MRN1`, `?MDR1A`). It is not the BPM25 protocol, but it could become a
  third `ReadingSource` later.

## License

MIT; see [LICENSE](LICENSE).
