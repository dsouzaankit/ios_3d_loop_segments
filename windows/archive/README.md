# Archived Windows scripts

Superseded by **[`../Mount-LoopSegmentsRclone.ps1`](../Mount-LoopSegmentsRclone.ps1)** (rclone + WinFsp maps the full phone `Exports/` folder).

| Script | Was used for |
|--------|----------------|
| `Map-LoopSegmentsWebDAV.ps1` | `net use` WebDAV drive (often error 67 on port 8765) |
| `Sync-FromPhoneLAN.ps1` | Poll/copy `loop/op_00.mp4` into a local PC DLNA pair |
| `Sync-FromPhoneLAN-Watch.cmd` | Wrapper for `-Watch` |
| `Set-LoopSegmentsDestination.ps1` | Saved DLNA folder path for sync |
| `LoopSegments-Config.ps1` | Shared paths for sync scripts |
| `loop-segments-destination.txt` | Saved destination (example) |

Undo port-80 WebDAV proxy (preferred on active scripts):

```powershell
cd ..
.\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy   # admin PowerShell
```

Or from archive: `.\Map-LoopSegmentsWebDAV.ps1 -Remove`

Run from this folder if you still need a local copy workflow:

```powershell
cd P:\all_scripts\ios_3d_loop_segments\windows\archive
.\Set-LoopSegmentsDestination.ps1 'D:\media\3d_fullsbs_trans'
..\Set-LoopSegmentsLANHost.ps1 192.168.1.42
.\Sync-FromPhoneLAN.ps1 -Watch
```

Active scripts live in **`../`** (`Mount-LoopSegmentsRclone.ps1`, `Set-LoopSegmentsLANHost.ps1`).
