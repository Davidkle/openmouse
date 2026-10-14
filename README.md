# OpenMouse

A native macOS replacement for Logitech Options+, written in Swift. It has no account, uses no network, and keeps everything in one local JSON file.

It talks to Logitech mice directly over HID++ (via Bolt or Unifying receivers, Bluetooth, or USB) and remaps buttons and scrolling with a `CGEventTap`.

## Features

- **Button remapping** from a clickable mouse diagram: middle click, back, forward, the gesture button, the Mode Shift button, wheel tilt left/right, and the MX Master 4 haptic panel.
- **Gestures**: hold a button and move the mouse up, down, left or right to trigger separate actions. The gesture button defaults to Mission Control, App Exposé and switching desktops, like Options+.
- **Scroll wheel**: reverse the direction for the mouse only (trackpad natural scrolling is left alone), set vertical and horizontal speed, and assign actions to scroll up or down.
- **SmartShift**: turn it on or off, set the sensitivity, or pick a fixed ratchet or free-spin mode.
- **Thumb wheel**: reverse it, change its speed, or remap up, down and tap.
- **DPI**: a slider plus presets you can cycle through with a button.
- **Per-app profiles**: override any button while a specific app is in front.
- **Actions**: keyboard shortcuts (recorded), copy and paste, browser back and forward, tabs, zoom, Mission Control, App Exposé, Spaces, Show Desktop, Launchpad/Apps, screenshots, lock, sleep, media and volume keys, brightness, mouse buttons, scrolling, opening apps or URLs, typing text, shell commands and AppleScript.
- **Runs in the background**: a launchd agent starts OpenMouse at login with no window or Dock icon, so remapping works without the app open.

## Download

Get the latest DMG from [Releases](https://github.com/Davidkle/openmouse/releases/latest). It's a universal build (Apple Silicon and Intel), signed with a Developer ID and notarized by Apple, so it opens without Gatekeeper warnings. Open the DMG and drag OpenMouse into Applications.

## Build and run

You need Swift 5.9 or later. The Xcode Command Line Tools are enough; you don't need Xcode itself.

```sh
scripts/build-app.sh            # builds build/OpenMouse.app
scripts/build-app.sh --install  # also copies it to /Applications and launches it
scripts/test.sh                 # unit tests
```

The build script signs the app with the first "Apple Development" or "Developer ID" identity in your keychain. You can set `CODESIGN_IDENTITY` to choose one. If it finds no identity it signs ad-hoc. A stable signature matters because macOS ties the Accessibility permission to it: with ad-hoc signing you have to grant access again after every rebuild.

## Releases

Every push runs the tests and an unsigned build (`.github/workflows/build.yml`). A push to `main` also builds a universal app, signs it with the Developer ID certificate, notarizes and staples it, and publishes it as GitHub release `v0.1.<run number>`.

The release job needs these repository secrets:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Base64 of a `.p12` holding the "Developer ID Application" certificate and private key |
| `DEVELOPER_ID_CERT_PASSWORD` | Password for that `.p12` |
| `NOTARY_KEY_P8` | Base64 of an App Store Connect API key (`AuthKey_XXXX.p8`) |
| `NOTARY_KEY_ID` | That key's Key ID |
| `NOTARY_ISSUER_ID` | The Issuer ID shown on the same App Store Connect page |

To release locally, run `scripts/build-app.sh` followed by `scripts/package-release.sh`, with `NOTARY_KEY_FILE`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` set.

## First launch

1. **Quit Logi Options+**, including its background agent (`logioptionsplus_agent`). Both apps configure the mouse over HID++ and will undo each other's changes. Uninstalling Options+ is the most reliable fix.
2. Grant **Accessibility** access when prompted (System Settings → Privacy & Security → Accessibility). Without it, OpenMouse can't intercept buttons and scrolling.
3. Click a control on the mouse diagram and pick an action.

The first launch also turns on **Run in background** (Settings → General). macOS lists it under System Settings → General → Login Items & Extensions as an OpenMouse background item. From then on OpenMouse starts at login without a window, and launchd restarts it if it crashes. Opening OpenMouse shows the settings window of that same background process, and closing the window leaves it running. Choosing Quit stops remapping until you open OpenMouse again or log in.

## How it works

| Control | How it's captured |
|---|---|
| Middle, back, forward, main wheel | `CGEventTap`. These are ordinary macOS mouse events. Only events from Logitech devices are touched (you can change this in Settings), and trackpads never are. |
| Gesture button, Mode Shift, wheel tilt, haptic panel | HID++ `0x1B04` (reprogrammable controls) diversion. Gestures use raw XY reporting. |
| Thumb wheel | HID++ `0x2150` diversion, only when it's remapped or its speed is changed. Reversing it alone is done in firmware. |
| DPI / SmartShift | HID++ `0x2201` / `0x2110`, `0x2111` |

A control is only diverted when its binding differs from the default, so any button you haven't changed keeps its built-in behavior. When OpenMouse quits, it hands every control back to the firmware.

Settings are stored in `~/Library/Application Support/OpenMouse/config.json`.

## Project layout

```
Sources/OpenMouseCore   HID++ framing and payload parsing, the binding/action model, config, gesture detection (has unit tests)
Sources/OpenMouse
  Device/               IOHIDManager transport, receiver and device discovery, per-device HID++ features
  Input/                event tap, action executor, private system calls (Dock, symbolic hotkeys, event sender)
  App/                  app entry point, config store, remapping engine
  UI/                   SwiftUI views
```

For development, `OPENMOUSE_PAGE=scrolling .build/debug/OpenMouse` opens straight to a given page (`buttons`, `scrolling`, `pointer` or `settings`).
