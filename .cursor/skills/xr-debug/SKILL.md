---
name: xr-debug
description: >-
  Pull and interpret Loop Segments /xr Quest debug logs (xr_debug.json) when
  AR/VR playback, AV1 blit, HEVC after AV1, exit crashes, or SBS eye orientation
  misbehave. Use when the user reports headset /xr bugs or asks to read XR logs.
---

# `/xr` Quest debug pull

## When

Quest Browser `/xr` issues: blank HEVC after AV1, browser disappear on AR exit, Enter VR eye/SBS discomfort, frozen frames, wrong codec path.

## Pull live evidence

Phone + PC on same Wi‑Fi; Loop Segments LAN on `:8765`.

Both calls need the LAN login (`admin` / the password on the app's Export screen; GET since build 422, POST since 424). Don't print the password.

```powershell
curl.exe -s -u "admin:<password>" "http://<phone-ip>:8765/xr_debug.json" -o xr_debug_live.json
```

Or open `http://<phone-ip>:8765/xr_debug.json` in a browser. Optional file on phone: `pcld_ios_media/scripts/xr_debug.log`.

Clear ring (optional):

```powershell
curl.exe -s -u "admin:<password>" -X POST "http://<phone-ip>:8765/xr_debug.json" -H "Content-Type: application/json" -d "{\"action\":\"clear\"}"
```

An empty ring after a Quest session can mean the `/xr` debug POST was refused (401 without a login prompt): reload `/xr` so the browser logs in again.

## What to read

| Field / line | Meaning |
|--------------|---------|
| `enter-vr` / `exit-vr` | Session boundaries; `sawAv1` on exit |
| `codec` `av1:true/false` | Probe result (real `av01` box only) |
| `sawAv1Tex` | Session already used AV1 GPU blit → later clips use canvas |
| `loadIndex` | Clip change while presenting or not |
| `snapshot.mode` | `av1rt` / `canvasrt` / `native` / `gpu` / … |
| `snapshot.note` | Transport tex note (`post-AV1 canvas`, `AV1 full frame`, …) |
| `exit-vr settled` | Safe to touch materials again after teardown |
| `eye-layers` | Dome layer and visibility: VR left 1 / right 2, AR and flat 0 |
| `canvas-tex-reset` | Canvas texture released after a size change: `from`, `to`, `presenting` |
| `xr-enabled-fixed` | `xr.enabled` was false in a live session and was repaired. `ticks` = frames into the session; `n` above 1 = something keeps clearing it |

## Classify

| Symptom | Likely |
|---------|--------|
| HEVC blank in AR after AV1 | Missing canvas path / still on VideoTexture; check `sawAv1Tex` + `mode` |
| Browser dies on AR exit after AV1→HEVC | Exit must pause + avoid VideoTexture on flat; check `exit-vr begin` then silence |
| Enter VR background / both-eye discomfort | SBS / eye layers; expect `eye-layers` left 1, right 2 in VR |
| First VR after AR black, second fine | Expect `xr-enabled-fixed` at `ticks:1`. Still black with it = a new cause; `xr-probe` (build 407 to 416, git history) logged session, dome and blit state to compare sessions |
| Black preview or white dome on a plain clip after Chroma | `post-av1-canvas` size jump; expect `canvas-tex-reset` right after it |
| Wrong codec path | `codec av1:true` on an HEVC file → sniff false positive |

## Fix rules

- `/xr` lives in `ios/LoopSegments/Resources/`: `xr-player.html` (markup, CSS), `xr-components.js` (A-Frame components) and `xr-app.js` (page logic), plus the vendored `aframe.min.js` (A-Frame 1.6.0, served from the phone; do not edit it). Prefer narrow patches there. Swift only fills `{{XR_...}}` placeholders and serves `/xr-assets/*.js`.
- Check a change with `node --check` on the edited script before a build.
- A-Frame is locked at 1.6.0 (see `ios/README.md`, "A-Frame version"). An upgrade is not routine: it needs a full `/xr` headset retest, because `xr-enabled-fixed`, the eye layers and the canvas texture reset depend on how 1.6.0 behaves.
- Quest VR uses WebGL layers 1/2 (build 406+). Do not edit the XR cameras' layers.
- Do not set `visible` in `onBeforeRender`: three reads it before the hook, and a hidden mesh never runs the hook again.
- Do not dispose large RTs while `xr.isPresenting`.
- Ship IPA only if the user wants a build (`deploy.ps1 -NoWaitEnter`).
