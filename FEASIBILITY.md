# Feasibility: getting segments to the PC

## The blocker

**Apple Devices only offers a manual “Save to PC” dialog.** It does not mount Loop Segments as a drive path scripts can read, and it does not auto-sync.

For a **rolling 2×60s buffer** meant to feed **PC DLNA**, you need the PC folder updated **without hand-copying every minute**. Manual Apple Devices transfer does **not** meet that bar.

## What the iPhone app does automate

| Step | Status |
|------|--------|
| pCloud browse + seek + export on **cellular** | Done (AVFoundation) |
| Two files `op_00.mp4` / `op_01.mp4` on the phone | Done (overwrite every ~60s) |
| **PC DLNA folder updated automatically** | **Not solved** with USB + Apple Devices alone |
| Copy segments to **Photos** (v1.2, “Loop Segments” album) | Done — optional; may fail for some **HEVC** (Photos API **3302**); **Exports/USB** is the reliable full-quality path |

## Viable production paths

### A. **PC pulls from pCloud** (fully automated on Windows)

Use the existing sibling pipeline:

`P:\all_scripts\3d_loop_segments\Run-SegmentCopy.ps1`

- PC ffmpeg reads pCloud (WebDAV), writes segments straight into `F:\f1_media\3d_fullsbs_trans`
- No iPhone, no USB, no Apple Devices
- Idle-stop / Wi‑Fi heuristics already exist there

**Best fit if the goal is unattended DLNA on the PC.**

This repo’s iPhone app is optional (e.g. export when the PC is off).

### B. **iPhone export + PC pulls over Wi‑Fi** (built)

While export runs, the app serves `Exports/` on the **LAN** (`http://<phone-ip>:8765/`); **`windows\Sync-FromPhoneLAN.ps1 -Watch`** copies into the DLNA folder every ~60s.

- Same phone cellular export you wanted; **Wi‑Fi/LAN** only for phone ↔ PC
- No USB, no Apple Devices, no Photos required
- Toggle **Serve Exports on Wi‑Fi** in Export; allow **Local Network** when iOS prompts

### C. **iPhone export + one manual copy per session** (marginal)

If you only need files on the PC **after** export finishes (not live during export):

- Only **two files** ever exist on the phone (they rotate in place)
- One Apple Devices save per evening may be acceptable
- **Not** viable for “DLNA always shows current 60s window while export runs”

## Recommendation

| Your goal | Use |
|-----------|-----|
| Automated DLNA buffer on PC (no phone) | **A — `Run-SegmentCopy.ps1` on PC** |
| Phone export + PC on LAN | **B — `Sync-FromPhoneLAN.ps1 -Watch`** |
| Cellular for pCloud + PC on same LAN | **B — `Sync-FromPhoneLAN.ps1 -Watch`** |
| Current repo as-is (USB + Apple Devices) | **Not feasible** for live rotating segments |

## De-scope note

Earlier docs said “no PC ffmpeg” to separate the **iPhone greenfield app** from the **legacy PC script**. That is a **project boundary**, not a claim that USB + manual copy is a complete system.

For an end-to-end **feasible** system, either **re-include A** as the production path or **implement B** in this repo.
