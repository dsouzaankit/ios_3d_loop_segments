# Workflow: iPhone cellular → PC DLNA (WLAN)

> **Feasibility:** Manual **Apple Devices → Save to PC** does **not** automate updating the DLNA folder while segments rotate. See **[FEASIBILITY.md](FEASIBILITY.md)** — production automation is either **PC `Run-SegmentCopy.ps1`** (pCloud → PC) or a **future Wi‑Fi pull** from the phone; USB copy is at best **once per export session**.

Three separate networks. **No Personal Hotspot** required for the iPhone path below.

```text
┌─────────────────────────────────────────────────────────────────┐
│  iPhone (cellular LTE/5G only — Wi‑Fi off is OK for export)      │
│    Loop Segments app → pCloud WebDAV (internet)                 │
│    Dense-fill each 60s from pCloud → Exports/op_00.mp4       │
│    Optional: each segment → Photos (MTP shows IMG_*.mp4 on PC)   │
└────────────────────────────┬────────────────────────────────────┘
                             │ USB (Exports and/or Photos)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Windows PC                                                     │
│    Sync-FromIPhonePhotos.ps1 -Watch → op_00/01 (DLNA pair)  │
│    DLNA media server → WLAN → TV / receiver / PotPlayer         │
└─────────────────────────────────────────────────────────────────┘
```

| Step | Where | Network |
|------|--------|---------|
| 1. Browse pCloud, run export | iPhone | **Cellular** (or Wi‑Fi if you prefer) |
| 2. Copy segment MP4s | USB | No IP network |
| 3. LAN playback | PC + TV | **WLAN** (Ethernet to router also fine) |

The PC never pulls from pCloud and never runs ffmpeg for this workflow. The phone never serves DLNA.

---

## 1. Build and install the iPhone app (one-time)

You need an **IPA** built in the cloud (no local Mac). See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md).

Install via **TestFlight** or sideload (AltStore, etc.) with an Apple Developer account.

---

## 2. On the iPhone (cellular)

