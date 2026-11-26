# WayLink

Stream a full Android (Waydroid) instance from a Linux host to your iPhone:
hardware-decoded H.264, real multitouch, game audio — over Wi-Fi and cellular.
Two modes: **Regular** (pinch-zoom, keyboard, nav bar) and **Gaming**
(landscape-locked fullscreen, gamepad overlay with touch-mapper and real UHID
gamepad support).

This repo is the iOS app. The Linux-side stack (Waydroid + scrcpy-protocol
WebSocket bridge) lives in the companion `waydroid-stream` bundle.

## Build the IPA (GitHub Actions)

Every push to `main` (or manual **Run workflow**) builds on a macOS runner and
uploads `WayLink.ipa` as an artifact:

1. **Actions → build-ipa → Run workflow** (or just push).
2. Download the artifact: `WayLink-unsigned.ipa`.
3. Install: re-sign with AltStore / Sideloadly / Scarlet, or your own cert.

### Signed builds (direct install)

Add repo secrets and the workflow signs the IPA with your distribution cert:

| Secret | Value |
|---|---|
| `P12_BASE64` | base64 of your distribution .p12 |
| `P12_PASSWORD` | p12 password |
| `PROVISIONING_BASE64` | base64 of the .mobileprovision (App ID `com.d3m0n.waylink`) |
| `TEAM_ID` | your Apple Developer Team ID |
| `PROFILE_NAME` | provisioning profile name |

## Build locally (Xcode)

Open `WayLink.xcodeproj`, pick your signing team, run on device. (No Mac?
That's why the Actions workflow exists.)

## In the app

- **Host/Port/Token** from the bridge (`~/.config/waylink/bridge.env` on the
  Linux box), **Test connection**, **Connect**.
- Gaming mode: menu → “Map gamepad buttons…” to map each virtual button to a
  position on the game's on-screen controls (per-game profiles persist).
- Quality: Smooth 960p30 (cellular) → Balanced 1280p60 → HD 1080p60 → Ultra;
  adaptive stepping is on by default.
