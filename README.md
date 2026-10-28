# Afterhours BlackOut

[🇻🇳 Xem bản tiếng Việt](README.vi.md)

Menu-bar app for macOS that turns the built-in MacBook display **off for real**
(like unplugging a cable) while you work on an external monitor — and brings it
back automatically when the cable is pulled.

Inspired by the BlackOut feature in [Lunar](https://github.com/alin23/Lunar).

## Features

- **Real disconnect** — hides the built-in (or any) display from the arrangement
  via the hidden `CGSConfigureDisplayEnabled` CoreGraphics API: link drops,
  backlight goes off, GPU stops driving it. Not a black overlay.
- **Auto rule** — "Keep built-in off while a monitor is attached": restores the
  built-in when the cable is unplugged and re-applies when it's plugged back in.
- **Watchdog** — polls the real display topology every 2 s, so the built-in
  comes back even when macOS posts no `didChangeScreenParametersNotification`
  (which happens with a real cable pull) and never leaves the Mac with zero
  active displays.
- **Per-display brightness** — hardware brightness (`DisplayServicesSetBrightness`)
  on the built-in panel; gamma-table dimming on external monitors that don't
  accept brightness over DisplayServices.
- **Stable identity** — displays are tracked by `CGDisplayCreateUUIDFromDisplayID`,
  because `CGDirectDisplayID` values are reassigned after a reconnect
  (observed: 1 → 11 → 12 → 13 on macOS 27).
- **Crash-safe** — disconnected displays are recorded in `UserDefaults` and
  re-enabled on the next launch, plus restored on termination.

## Requirements

- macOS 13+ (developed and tested on macOS 27.0.1, Apple Silicon)
- Apple Silicon for the disconnect path (the API is wrapped in `arch(arm64)`
  style guards in spirit; on unsupported builds the app reports and degrades)
- Xcode / Swift 6 toolchain for building

## Build

```bash
./build-app.sh          # swift build + package "Afterhours BlackOut.app" + ad-hoc sign
open "Afterhours BlackOut.app"
```

The build script ad-hoc re-signs the bundle every run — replacing the binary
inside an App Store-style bundle without re-signing gets the app killed by
launchd on modern macOS.

## Usage

| Action | How |
|---|---|
| Toggle a display | Switch in the popover, or click the row |
| Turn off / on the built-in | "Built-in" button |
| Restore everything | "Restore All", `⌃⌘6` (global Carbon hotkey), or `Esc` |
| Auto rule | Toggle at the bottom of the popover |

The built-in panel is never disconnected when it is the last active display,
and if the last display disappears the watchdog force-enables the built-in.

Diagnostics flags:

```bash
"Afterhours BlackOut.app/Contents/MacOS/AfterhoursBlackOut" --self-test   # brightness + disconnect round trip
"Afterhours BlackOut.app/Contents/MacOS/AfterhoursBlackOut" --snapshot    # render the panel to /tmp
```

Runtime log: `/tmp/afterhours-blackout.log`.

## Caveats

- `CGSConfigureDisplayEnabled` is a private, undocumented API. It still works on
  macOS 27.0.1 but Apple can remove it in any release; the app fails gracefully
  with an error message when the symbol is gone.
- External-monitor brightness goes through the gamma table (`software dim`) on
  this setup: `IOAVServiceCreateWithService` returns nil on macOS 27 for
  unsigned apps, so DDC/CI writes are blocked. Gamma dimming is labelled as such
  in the UI and reset on quit/startup.
- Re-enabled displays get a new `CGDirectDisplayID` a few seconds after they
  come back; the menu may lag behind for a moment while `NSScreen` catches up.

## Project layout

```
Package.swift                     SwiftPM manifest (macOS 13+, Swift 6)
Sources/AfterhoursBlackOut/main.swift  app, display engine, watchdog, UI
Info.plist                        bundle metadata (LSUIElement)
build-app.sh                      build + package + ad-hoc sign
index.html                        earlier HTML prototype (kept for reference)
```
