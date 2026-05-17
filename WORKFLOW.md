# Workflow: iPhone cellular → USB → PC DLNA (WLAN)

Three separate networks. **No Personal Hotspot** required.

```text
┌─────────────────────────────────────────────────────────────────┐
│  iPhone (cellular LTE/5G only — Wi‑Fi off is OK for export)      │
│    Loop Segments app → pCloud WebDAV (internet)                 │
│    FFmpeg writes Documents/Exports/3d_op_00.mkv, 3d_op_01.mkv │
└────────────────────────────┬────────────────────────────────────┘
                             │ USB cable (file transfer only)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Windows PC                                                     │
│    Sync-IphoneSegments.ps1 → F:\f1_media\3d_fullsbs_trans       │
│    DLNA media server → WLAN → TV / receiver / PotPlayer         │
└─────────────────────────────────────────────────────────────────┘
```

| Step | Where | Network |
|------|--------|---------|
| 1. Browse pCloud, run export | iPhone | **Cellular** (or Wi‑Fi if you prefer) |
| 2. Copy segment MKVs | USB | No IP network |
| 3. LAN playback | PC + TV | **WLAN** (Ethernet to router also fine) |

The PC never pulls from pCloud for this workflow. The phone never serves DLNA.

---

## 1. Build and install the iPhone app (one-time)

You need an **IPA** built in the cloud (no local Mac). See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md).

Install via **TestFlight** or sideload (AltStore, etc.) with an Apple Developer account.

SPM package **ffmpeg-kit-spm** is declared in [ios/project.yml](ios/project.yml); cloud build runs `xcodegen generate` first.

---

## 2. On the iPhone (cellular)

1. **Settings → Cellular → Loop Segments** → allow cellular data.
2. Optional: turn **Wi‑Fi off** to force cellular-only pCloud access (no hotspot).
3. Open **Loop Segments** → sign in to pCloud (US/EU).
4. Browse to a video → set seek (presets 0/10/15/30/45 min) → **Start export**.
5. Keep the app in the foreground until both `3d_op_00.mkv` and `3d_op_01.mkv` exist (Files → Loop Segments → Exports).

Large files on cellular: expect long runs; `-re` reads at real-time speed.

---

## 3. USB transfer to the PC

1. Connect iPhone with USB; unlock; tap **Trust** on the phone.
2. On Windows, open **Apple Devices** / Explorer → iPhone → **Loop Segments** → **Exports**.
3. Run sync (copies into DLNA library folder):

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows
.\Sync-IphoneSegments.ps1
```

If auto-discovery fails, paste the Exports path:

```powershell
.\Sync-IphoneSegments.ps1 -SourceRoot 'D:\Apple iPhone\Internal Storage\Loop Segments\Exports'
```

**Wait for device** (polls until both MKVs are visible):

```powershell
.\Sync-IphoneSegments.ps1 -WaitForDevice -WaitMinutes 30
```

Optional: register a logon task that runs sync when you sign in (after plugging in the phone):

```powershell
.\Register-UsbSyncTask.ps1
```

---

## 4. DLNA playback on WLAN

1. PC connected to the same **WLAN** as the TV/player (not via iPhone hotspot).
2. Windows **media streaming** (or your existing DLNA server) publishes `F:\f1_media\3d_fullsbs_trans`.
3. Open the library on the TV; play the rotating `3d_op_*.mkv` entries.

For **idle stop** of a *PC-side* ffmpeg job (Wi‑Fi upload heuristic), use [Run-SegmentCopy.ps1](../3d_loop_segments/Run-SegmentCopy.ps1) on Windows — that is separate from the iPhone export path.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| PC can’t see iPhone | Trust PC, unlock phone, install Apple Devices / iTunes drivers |
| Sync can’t find Exports | Use `-SourceRoot` from Explorer address bar |
| DLNA empty | Confirm `3d_op_00.mkv` and `3d_op_01.mkv` in `F:\f1_media\3d_fullsbs_trans` |
| pCloud fails on phone | Approve WebDAV 2FA email; check cellular permission for app |
| Export fails immediately | Check ffmpeg-kit build logs; segment muxer needs full FFmpeg-Kit variant if min build lacks it |

---

## Not used in this workflow

- iPhone **Personal Hotspot** (PC does not share phone internet)
- PotPlayer **RememberFiles** registry resume
