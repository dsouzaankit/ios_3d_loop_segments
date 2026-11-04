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

```powershell
curl.exe -s "http://<phone-ip>:8765/xr_debug.json" -o xr_debug_live.json
```

Or open `http://<phone-ip>:8765/xr_debug.json` in a browser. Optional file on phone: `pcld_ios_media/scripts/xr_debug.log`.

Clear ring (optional):

```powershell
curl.exe -s -X POST "http://<phone-ip>:8765/xr_debug.json" -H "Content-Type: application/json" -d "{\"action\":\"clear\"}"
```

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

## Classify

| Symptom | Likely |
|---------|--------|
| HEVC blank in AR after AV1 | Missing canvas path / still on VideoTexture; check `sawAv1Tex` + `mode` |
| Browser dies on AR exit after AV1→HEVC | Exit must pause + avoid VideoTexture on flat; check `exit-vr begin` then silence |
| Enter VR background / both-eye discomfort | SBS / eye cull; expect Quest VR `onBeforeRender` split, not layers 1/2 |
| Wrong codec path | `codec av1:true` on an HEVC file → sniff false positive |

## Fix rules

- Prefer narrow patches in `ExportLANServer.swift` `/xr` JS (Swift raw string: interpolate with `\#(` not `\(`).
- Do not reintroduce WebGL layers 1/2 on Quest.
- Do not dispose large RTs while `xr.isPresenting`.
- Ship IPA only if the user wants a build (`deploy.ps1 -NoWaitEnter`).
