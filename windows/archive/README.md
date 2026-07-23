# Archived Windows helpers

**Active phone mount:** **[`../rclone/Mount-LoopSegmentsRclone.ps1`](../rclone/Mount-LoopSegmentsRclone.ps1)** + **[`../rclone/RCLONE-PHONE-MOUNT.md`](../rclone/RCLONE-PHONE-MOUNT.md)**.

| File | Role |
|------|------|
| **`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`** | Forwarder to `../rclone/Mount-LoopSegmentsRclone.ps1` |
| **`RCLONE-PHONE-MOUNT-LEGACY.md`** | Old doc pointer — see **`../rclone/RCLONE-PHONE-MOUNT.md`** |
| **`Map-LoopSegmentsWebDAV.ps1`** | Legacy `net use` / port 80 proxy (Windows WebClient) |
| **`Sync-FromPhoneLAN.ps1`** | HTTP copy loop without rclone mount |
| **`Copy-ToLoopSegmentsPhoneLAN.ps1`** | HTTP PUT to `pcld_ios_media/` when **`L:`** is not mounted (prefer copy via mount) |
| **`LoopSegments-Config.ps1`** | Old config (superseded by `../lib/LoopSegments-Windows.ps1`) |

Quick LAN probe (no mount):

```powershell
cd ..
.\setup\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly
```

Port-proxy cleanup (admin): `..\rclone\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`

Upload without **L:** (from this folder): `.\Copy-ToLoopSegmentsPhoneLAN.ps1 ..\your.ps1`