1. **Settings → Cellular → Loop Segments** → allow cellular data.
2. Optional: turn **Wi‑Fi off** to force cellular-only pCloud access (no hotspot).
3. Open **Loop Segments** → sign in to pCloud (US/EU).
4. Browse to a video → set seek (presets 0/10/15/30/45 min) → **Start export**.
5. Keep the app in the foreground. On phone: **Files → Loop Segments → Exports** should show `op_00.mp4` updating each ~60s of **media** time (first segment can take several minutes on large moov-at-end HEVC while the minute **dense-downloads**).
6. **Photos (default on, build 93+):** each minute is **dense-filled** to sparse temp on the phone, passthrough-copied to `op_00.mp4`, then imported to the **Loop Segments** album. iOS does not write **DCIM**; Windows MTP often lists clips as `IMG_*.mp4` under monthly folders (`202605_a`, etc.). **Exports** still has full passthrough. Photos may fail with **3302** on some HEVC — see [ios/README.md](ios/README.md#photos-library-optional--not-required-for-dlna). Turning Photos off still uses dense fill but skips library import (no MTP path without Photos).

Large files on cellular: first segment waits for index + dense window (`Downloading window … (dense fill)` → `Window on disk` in `export_latest.txt`). Later minutes reuse the same sparse temp shell; export does not keep up with live TV wall clock on slow LTE — OK if the DLNA player **loops** the PC pair.

---

## 3. USB transfer to the PC (Apple Devices)

Apple Devices does **not** mount the iPhone app as a drive path. You **manually** choose a **Windows output folder** when saving from **Loop Segments → Exports** or import from **Photos** (if you used Photos export). There is no true auto-sync from Apple.

**Photos path:** Apple Devices → import photos/videos → look for recent items from the **Loop Segments** album, or browse Internal Storage photo folders. Still manual per save/import — rotating segments do not auto-update the PC DLNA folder.

**MTP script (no Apple Devices):** `windows\Sync-FromIPhonePhotos.ps1` scans **This PC → Apple iPhone → Internal Storage** (latest month folder + DCIM). Each run copies the **newest** phone video and overwrites the **older** of the PC DLNA files `op_00.mp4` / `op_01.mp4` (ring buffer; backward time jumps in a looping player are OK). Run `-Discover` first. **Watch:** `.\Sync-FromIPhonePhotos.ps1 -Watch` or `Sync-FromIPhonePhotos-Watch.cmd`. `-LegacyDualMap` restores the old “two newest → 00/01 by date” behavior. Assume only your export clips are newest in that folder.

### Simplest (one step)

When Apple Devices asks where to save, pick your **DLNA library folder** directly:

`F:\f1_media\3d_fullsbs_trans`

Save `op_00.mp4` and `op_01.mp4` there. Done — no extra script.

### Automation (what is and is not automated)

| Step | Automated? |
|------|------------|
| iPhone export (pCloud → segments) | **Yes** — in the app |
| Apple Devices → PC folder | **No** — you choose the Windows path and save (Apple limitation) |
| PC folder → DLNA library | **Yes** — watcher or scheduled copy (below) |

**One-time setup**

1. Create `Documents\LoopSegmentsIncoming` (or save straight to `F:\f1_media\3d_fullsbs_trans` and skip automation).
2. In Apple Devices, always save **Loop Segments → Exports** into that incoming folder (Windows remembers the path).

**Option 1 — Watcher (automated copy after each save)**

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Watch-LoopSegmentsIncoming.ps1 -RegisterLogonTask
```

At logon, a background task watches `LoopSegmentsIncoming` and runs `Copy-FromIncoming.ps1` when MP4s/logs change. You still **save manually** in Apple Devices; copy to DLNA is automatic.

Run the watcher in a window (no task):

```powershell
.\Watch-LoopSegmentsIncoming.ps1
```

**Option 2 — Scheduled copy every N minutes**

Task Scheduler → run `Copy-FromIncoming.ps1` on a schedule (picks up files after you saved to incoming).

**Option 0 — No automation**

Save directly to `F:\f1_media\3d_fullsbs_trans` in the Apple Devices dialog — one manual step total.

### Legacy: `Sync-IphoneSegments.ps1`

Only if Windows exposes a readable iPhone `Exports` path (uncommon with Apple Devices Save dialog only).

---

## 4. DLNA playback on WLAN

1. PC connected to the same **WLAN** as the TV/player (not via iPhone hotspot).
2. Windows **media streaming** (or your existing DLNA server) publishes `F:\f1_media\3d_fullsbs_trans`.
3. Open the library on the TV; play the rotating `op_*.mp4` entries.

---

## Finding **Loop Segments → Exports** on Windows

**`Internal Storage` with folders like `202605_a`, `202604_b`, …** = **Photos** (camera roll by month). That is normal. Your segment MP4s are **not** there.

| Where to look | What you should see |
|---------------|---------------------|
| **iPhone → Files → On My iPhone → Loop Segments → Exports** | `op_00.mp4`, `export_latest.txt`, `loop_segments_ok.txt` (always check here first) |
| **Apple Devices** → **Loop Segments** → **Exports** → **Save to PC** (you pick the Windows folder) | **Normal path** — not automatable by Apple; save to `F:\f1_media\...` or incoming + `Copy-FromIncoming.ps1` |
| **Explorer → This PC → Apple iPhone → Internal Storage** | Often **only** Photos (`202605_a`, …) — not the app |

If Explorer never shows **Loop Segments**:

1. Install/update **[Apple Devices](https://apps.microsoft.com/detail/9NP83LWLPZ9K)** (or iTunes for drivers).
2. Open the **Apple Devices** app → select iPhone → look for **Files** or apps list → **Loop Segments**.
3. On the phone, confirm exports exist in **Files** (step above).
4. Copy files manually: in **Files**, select `op_*.mp4` → **Share** → save to **iCloud Drive** / **OneDrive** / email to PC (workaround when USB app folders don’t mount).

`Sync-IphoneSegments.ps1` only works when Windows exposes  
`…\Loop Segments\Exports` (or you paste that path into `-SourceRoot`).

```powershell
.\Sync-IphoneSegments.ps1 -Discover
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Internal Storage only `202605_a` folders | Those are **Photos**, not the app. Use **Files → On My iPhone → Loop Segments → Exports** on the phone; try **Apple Devices** app on PC for File Sharing |
| PC can’t see iPhone | Unlock phone, replug USB, open **Apple Devices** app; if Exports vanished during export, **stop export**, unlock, then browse again. Copy path from Explorer → `-SourceRoot` |
| Network timed out on export | Strong cellular; keep app foreground; try Wi‑Fi; read `Exports/export_latest.txt` |
| Sync can’t find Exports | Use `-SourceRoot` from Explorer address bar |
| DLNA empty | Confirm `op_00.mp4` and `op_01.mp4` in `F:\f1_media\3d_fullsbs_trans` |
| pCloud fails on phone | Approve WebDAV 2FA email; check cellular permission for app |
| Export fails on phone | `.\Sync-IphoneSegments.ps1` also copies logs → `%USERPROFILE%\Documents\LoopSegmentsLogs\export_latest.txt` (Windows USB often hides logs on the phone) |

---

## Not used in this workflow

- iPhone **Personal Hotspot** (PC does not share phone internet)
- **PC-side ffmpeg** / `Run-SegmentCopy.ps1` (legacy pipeline in `3d_loop_segments` repo)
- PotPlayer **RememberFiles** registry resume
- PC Wi‑Fi **idle stop** while ffmpeg runs on PC (not applicable when export is on the phone)
