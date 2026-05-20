# Archived Windows scripts

Active LAN checks: **[`../Mount-LoopSegmentsRclone.ps1`](../Mount-LoopSegmentsRclone.ps1)** (**`-TestOnly`** = HTTP reachability to the phone; **`-RemovePort80Proxy`** = undo legacy port proxy).

**rclone WebDAV drive mapping of the phone is retired** — see **[RCLONE-PHONE-MOUNT-LEGACY.md](RCLONE-PHONE-MOUNT-LEGACY.md)** and the frozen script **[`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`](Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1)** (WinFsp + `rclone mount` against old WebDAV-on-phone builds).

| Script / doc | Role |
|----------------|------|
| **`RCLONE-PHONE-MOUNT-LEGACY.md`** | Why rclone+phone mount was removed; what to use instead |
| **`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`** | Old full mount + `rclone.conf` patch (reference) |
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

Other active scripts live in **`../`**: `Set-LoopSegmentsLANHost.ps1`, `Set-LoopSegmentsWindows.ps1`, `LoopSegments-Windows.ps1`.
