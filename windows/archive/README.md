# Archived Windows helpers

**Active phone mount:** **[`../Mount-LoopSegmentsRclone.ps1`](../Mount-LoopSegmentsRclone.ps1)** + **[`../RCLONE-PHONE-MOUNT.md`](../RCLONE-PHONE-MOUNT.md)**.

| File | Role |
|------|------|
| **`Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1`** | Forwarder to `../Mount-LoopSegmentsRclone.ps1` |
| **`RCLONE-PHONE-MOUNT-LEGACY.md`** | Old doc pointer — see **`../RCLONE-PHONE-MOUNT.md`** |
| **`Map-LoopSegmentsWebDAV.ps1`** | Legacy `net use` / port 80 proxy (Windows WebClient) |
| **`Sync-FromPhoneLAN.ps1`** | HTTP copy loop without rclone mount |
| **`Copy-ToLoopSegmentsPhoneLAN.ps1`** | HTTP PUT to `pcld_ios_media/` when **`L:`** is not mounted (prefer copy via mount) |
| **`LoopSegments-Config.ps1`** | Old config (superseded by `../LoopSegments-Windows.ps1`) |

Quick LAN probe (no mount):

```powershell
cd ..
.\Set-LoopSegmentsLANHost.ps1 10.0.100.10
.\Mount-LoopSegmentsRclone.ps1 -TestOnly
```

Port-proxy cleanup (admin): `..\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`

Upload without **L:** (from this folder): `.\Copy-ToLoopSegmentsPhoneLAN.ps1 ..\your.ps1`
