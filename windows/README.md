# Loop Segments — Windows (portable)

Scripts work on **any Windows PC** after you copy or clone this repo (`git clone --recurse-submodules` so **`env_setup`** and **`Skybox_vr_pc`** are present). Machine-specific paths live in **`loop-segments-windows.json`** (gitignored) in this folder. Shared helpers live in **`lib\`**; entry-point scripts are grouped by role under subfolders.

**IPA → iCloud:** from the **repo root** (parent of this folder), run **`..\deploy.ps1`** (build/fetch, then calls **`copy-to-icloud.ps1`**) or **`..\copy-to-icloud.ps1`** alone (stamped `LoopSegments-b{build}-{time}.ipa`, like web_auto_parking). See [../ios/BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md).

**PowerShell:** use **PowerShell 7** (`pwsh`) — install: https://aka.ms/powershell. Open a **pwsh** prompt (not the blue Windows PowerShell 5.1 console) before running `.ps1` files. If you do start one under 5.1, a helper **re-runs that same script under `pwsh`** and exits 5.1 with the child’s code. Prefer a 7 prompt; the bounce is a fallback (path spaces like `iOS apps` used to break it). `.cmd` launchers already call `pwsh`.

Companion: `pcloud_web_companion\Run-PCloudWebCompanion.ps1`. Mount: `rclone\Mount-LoopSegmentsRclone.ps1` (or `Mount-PhoneL.cmd`). Quest DLNA: `rclone\Serve-LoopSegmentsRcloneDlna.ps1` (or `Serve-PhoneDlna.cmd`).

## Layout

| Folder | Role |
|--------|------|
| *(this folder)* | `README.md`, `loop-segments-windows.json` (+ example) |
| `lib/` | Shared helpers: `LoopSegments-Windows.ps1`, Python picker, AltServer wrappers (`env_setup` submodule), Skybox wrappers (`Skybox_vr_pc` submodule) |
| `setup/` | New-PC bootstrap + edit per-PC json / LAN IP |
| `usb/` | Force-open / Home over USB (`pymobiledevice3`) |
| `sideload/` | AltServer logon task; Sideloadly fallback |
| `lan/` | Multi-phone unified listing / PC index on `:8766`; gateway Wi‑Fi reboot (wrong-subnet / other-router / off-subnet); LAN throughput |
| `rclone/` | Optional WinFsp `L:` mount + `rclone serve dlna` for Quest |
| `quest/` | Quest Browser over adb: **Open on Quest** (signed-in normal tab), insecure-origin flag checked through `isSecureContext` in the opened tab, keep the headset awake during the session, the **Quest control page** on this PC's LAN address (SKYBOX WebDAV server Push / Update / Clear, PC ↔ phone LAN bandwidth test, **Session Control** for Space / End session on 3d_playlist_local and the PC companion, opened on the Quest with Open on Quest), deletion of the Loop Segments history entries on companion close. Setup: [quest/README.md](quest/README.md) |
| `pcloud_web_companion/` | **PC companion** (Chromium MV3 + Quest/rclone session hooks) + `Run-PCloudWebCompanion.ps1` |
| `archive/` | Legacy `net use` / sync scripts |

## Typical `.ps1` run sequence (`windows\`)

```powershell
cd <repo>\windows

# 1) Once per PC (Python 3.12, pymobiledevice3, companion venv/Chromium, portable json,
#    PC-signed USB install: zsign + SideStore .p12 + its password, via setup\Set-LoopSegmentsSigning.ps1)
#    Any iPhone: with it on USB (unlocked, on Wi-Fi) setup reads and saves its LAN IP; or pass -PhoneHost <phone-ip>
.\setup\Setup-LoopSegmentsWindows.ps1

# 2) Once (optional, AltStore only): AltServer at logon — ~7-day sideload refresh
.\sideload\Register-AltServerAtLogon.ps1
# SideStore: do not register. If it (or UsbWatch) was already registered, unregister:
#   .\sideload\Register-AltServerAtLogon.ps1 -Unregister
#   pwsh -File ..\env_setup\altserver_refresh\usb\Register-IphoneUsbAltServer.ps1 -Unregister
#   (UsbWatch -Unregister also stops leftover Watch wscript/pwsh; old unregister left orphans that still started AltServer on USB plug-in.)
# Why: SideStore refreshes on Wi‑Fi with LocalDevVPN; no AltServer / USB watch.

# 3) Day-to-day: pCloud companion (gateway check → LAN status; USB-foregrounds app unless -SkipUsbLaunch)
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
#    Quit: close Chromium, Ctrl+C, or console X - kills Chromium, unmaps Skybox
#    AirScreen shares, quits SKYBOX if this session started it, stops rclone mount+DLNA, syncs profile,
#    then USB Home only if the app is still foreground (Keep Alive default on — see ../ios/README.md; -SkipGoHome to never press)

# Optional helpers
.\setup\Set-LoopSegmentsWindows.ps1 -Show          # show/edit per-PC json
.\setup\Set-LoopSegmentsLANHost.ps1               # USB (phone network monitor) → phoneLanHost (or pass <phone-ip>)
.\lan\Discover-LoopSegmentsLanHost.ps1            # same USB read; -Force re-reads even if :8765 up
.\usb\Launch-LoopSegmentsViaUsb.ps1 -SkipMount    # open app over USB only
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly   # probe phone LAN / WebDAV
.\rclone\Mount-LoopSegmentsRclone.ps1             # mount L: (optional; WinFsp)
.\rclone\Serve-LoopSegmentsRcloneDlna.ps1         # Quest DLNA over phone WebDAV
.\lan\Start-LoopSegmentsCloudflareTunnel.ps1      # quick tunnel → phoneLanHost:8765 (deprecated: prefer the Quest flag; public URL, close when done)
```

If Loop Segments won’t open after ~7 days: **SideStore** (LocalDevVPN → Refresh; optional daily/weekly **Shortcuts → Refresh All Apps** Automation — caveats in [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md#sidestore-shortcuts-auto-refresh-optional)) or start **AltServer** → USB + unlock → AltStore **Refresh All** (works even when phone and PC are on different gateways) → **Settings → General → VPN & Device Management → DEVELOPER APP → iPhone Developer: \<email\> → Trust** (entry may appear only after a failed open) → open app once → retry.

**SideStore refresh: “Device Reachability (Ping): Unreachable” / “Pairing file not found”:** reinstall SideStore with **iloader** over USB (nightly hit *Pairing file not found* here; **stable** fixed it), then re-add Loop Segments / Parking via **My Apps → +** (same Apple ID keeps app data). LocalDevVPN IP stopgap if ping still fails. Steps: [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md#reinstall-or-update-sidestore-with-iloader).

**AltStore / SideStore “data isn’t in the correct format”:** often the IPA is still syncing in iCloud (partial file). Wait for iCloud to finish, then **retry My Apps → + several times**. **SideStore stable** hit the same error here; **SideStore nightly** worked. If it persists after a fully local file on AltStore, see [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) (iTunes authorize / anisette). SideStore: change anisette / re-pair with iloader.

**SideStore install hangs on update:** installing a new `LoopSegments*.ipa` **over** the existing app often never finishes. **Force-quit Loop Segments** first, then retry **My Apps → +**. If it still hangs, **delete** the app and install again (LocalDevVPN on; IPA fully synced; delete wipes on-device data) — see [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md).

**AltStore “could not determine this device's UDID” (error 1006):** AltStore was not installed (or was corrupted) by AltServer — UDID is embedded only when AltServer installs AltStore. Update AltServer → USB + unlock → tray **Install AltStore** (not Sideloadly / random IPA) → Trust developer if prompted → open AltStore → **Refresh All**. If Loop Segments then says **“not available”** (or is missing from My Apps): no new build required — **My Apps → +** → same `LoopSegments.ipa` (or delete the home-screen icon and install again). Details: [../ios/BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md).

## First time on a PC

```powershell
cd <repo>\windows   # e.g. where this README lives

# One shot: Python 3.12 + pymobiledevice3 + companion venv/Chromium + portable json
# + PC-signed USB install (zsign, SideStore .p12, password prompt; -SkipSigning to skip)
# + phoneLanHost from whichever iPhone is on USB (no built-in IP; -PhoneHost <phone-ip> to set it yourself)
.\setup\Setup-LoopSegmentsWindows.ps1

# PC-signed USB install only (re-check, new .p12 export, or a new PC's password)
.\setup\Set-LoopSegmentsSigning.ps1 [-P12 <SideStore export .p12>]

.\setup\Set-LoopSegmentsWindows.ps1 -Show
.\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly
.\rclone\Mount-LoopSegmentsRclone.ps1          # rclone mount -> drive letter (WinFsp)
```

Or step by step: copy `loop-segments-windows.example.json` → `loop-segments-windows.json`, then `.\setup\Set-LoopSegmentsWindows.ps1`.

**`phoneLanHostSource` (super-config, before companion):** `"config"` (default) = force saved `phoneLanHost` (PC may be aligned to that subnet); `"usb"` = keep the phone’s **current** Wi‑Fi IPv4 read over USB (its network monitor: its own address on `en0`; then its Wi‑Fi hardware address looked up in this PC's ARP table after one ping sweep of its own /24s (exact when they share a network); pcapd sniffing as the last fallback) for `lan_config` + gateway/recover — **does not overwrite** saved `phoneLanHost`. Set with `.\setup\Set-LoopSegmentsPhoneLanHostSource.ps1` (bare run / double-click **toggles**; or `-Usb` / `-Config` / `-Show`) or edit json. **`phoneLanHost`** itself is the saved IP (`.\setup\Set-LoopSegmentsLANHost.ps1` / discover). **No TCP subnet scan**. Phone + PC same subnet: `lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`.

Phone LAN is **HTTP + WebDAV** on `:8765` (Basic auth **`admin`** / the app's password (Export screen) — same as Skybox). Writable paths support **PUT** (≤ 2 MB), **MKCOL**, **DELETE**, and **MOVE** (build **282+**; Explorer rename stays on-phone). No server **COPY** yet. **rclone mount** (`L:`) is optional for Explorer; companion exposes phone WebDAV to Quest via **`rclone serve dlna`** — see **[rclone/RCLONE-PHONE-MOUNT.md](rclone/RCLONE-PHONE-MOUNT.md)**. **AirScreen of `L:` never played in Skybox VR** (do not map it). If **rclone DLNA stutters**, prefer **[3d_playlist_local](https://github.com/dsouzaankit/3d_playlist_local)** → play from the **`3d_fullsbs_trans`** AirScreen share (`Skybox_vr_pc`), or Quest WebDAV straight to the phone.

## App LAN vs primary router

The **app LAN gateway** (the AP whose subnet is `phoneLanHost` / AltServer — e.g. `10.0.100.0/24`) is **tethered to a primary router** (upstream WAN / another SSID, e.g. `192.168.2.x`). Phone and PC should associate to the **app LAN** AP, not the primary.

Because that gateway is tethered, its **Wi‑Fi channel must match the primary router’s Wi‑Fi channel**. After changing the primary’s channel, set the same channel on the app LAN gateway (or reboot its Wi‑Fi so it re-locks).

Low Mbps on the **right** subnet is **suspected to be Wi‑Fi channel congestion from neighboring routers** (other APs on or near that channel). Recovery (`Measure-LoopSegmentsLanThroughput.ps1` / companion) therefore **reboots other known routers** (including the primary) and **leaves the current app-LAN gateway up**, so Chromium/pCloud stay connected. It then waits ~20s and re-measures, up to **2** retries, until Mbps ≥ `minLanThroughputMbps` (default **40**).

## pCloud web helper (integrated)

Chromium + MV3 extension lives in **`windows\pcloud_web_companion\`**. On start it syncs `lan_config.json` from `loop-segments-windows.json`, and if `phoneLanHost` is empty or `:8765` is down it **overrides** that host with the address read over USB (see above). Before Chromium starts it checks whether the PC default gateway shares a subnet with `phoneLanHost` (app LAN page); if not, it first **switches this PC's Wi‑Fi to a saved network on that subnet** (`netsh`, about 5 s, no router reboot; also correct under Clash's TUN, which owns the default route). Only when no saved network reaches it does it **reboot Wi‑Fi on the current gateway**, **wait for this PC to get a new LAN IP**, and **retry up to 3 rounds** until the gateway is on the app LAN subnet (via `P:\all_scripts\5g_router_reboot`), then **starts Chromium** so you can browse pCloud while SKYBOX / USB-launch / phone-LAN recover / rclone continue. If `:8765` is down, the extension **queues** downloads (desktop notification) and retries; after ~5 minutes it **denies** them. **Click a toast** to bring the companion PowerShell window to the front. After Chromium is up it **starts SKYBOX VR desktop** via the **`Skybox_vr_pc`** submodule (hide to tray; **does not keep re-hiding** after a tray restore), maps AirScreen **`p_cld_media`**, then **starts Virtual Desktop Streamer** if idle and **hides it to the tray** (`-SkipSkybox` / `-SkipVirtualDesktop` to skip). USB-launches Loop Segments only when needed: **skips** if the LAN page is up **and** the phone is signed in to pCloud; otherwise **foregrounds briefly**, waits until `:8765` responds (skipped when the phone's Wi-Fi address, read over USB, is off the phone LAN's /24: it cannot answer there, so LAN recover runs right away and moves it back), then **Homes** the app again (locked phone no longer blocks Chromium; DVT **`--no-kill-existing`**), **attempts an rclone mount** in a separate window (then maps phone **`pcld_ios_media`** in Skybox Add-folders), then **probes LAN Mbps** (HTTP + mount when the letter is up, **HTTP-only** if it is not). If that is below `minLanThroughputMbps` (default **40**), it **reboots other routers** (not this PC’s app-LAN gateway), waits, and re-checks — up to **2** retries. The app LAN gateway is tethered to a primary router; those two APs must use the **same Wi‑Fi channel**.

**Multi-select tip:** in my.pcloud.com, click the **`v`** control to filter the folder by one of **five** types (including **Video**), then multi-select → Download — the companion cancels the zip and queues videos on the phone FIFO. **Folder right-click → Download is not supported** (zip cancelled, no `fileid`s → “no selection ids”); open the folder, select the videos, then Download instead. **Open this folder in pCloud Drive** (Shift+right-click for the Chrome menu — my.pcloud.com blocks a normal right-click — toolbar popup, or **Ctrl+E**) resolves the tree/`folder=` URL and opens the matching path in Explorer in the foreground; the drive letter comes from pCloud `SyncDrive` / the **pCloud Drive** volume, not a hardcoded `P:`. The companion pins the extension on the Chromium toolbar each launch. **CDN view tabs stay open** (Open Original / inline play); the downloads shelf is still cancelled. **Same full href** is not posted again this Chromium session. Details: [`pcloud_web_companion\README.md`](pcloud_web_companion/README.md).

```powershell
.\pcloud_web_companion\Run-PCloudWebCompanion.ps1
# gateway vs phoneLanHost subnet check (saved-Wi-Fi switch, else reboot current gateway Wi-Fi),
# then starts Chromium; SKYBOX / USB-launch / LAN recover / rclone continue in this window
# (plugin queues downloads if :8765 is down, then denies after ~5 min).
# SKYBOX VR desktop is started after Chromium if installed but idle, then hidden to the tray (-SkipSkybox to skip).
# Virtual Desktop Streamer is started if idle (service started if stopped) and hidden to the tray (-SkipVirtualDesktop to skip).
# Quit also closes Skybox when this companion session started it (already-running Skybox is left).
# locked phone no longer blocks Chromium. Low throughput reboots other APs (not this PC's gateway) and re-checks (up to 2 retries).
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipGatewayReboot  # skip Wi-Fi reboot check
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipUsbLaunch   # Chromium only (still tries rclone if LAN up)
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -EnsureAltServer # AltStore path: start AltServer if idle (default skips)
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipRcloneMount # no drive-letter mount window
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -EnableRcloneDlna # also start rclone serve dlna for Quest Skybox (off by default: no password)
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipLanThroughput # no media copy Mbps probe
# .\pcloud_web_companion\Run-PCloudWebCompanion.ps1 -SkipLowThroughputGatewayReboot # keep going even if below minLanThroughputMbps
# Profile: full sync to P:; local AppData cleared after companion finishes (gitignored)
# Quit: close Chromium, or Ctrl+C / console X — quits Skybox if we started it, syncs profile, then USB Home only if the app is still foreground
# On finish: USB Home backgrounds the app when it is still frontmost (needs Keep Alive for export — see ios README).
#   Already backgrounded / locked / no USB → Home skipped. -SkipGoHome never presses Home
```

**Machine-local** (not synced via pCloud): companion venv, Playwright Chromium, and the unpacked extension under `%LOCALAPPDATA%\pcloud_web_companion\`. The repo `.venv` is removed if present — do not recreate it on `P:`.

Details: [`pcloud_web_companion\README.md`](pcloud_web_companion/README.md).

## PC-signed USB install (zsign, no Install tap)

`deploy.ps1`'s USB install (`usb\Install-LoopSegmentsIpaViaUsb.ps1`) first tries to **sign the IPA on this PC with SideStore's own certificate** and install it over USB (`usb\LoopSegments-UsbSign.py`). That takes about 5 s, with **no Install tap, no Wi‑Fi moves and no LocalDevVPN**. The deploy's phone prep (`usb\Prepare-PhoneForSideStoreViaUsb.ps1`) runs the signing check first and leaves LocalDevVPN alone when it is `READY`. Only a fallback to SideStore connects it, and then it is switched off again after the install. LocalDevVPN is still needed for **SideStore refreshes**, which renew the 7-day profile. If it isn't set up or fails, it goes on to the SideStore link flow ([BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md)). `-NoSignedInstall` skips it.

**How it works:** it reads the installed bundle ID from the phone (SideStore adds `.TEAMID`, e.g. `com.loopsegments.app.<TEAMID>`) and keeps it. It then picks the **newest unexpired profile on the phone** (misagent over USB) that is for that app ID, lists the .p12's certificate and lists this phone. It signs with `zsign -k signing.p12 -m <profile> -b <bundle id>` (entitlements come from the profile) and installs with installation_proxy. The new build is confirmed the same way as the SideStore path. Same certificate and bundle ID as SideStore, so app data is kept and no new App ID is used.

**SideStore markers:** before signing, it adds the Info.plist keys SideStore adds when it signs an app: the URL scheme `sidestore-<bundle id>`, the exported type `io.sidestore.Installed.<bundle id>` (`UTExportedTypeDeclarations`), `ALTBundleIdentifier` (the original ID), `ALTAppGroups` and `ALTPairingFile`. SideStore uses the URL scheme and the exported type to tell whether its apps are still installed. Without them, SideStore treats the app as deleted and **drops it from My Apps**, which the first PC-signed builds did. If Loop Segments is missing from My Apps, add it back once with **My Apps → +** and the IPA (data is kept). Later PC installs keep it listed.

**Stuck installer:** the phone's installer once stopped answering USB installs: the upload finished but the install never did, until the phone was restarted. The helper now gives up after 120 s (`INSTALL_FAILED … restart the phone`) and the deploy falls back to SideStore. Fix: restart the phone (`<python> -m pymobiledevice3 diagnostics restart`, with the Python that Setup set up, e.g. `py -3.12`), unlock it, then run `.\reinstall-latest.ps1`.

**Setup (any Windows PC):** `.\setup\Set-LoopSegmentsSigning.ps1` does steps 2-5 and skips what is already done. `Setup-LoopSegmentsWindows.ps1` runs it too (`-SkipSigning` to skip). What lives where:

| What | Where | Per PC? |
|---|---|---|
| Certificate | `windows\signing\signing.p12` (gitignored) | No: syncs with the repo folder (e.g. pCloud) |
| zsign | `zsignExe` in `loop-segments-windows.json`, else `..\env_setup\zsign\zsign.exe` next to the repo, else `windows\signing\zsign\zsign.exe`, else `PATH` | No when in a synced folder |
| Password | Credential Manager, generic credential `LoopSegments-signing` | **Yes**: set it on each PC |
| Work files | `%USERPROFILE%\.loopsegments-sign-work` (deleted after each install) | Yes |

1. **Export the certificate:** iPhone → **SideStore → Settings → Certificate Management** → **long-press the certificate** (named after the tool that made it, e.g. **iLoader (R)**) → **Export Certificate** → **Export Full (.p12)** → choose a password → save to **iCloud Drive → Downloads**. Pick **Full**: zsign needs the private key. The file is named `iPhone Developer_ <Apple ID> (<cert ID>).p12`. Older SideStore builds have **Export Signing Certificate...** near the bottom of Settings instead. iloader gave SideStore this certificate when it installed it. iloader itself can't export it; it only keeps the private key in Windows Credential Manager (`<sha256 of Apple ID>/key.iloader`).
2. **Run the setup with the export** (copies it to `windows\signing\signing.p12`, asks for the password, downloads zsign if missing, runs the check):
   ```powershell
   .\setup\Set-LoopSegmentsSigning.ps1 -P12 "<path to the exported .p12>"
   ```
   Then **delete the export in iCloud Drive**: it's your signing key.
3. **Password:** the setup asks for it with `cmdkey`'s own prompt, so it stays out of history. It is stored per PC: on another PC, just run `.\setup\Set-LoopSegmentsSigning.ps1` (no `-P12` if the folder synced). `-ResetPassword` asks again. By hand: `cmdkey /generic:LoopSegments-signing /user:p12 /pass`.
4. **zsign:** when none is found, the setup downloads `zsign-windows-x64.zip` (the version pinned in `lib\Get-LoopSegmentsSigning.ps1`, v1.1.3) from [zhlynn/zsign releases](https://github.com/zhlynn/zsign/releases), checks it against the SHA-256 pinned there (from the release's `SHA256SUMS.txt`), and unzips it to `..\env_setup\zsign\` when an `env_setup` folder sits next to the repo (shared with the sibling iOS app repos; ignored by that repo's git), else to `windows\signing\zsign\`. Elsewhere: set `zsignExe`, or put `zsign` on `PATH`.
5. **Check:** the setup ends with `READY <bundle id>; profile valid until …; certificate until …` (needs the iPhone on USB; without it, it only says everything is set up). Run `.\setup\Set-LoopSegmentsSigning.ps1` again any time to re-check.

**Not under `%LOCALAPPDATA%`:** the Microsoft Store Python (`py` from WindowsApps) sees its own private copy of `AppData\Local`, so it can't read files placed there from outside. That's why the certificate and zsign live in the repo's folder or next to it, and the work files in `%USERPROFILE%`.

**Profile expiry (7 days):** free-account profiles last 7 days, and every SideStore refresh puts a new one on the phone, so each deploy reads the current one from the phone. With no SideStore refresh for 7 days, the check reports `NO_PROFILE … expired` and the deploy uses the SideStore path. **Keep refreshing in SideStore** (LocalDevVPN on, or the Shortcuts automation). The **certificate** lasts a year (the check prints its expiry date). If it is revoked (e.g. in iloader) or SideStore makes a new one, the check reports `NO_PROFILE … another certificate`: export it again (steps 1-2).

| Check result | Meaning / fix |
|---|---|
| `NO_P12` / `NO_PASSWORD` | Run `.\setup\Set-LoopSegmentsSigning.ps1` (with `-P12 <file>` if the certificate is missing) |
| `BAD_P12` | Wrong password (`-ResetPassword`) or expired certificate |
| `NO_PROFILE … expired` | Refresh Loop Segments in SideStore |
| `NO_PROFILE … another certificate` | SideStore's certificate changed: export again |
| `NOT_INSTALLED` | Install once via SideStore first (it registers the app ID and profile) |

**iCloud sync is slow (export not on the PC yet):** iCloud for Windows has no sync command. Restarting its Drive process makes it check again. This works for Apple's installer and the Microsoft Store version, since it restarts whatever is running:
```powershell
$p = (Get-Process iCloudDrive -ErrorAction Stop).Path; Stop-Process -Name iCloudDrive -Force; Start-Process $p
```
If it doesn't come back (the Store version may refuse a direct start), open **iCloud** from the Start menu. Or right-click the file in File Explorer → **Always keep on this device**. On the phone, the Files app must show the upload as finished (no cloud-arrow icon) first.

## Open Loop Segments over USB (pymobiledevice3)

Force-launch the app from the PC when the iPhone is **USB-connected** and trusted (iTunes / Apple Mobile Device Support). Used standalone or by `Run-PCloudWebCompanion.ps1` after Chromium. Scripts: `usb\Launch-LoopSegmentsViaUsb.ps1`, `usb\Kill-LoopSegmentsViaUsb.ps1`, `usb\Resolve-LoopSegmentsBundleId.py`, `usb\Probe-IphoneUnlock.py`, `usb\Probe-LoopSegmentsForeground.py`. Skips relaunch when USB DVT already reports the app **foreground** (`-ForceRelaunch` to always launch and allow a process restart). Otherwise DVT uses **`--no-kill-existing`** so a Keep Alive / lock-screen export is only brought forward (not killed). Launch order is **DVT `--userspace` first**; `core-device launch-application --userspace` often times out on the RSD handshake (iOS 26) and is only a fallback — a `TimeoutError` traceback there is not a failed launch if DVT then prints `Process launched with pid`. **Kill** (not Home): `usb\Kill-LoopSegmentsViaUsb.ps1` DVT-kills the process whether foreground or background — that is what stops Keep Alive and the `:8765` LAN page from the PC (Home only backgrounds).

```powershell
# Prefer Setup (installs 3.12 tooling). Manual:
py install 3.12
py -3.12 -m pip install -U pymobiledevice3
# Phone: Settings → Privacy & Security → Developer Mode → On
# Unlock phone, then:
.\usb\Launch-LoopSegmentsViaUsb.ps1
# If Developer Disk Image is already mounted:
.\usb\Launch-LoopSegmentsViaUsb.ps1 -SkipMount
```

| Topic | Notes |
|-------|--------|
| Bundle id | Usually `com.loopsegments.app`; AltStore may resign as `com.loopsegments.app.<suffix>`. **USB launch lookup is independent of that suffix** (and of whatever alphanumeric suffix AltStore shows in App IDs / the app name): each run re-resolves on the phone (`Resolve-LoopSegmentsBundleId.py` — prefix `com.loopsegments.app.*` or display name **Loop Segments**). LAN companion talks `:8765` only (ignores bundle id). |
| App ID renew vs suffix | AltStore **Renew App IDs** extends the same Apple slot — it does **not** change the resigned suffix. A new suffix appears only if AltStore **registers a new** App ID (e.g. delete + reinstall after the old slot expired). USB launch still finds the app either way. |
| Unlock | Needed only when companion actually USB-launches. Exit **3** if locked during launch — companion **warns** and Chromium stays open. Companion probes LAN (prints UP/DOWN); **skips USB launch** when LAN is up **and** `pcloud_list.json` reports **signedIn**; otherwise **foregrounds briefly**, waits for `:8765` (up to ~60 s (skipped when the phone's Wi-Fi address, read over USB, is off the phone LAN's /24: it cannot answer there, so LAN recover runs right away and moves it back)), then **USB Home** backgrounds again (unless `-SkipUsbLaunch` / `-SkipGoHome`). Skips relaunch when USB DVT already sees Loop Segments **foreground**; otherwise **`--no-kill-existing`**. If USB is missing but LAN is UP, warns and continues. Finish-time Home is skipped when the phone is locked (treated as already backgrounded) |
| Home on quit | Companion finish **POSTs `/keep_alive.json`** first (build **440+**) to **reset Keep Alive to 60 min**, then backgrounds Loop Segments over USB (`usb\Go-IphoneHomeViaUsb.ps1`) **in-process** (**only if it is still the foreground app**). Lock screen or already-backgrounded → skip (`HOME_USB_EXIT:0`). Prefers **DVT `--userspace`** (SpringBoard, then Settings) — the same path as USB launch. **`core-device hid --userspace`** is skipped by default (iOS 26 RSD `TimeoutError` typer dump); pass `-TryUserspaceHid` to try it anyway. No USB → skip. Each attempt times out (~25s); `-SkipGoHome` never presses Home. A failed Home press does **not** fail the companion session (still exit 0), but the window **waits for Enter** so the dump stays readable. Direct runs of the Home script also wait on error unless `-NoWaitEnter` (throws `HOME_USB_EXIT:<code>` so the companion host is not killed). Finish also stops the phone rclone mount and runs Wi‑Fi→www AP bounce **in-process** so a dead WinFsp `L:` cannot hang a nested `pwsh` on `InitializeDefaultDrives`. The bounce restores the phone's internet over Wi‑Fi, which SideStore needs for its daily app refresh. Side effect: while the phone-LAN router restarts, the PC (and a Quest headset) join their other saved Wi‑Fi and stay there until the next companion start ([quest/README.md](quest/README.md#5-how-the-pc-finds-the-headset)). Export continues in background only if the app’s **Keep Alive** is on (default since build 272 — details in [../ios/README.md](../ios/README.md)) |
| Trust / 7-day cert | Free/Personal Team installs **stop opening after ~7 days** without refresh. **SideStore:** LocalDevVPN → Refresh. **AltStore:** start AltServer → USB + unlock → **Refresh All** → Trust → open once. Scripts **skip AltServer by default**; pass `-EnsureAltServer` / `-EnsureAltStorePrep` for AltStore |
| AltStore UDID (1006) | **“could not determine this device's UDID”** — reinstall AltStore from AltServer (USB). Then **Refresh All**. If Loop Segments is **“not available”**, reinstall the **same** IPA via My Apps → **+** (new GitHub build not required). See tip above / [BUILD-WITHOUT-MAC.md](../ios/BUILD-WITHOUT-MAC.md) |
| AltServer | **Skipped by default** everywhere. Opt-in: companion/USB/setup `-EnsureAltServer`; deploy/copy-to-icloud `-EnsureAltStorePrep`. Optional logon start: `.\sideload\Register-AltServerAtLogon.ps1` |
| “already mounted” | Harmless — DDI is up; script skips remount (or use `-SkipMount`) |
| Background launch | **Not supported** — USB launch opens/foregrounds the app (DVT **`--no-kill-existing`** unless `-ForceRelaunch`); lock only after Keep Alive is running (app setting) |
| Kill / stop LAN | USB Home leaves Keep Alive (and `:8765`) running. To stop the LAN page from the PC: `usb\Kill-LoopSegmentsViaUsb.ps1` (DVT kill). Foreground-only kill remains in `Probe-LoopSegmentsForeground.py --kill` (SideStore prep) |
| iOS 17+ / 26 launch | Tries **`dvt launch --userspace --no-kill-existing`** first (no admin). `core-device --userspace` RSD handshake timeouts are collapsed to one line and the next method is tried. If DVT also fails: elevated `py -3.12 -m pymobiledevice3 remote tunneld`, then `.\usb\Launch-LoopSegmentsViaUsb.ps1 -UseTunneld -SkipMount` |

## Day-to-day mount

After setup, double-click **`rclone\Mount-PhoneL.cmd`** or run:

```cmd
rclone\Mount-PhoneL.cmd
```

Same as `.\rclone\Mount-LoopSegmentsRclone.ps1` — reads **`loop-segments-windows.json`** (IP, drive letter, rclone paths). Leave the window open while **L:** is in use; **Ctrl+C** stops the mount. If `pcld_ios_media/` exists on the phone, the mount **starts there** (`L:\loop`, `L:\archive`, `L:\scripts`) — do not create a nested `L:\pcld_ios_media`. Otherwise Explorer shows `L:\pcld_ios_media\`. After WinFsp attaches, the mount script notifies Explorer (**This PC**) so **L:** appears without F5; the same notify runs when the letter is removed (mount **Ctrl+C** / console X / LAN-watch unmount / `-Remove`). While mounted, the script polls phone `status.json` and **kills rclone + exits** if LAN stays down ~60s (avoids Explorer hangs). If the phone LAN page cannot be reached at mount time, **`..\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`** runs **in-process** and uses USB/`pcapd` (`env_setup\lan`) to align the phone with the PC subnet (or, without USB, reboots off-subnet routers under `P:\all_scripts\5g_router_reboot`), then retries (`-SkipOffSubnetRouterReboot` to disable). Mount log: **`%TEMP%\loopsegments-rclone-mount.log`** (copied to **`rclone\loopsegments-rclone-mount.log`** on quit). If the IP changed: `.\setup\Set-LoopSegmentsLANHost.ps1 <new-ip>` first.

Optional args: **`rclone\Mount-PhoneL.cmd -ReadOnly`**, **`-Remove`**, **`-TestOnly`**, **`-Unstick`**, **`-Quick`**, **`-NoLanWatch`**, **`-LanDownSeconds`**, **`-LanPollSeconds`**.

**Explorer frozen after LAN dies:** wait for auto-unmount, or run **`rclone\Unstick-PhoneL.cmd`** (kills mount + restarts Explorer). If Explorer is already wedged: Task Manager → File → Run new task → full path to `Unstick-PhoneL.cmd`.

## Multiple iPhones — unified LAN listing

Each phone runs its own LAN server on **`http://<phone-ip>:8765/`**. To browse **all** phones from one place on the PC:

1. Add every phone to **`phoneLanHosts`** in `loop-segments-windows.json` (keep **`phoneLanHost`** as the primary rclone mount target):

```json
"phoneLanHost": "10.0.100.10",
"phoneLanHosts": [
  { "host": "10.0.100.10", "label": "iPhone A" },
  { "host": "10.0.100.11", "label": "iPhone B" }
]
```

2. One-shot JSON or HTML:

```powershell
.\lan\Get-LoopSegmentsUnifiedLANListing.ps1
.\lan\Get-LoopSegmentsUnifiedLANListing.ps1 -Format html -OutFile unified-lan.html
```

3. Live index page on the PC (re-polls phones on each refresh):

```powershell
.\lan\Serve-LoopSegmentsUnifiedLAN.ps1
# Open http://<pc-ip>:8766/
```

The page asks for the phone LAN login (`webdavUser` + `webdavPassword`, or a `phoneLanHosts` entry's password), because it shows what the phones keep behind that login. It also refuses clients outside private address ranges, and `Host` headers that are not an IP address or `localhost`. Open it by IP, not by a host name.

Links in the unified view point back to each phone’s `:8765` URL — playback and WebDAV still go to the phone that holds the file. **`rclone\Mount-LoopSegmentsRclone.ps1`** still mounts **one** phone at a time (`phoneLanHost`).

### LAN throughput (after rclone mount)

With **`L:`** up, measure PC ↔ phone Wi‑Fi both ways (phone HTTP + rclone mount copy) using a random media file under `L:\archive\` (or `L:\pcld_ios_media\archive\` if the mount is WebDAV root) (≥ `-MinBytes`, default **8 MB**):

```powershell
.\rclone\Mount-PhoneL.cmd          # leave open
.\lan\Measure-LoopSegmentsLanThroughput.ps1
# .\lan\Measure-LoopSegmentsLanThroughput.ps1 -MaxBytes 0      # full file
# .\lan\Measure-LoopSegmentsLanThroughput.ps1 -KeepLocal       # keep temp copy
```

Reports MB transferred and Mbps (default caps at **64 MB**), then recommends a **max media bitrate** for minute segments (**80%** of measured LAN, clamped 5–80 Mbps; Intel av1_qsv CBR near 100M codes blocky / hazy segments) and writes sidecars under `L:\scripts\lan_throughput.json` and `L:\archive\lan_recommended_segment_bitrate.json` (same names under `L:\pcld_ios_media\` if the mount is WebDAV root). **`run_batch_vr_hybrid.ps1`** / **`Run-TranscodeFfmpeg.ps1`** pick that up for `-SegmentVideoBitrateMbps` (flat + fisheye pass-2). If measured throughput is below **`minLanThroughputMbps`** (default **40**), **reboots Wi‑Fi on every known router except the current default gateway**, waits ~20s, and **re-measures** — up to **2** retries, or until throughput is at least the minimum. Companion runs the same loop after Chromium is open (this PC’s AP is left up). This is **not** 5G WAN speed. `-ResultFile <path>` also writes the final result (after re-checks, or `ok: false` with the error) as JSON; the companion writes `%TEMP%\loopsegments-lan-throughput.json`, which the **Quest control page** shows. Its **Measure LAN** button re-runs this probe (HTTP, plus the mount when it is up; never reboots routers): [quest/README.md](quest/README.md#lan-bandwidth-pc--phone-from-the-control-page).

**LAN page (phone `:8765`):** **LAN speed test** on **`/`** / **`/browse`** runs **5×** streamed **HTTP** Range downloads (same file, up to 64 MB each ≈ **320 MB** total) in whatever browser opens the page, takes the **median** Mbps, then **POSTs** `/lan_throughput.json` so the phone writes those same sidecars under `pcld_ios_media/` (no `L:` mount required). HTTP-only (`measureMethod: http-lan-page`) — **no** rclone mount leg and **no** other-router reboot; use this Measure script / companion for those. **WAN speed test** on the same pages (and companion startup): phone POSTs `/wan_throughput.json` — random pCloud video ≥**375 MB**, ~**30 s** WebDAV Range → Mbps (cellular OK).

**Quest encode budget:** segment / `3d_playlist_local` bitrate is for **PC or phone → Quest** play. Run the LAN page from the **Quest browser** so the probe is **phone → Quest** (often the slowest Wi‑Fi path and a better conservative ceiling than phone→PC). A PC-browser run still works for a quick phone→PC check, but it can overstate what Skybox/AirScreen will sustain. Median of 5×64 MB Ranges ≠ Skybox streaming — use the sidecar as headroom, not a perfect mimic.

**Do not run the probe during an active Virtual Desktop headset session.** VD streaming the PC screen uses about **50 Mbps** of LAN and will understate phone LAN capacity. The measure script prints this on the console (and warns again if Streamer is running).

## What goes in `loop-segments-windows.json`

| Field | Purpose |
|-------|---------|
| `phoneLanHost` | Saved iPhone Wi‑Fi IP (fallback / forced when `phoneLanHostSource=config`). **Empty by default** (no built-in phone IP): `setup\Setup-LoopSegmentsWindows.ps1` and the Quest helpers read it from whichever iPhone is on USB and save it. New phone: `.\setup\Set-LoopSegmentsLANHost.ps1 -ForceDiscover` |
| `phoneLanHostSource` | **Super-config:** `config` (default) = force `phoneLanHost`; `usb` = current Wi‑Fi read over USB at companion start (the phone's network monitor: its own address on `en0`; then its Wi‑Fi hardware address looked up in this PC's ARP table after one ping sweep of its own /24s (exact when they share a network); pcapd sniffing as the last fallback). Bare run of `setup\Set-LoopSegmentsPhoneLanHostSource.ps1` toggles |
| `preferUsbPhoneLanHost` | Mirror of `phoneLanHostSource` (`true`↔`usb`) for older callers |
| `phoneLanHosts` | Optional array `{ host, label?, port? }` — unified LAN listing across multiple iPhones |
| `lanPort` | Usually `8765` |
| `minLanThroughputMbps` | Companion/measure: if LAN probe is below this (default `40`), reboot other routers (not current gateway), settle, re-check (up to 2 retries) |
| `mountDriveLetter` | Preferred phone mount letter (default `L`). If that letter is already taken (e.g. Koofr), mount picks a **random free D–Z** and saves it here so Unstick/companion stay in sync. Reuse if rclone is already on that letter. |
| `rcloneRemoteName` | Block name in `rclone.conf` for the phone (default `loopsegments`) |
| `rcloneConfigPath` | **Empty** = auto (`%APPDATA%\rclone\rclone.conf`; created blank on first mount if missing). Only set a full path for a non-default location. |
| `rcloneExe` | **Empty** = `rclone` on PATH |
| `winfspDllPath` | **Empty** = search Program Files; set full path if detection fails |
| `skipWinFspCheck` | `true` if Koofr mount already proves WinFsp works |
| `webdavUser` / `webdavPassword` | Phone LAN WebDAV (defaults match app) |
| `ipaInstallWifiProfile` | **Empty** = each saved Windows Wi‑Fi profile in turn, those in range first (Windows' in-range list is often stale), until one gives an address off the `phoneLanHost` /24. `deploy.ps1`'s USB install moves the PC there when the phone's network after the phone LAN bounce is not already the PC's (SideStore needs www over Wi‑Fi) |
| `iCloudDownloads` | **Empty** = `%USERPROFILE%\iCloudDrive\Downloads` — target for repo-root **`copy-to-icloud.ps1`** (also used by **`deploy.ps1`**) |
| `zsignExe` | **Empty** = auto: `..\env_setup\zsign\zsign.exe` next to the repo, else `windows\signing\zsign\zsign.exe`, else `zsign` on `PATH` (PC-signed USB install; `setup\Set-LoopSegmentsSigning.ps1` downloads it when none is found). Set it only when zsign lives elsewhere on this PC |
| `dlnaFolder` | Optional legacy note / junction target (Explorer); Quest uses `rclone serve dlna` instead |
| `rcloneDlnaAddr` | rclone serve dlna bind address (default `:7879`) |
| `rcloneDlnaName` | DLNA friendly name advertised on LAN (default `Loop Segments`) |
| `skyboxExe` | Optional full path to **SKYBOX.exe** if auto-detect misses (companion starts SKYBOX VR desktop when idle and hides it to the tray) |
| `virtualDesktopStreamerExe` | Optional full path to **VirtualDesktop.Streamer.exe** if auto-detect misses (companion starts Streamer when idle, starts the service if stopped, and hides Streamer to the tray) |
| `questAdbHost` / `questAdbPort` | Quest Wi‑Fi IP and adb port (default `5555`) for the LAN page **Open on Quest** button. Empty host = an already-connected headset, the last address it was on adb at (`%TEMP%\loopsegments-quest-last-adb.txt`), or mDNS |
| `questAdbSerial` | Optional: pick this adb serial when several Android devices are connected |
| `questAdbExe` | **Empty** = `adb` on PATH / winget / Android SDK / MQDH |
| `questAdbRediscoverSec` | `60` (default) = headset not found over mDNS for this long and no adb device connected: restart the PC's adb server once to rediscover it (at most every 5 min). `0` = off. A headset that switched to another Wi-Fi network cannot be found this way: [quest/README.md](quest/README.md#5-how-the-pc-finds-the-headset) |
| `questSendLanLogin` | `true` (default) = the tab is signed in with the LAN login (login URL, then reloaded plain) |
| `questEnsureInsecureOriginFlag` | `true` (default) = Open on Quest reads `isSecureContext` in the LAN tab and, only when it is false, fixes Quest's `unsafely-treat-insecure-origin-as-secure` flag for the phone origin(s) (restarts Quest Browser, reopens the page) |
| `questClearHistoryOnExit` | `true` (default) = companion close deletes the Quest Browser history entries on the phone LAN page and the Quest control page (other history is kept) |
| `questWifiOffOnExit` | `true` (default) = companion quit opens the headset's **Settings > Wi-Fi** page (toggle in front, awake headset only) and switches its **Wi-Fi off** as its last Quest step (after history, browser, SKYBOX, sensor; before the AP bounce): a sleeping headset does not drain its battery on Wi-Fi or hop networks. While the history delete is postponed, the after-quit helper switches Wi-Fi off after its delete instead (before the held AP bounce). You switch Wi-Fi on in the headset before the next session; wireless debugging comes back by itself. `false` = leave Wi-Fi on |
| `questHistoryRetryMinutes` | `120` (default) = if that delete fails at quit (nobody wearing the headset, so Quest Browser does not answer; or headset not on adb), a background helper does it once the headset is worn, for up to 2 h; it stops when the companion starts again. `0` = off: [quest/README.md](quest/README.md#after-quit-history-helper) |
| `questClearHistoryFallback` | `"day"` (default) = if that selective delete fails (at quit or in the after-quit helper), clear **all** Quest Browser history from the last 24 hours instead (also empties *Recently closed*; once per after-quit helper run); also `hour`, `week`, `fourweeks`, `all`, or `none` |
| `questCloseLanTabsOnExit` | `true` (default) = companion close first closes Quest Browser tabs on the phone LAN page (and the control page), keeping the last one as a new-tab page when they are the only tabs (Quest Browser's History list only answers with a tab open), then closes Quest Browser itself if Open on Quest started it and no other tabs are left |
| `questKeepAwakeDuringSession` | `true` (default) = while the companion runs, the Quest proximity sensor is held off (`prox_close`) so the headset stays awake on adb; cleanup deletes the Loop Segments history entries first, then turns the sensor back on |
| `questControlPage` | `true` (default) = while the companion runs, serve the Quest control page on this PC's LAN address, port `questControlPort` (default `18766`), signed in with the phone LAN login; **Open on Quest** also opens it on the headset (`questControlPageOnQuest`) |
| `questSkyboxWebDav` | `true` (default) = the control page's SKYBOX **Push / Update / Clear** buttons (the phone as WebDAV server **Loop Segments**, signed in, at the address in `lan_config.json`), and removal of the Loop Segments entries from SKYBOX at companion close (phone WebDAV servers, any WebDAV server named Loop Segments, the rclone DLNA entry). Edits SKYBOX's database over adb and restarts SKYBOX (if open) only when the server changes |
| `questPlaylistSession` | `true` (default) = 3d_playlist_local workflows (hybrid / fisheye batch, flat orchestrator) hold the Quest sensor off at start, open the control page on the Quest (the workflow window prints a sign-in link for the PC), and get the **End session** button; see [quest/README.md](quest/README.md#3d_playlist_local-workflow-session-sensor-off-control-page-end-session) |
| `questPlaylistOpenWaitMinutes` | `0` (default) = workflow start: keep trying to open the page on the headset (every 5 s) until the workflow ends; a number = give up after that many minutes. The headset's Wi-Fi is usually off at a workflow start (the last cleanup switched it off) |
| `questPlaylistHistoryOrigins` | `[]` (default) = extra Quest Browser history origins to delete (`{pc}` = this PC's address) |
| `questPlaylistEnterExitSec` | `180` (default) = End session: seconds a workflow window gets to exit after Enter before it is killed (`0` = never) |
| `notes` | Free text (e.g. "Koofr remote = koofr on M:") |

## Koofr + Loop Segments on one PC

- **Koofr** and **loopsegments** can share one **`rclone.conf`** — different remote names and drive letters.
- Example: Koofr on **`M:`**, phone on **`L:`** via `mountDriveLetter`.

## Moving to another PC

1. Clone, copy, or sync the repo (`.pcloudignore` skips per-PC junk; do **not** commit `loop-segments-windows.json`).
2. On the new PC: `.\setup\Setup-LoopSegmentsWindows.ps1 -PhoneHost <ip>` (clears foreign `rcloneConfigPath`, builds a local companion venv).
3. Leave **`rcloneConfigPath`** empty unless this PC stores rclone.conf somewhere non-standard.
4. Do **not** rely on a synced `pcloud_web_companion\.venv` — it embeds absolute Python paths from the old user/PC.
5. **PC-signed USB install:** Setup runs `.\setup\Set-LoopSegmentsSigning.ps1`. `windows\signing\signing.p12` comes with the synced repo folder (a fresh git clone has none: pass `-P12 <export>`), zsign with the synced `env_setup` folder (else it downloads it), and it asks for the .p12 password, which each PC keeps in its own Credential Manager.

| Stays on P: / repo (intentional) | Machine-local only |
|----------------------------------|--------------------|
| Extension source, scripts | `%LOCALAPPDATA%\pcloud_web_companion\venv` |
| `chromium-profile.zip` (shared pCloud login) | Playwright browsers, unpacked extension, REST log |
| | `loop-segments-windows.json` (per-PC phone IP) |
| `windows\signing\signing.p12`, `..\env_setup\zsign\` | .p12 password (Credential Manager `LoopSegments-signing`) |

## Scripts

| Script | Role |
|--------|------|
| `setup\Setup-LoopSegmentsWindows.ps1` | **New PC bootstrap** — Python 3.12 / pymobiledevice3 / companion venv / portable json |
| `lib\Get-LoopSegmentsPython.ps1` | Shared Python picker (dot-sourced; prefer 3.12, skip 3.14+) |
| `lib\LoopSegments-Windows.ps1` | Shared config (dot-sourced; do not run alone) |
| `lib\Get-LoopSegmentsAltServer.ps1` | Loop Segments wrapper around **`..\env_setup\altserver_refresh\lib\Get-AltServer.ps1`** (locate/start); 7-day / Trust copy stays here |
| `lib\Get-LoopSegmentsSkybox.ps1` | Companion Skybox setup/teardown: dotsources repo-root **`Skybox_vr_pc`** submodule ([skybox-vr-pc](https://github.com/dsouzaankit/skybox-vr-pc); fallback `P:\all_scripts\Skybox_vr_pc`) for start/hide/quit + AirScreen `p_cld_media` (clears stale phone-rclone Add-folders; Quest phone media uses rclone DLNA) (`-SkipSkybox` to skip) |
| `lib\Get-LoopSegmentsVirtualDesktop.ps1` | Locate/start **Virtual Desktop Streamer**, start the service if it is stopped, and hide the Streamer window to the **tray** (`-SkipVirtualDesktop` to skip). Companion finish does not quit Streamer |
| `lib\Get-LoopSegmentsClash.ps1` | Optional: if Clash/mihomo is running, UAC-run **`env_setup\altserver_refresh\VpnMulticast\Remove-VpnMulticastRoute.ps1`** so TUN `224.0.0.0/4` does not steal `.local` mDNS. Phone-IP / `:8765` use numeric IPs and do not need this. |
| `setup\Set-LoopSegmentsSigning.ps1` | PC-signed USB install setup on any PC (Setup runs it; `-SkipSigning` there): downloads zsign (pinned version, SHA-256 checked) when none is found, `-P12 <export>` copies SideStore's certificate to `windows\signing\signing.p12`, asks for its password via `cmdkey` (per PC; `-ResetPassword`), then runs the check. `-NoPrompt`, `-SkipZsign`. Exit 0 ready (or set up, no iPhone on USB), 1 something missing |
| `setup\Set-LoopSegmentsWindows.ps1` | Edit per-PC json |
| `setup\Set-LoopSegmentsPhoneLanHostSource.ps1` | **Super-config** before companion: bare run / double-click **toggles** `usb`↔`config`; also `-Usb` / `-Config` / `-Show` |
| `setup\Set-LoopSegmentsLANHost.ps1` | Set `phoneLanHost` (no args = read over USB; or pass IP; `-ForceDiscover` re-reads USB even if `:8765` up) |
| `lan\Discover-LoopSegmentsLanHost.ps1` | USB → save `phoneLanHost`: the phone's own address on its TCP connections over `en0` from its DVT network monitor (`usb\LoopSegments-UsbInfo.py wifi-ip`); nothing open on Wi‑Fi → the phone's Wi‑Fi address in this PC's ARP table after a ping sweep (`source: usb-mac-arp`, exact on a shared network) → pcapd sniffing fallback (a guess: it can pick a peer such as this PC) (`-Force`, `-NoSave` print only; Enter on direct run, `-NoWaitEnter` for callers) |
| `lan\Get-LoopSegmentsUnifiedLANListing.ps1` | **Pool media listings** from all `phoneLanHosts` → JSON or HTML |
| `lan\Serve-LoopSegmentsUnifiedLAN.ps1` | PC HTTP index on `:8766` (merged view; phones still serve files on `:8765`) |
| `lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1` | Wrong subnet: **saved-Wi‑Fi switch first** (`lib\Get-LoopSegmentsWifi.ps1`, no reboot); none reaches the subnet → **loop** (wait tcp/23 → reboot → wait up to ~20s for new PC LAN IP or AP back on telnet → re-check, max 3 rounds; telnet fail continues) / forced / **off-subnet sequential** / **`-RebootOtherRouters`** (low Mbps: every known AP except current gateway) / **`-BouncePhoneLanAp`** (phone LAN page subnet AP after Wi‑Fi→www probe fail; ~20s tcp/23 wait; if WifiRestart drops the telnet session then tcp/23 returns, treats that as success and does **not** reboot twice; exits 1 if bounce does not confirm). **Off-subnet / other-router passes skip APs with closed tcp/23** (avoids ~60s telnet WinError 10060). Direct run waits for Enter; companion passes `-NoWaitEnter`. Quit-time bounce also passes **`-InProcessThrowExit`**: sets `LoopSegmentsGatewayExitCode` and throws `GATEWAY_EXIT:<code>` (including **0**); the script’s outer `try/catch` swallows that quietly (no red stack). No nested `pwsh` / dead-`L:` hang. While the Quest after-quit history helper is waiting for the headset, the quit holds this bounce (`%TEMP%\loopsegments-wifi-bounce-pending.json`) and the helper runs it afterwards (after the delete or its 2 h give-up; output `%TEMP%\loopsegments-wifi-bounce.log`): bouncing first would move the headset to the other Wi-Fi, out of the PC's reach. |
| `lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1` | In-process USB/`pcapd` via **`env_setup\lan`** (phone IP vs PC subnet), then wait for `:8765`. If already on-subnet: short `:8765` wait (**5 s**, `-WaitOnSubnetSec`); if still down, **USB-launches** with **`-ForceRelaunch`** (avoids “already foreground” skip when `:8765` is dead), waits (**60 s**, `-WaitAfterUsbLaunchSec`), then **USB Home** backgrounds again (companion-style; `-SkipUsbLaunch` / `-SkipGoHome`). Does **not** burn the **45 s** pre-reboot grace or bounce routers when Wi‑Fi is already right. Off-subnet / no USB: wait **`-WaitBeforeRebootSec`** (45) then off-subnet router reboot. Idle phone → **soft exit 4**. `-NoWaitEnter` throws `LAN_RECOVER_EXIT:<code>`. |
| `lan\Invoke-LoopSegmentsCompanionWifiReorientAfterIpa.ps1` | **After IPA deploy:** re-run companion Wi‑Fi setup — gateway align (`Invoke-LoopSegmentsGatewayWifiRebootIfNeeded`) then phone LAN recover (`Invoke-LoopSegmentsPhoneLanRecoverIfNeeded`). If `:8765` is still down (often after bouncing off the phone LAN for SideStore), USB-foregrounds Loop Segments and waits again. Direct run waits for Enter; `-NoWaitEnter` throws `COMPANION_WIFI_REORIENT_EXIT:<code>`. |
| `lan\Measure-LoopSegmentsLanThroughput.ps1` | Time up to 64 MB via phone HTTP (+ optional rclone mount) from a random `L:\archive\` (or `L:\pcld_ios_media\archive\`) media file → Mbps + recommended max segment bitrate sidecar for hybrid batch. Phone LAN **LAN speed test** writes the same sidecars over HTTP only (no mount / no router reboot) |
| `lan\Start-LoopSegmentsCloudflareTunnel.ps1` | **Deprecated.** Asks you to type YES before starting, or pass `-AcceptPublicExposure`. **Cloudflare quick tunnel** to configured `phoneLanHost`:`lanPort` (default `:8765`). Prints / clipboard-copies `*.trycloudflare.com` host for the LAN page tunnel textbox → **Update links** (Quest WebXR). Needs `cloudflared` on PATH (`winget install Cloudflare.cloudflared`). Leave window open; Ctrl+C stops. **Security:** while running, the tunnel exposes the whole phone server (media, pCloud listing, export controls) at a public URL, and the LAN password is public in this repo. Close it as soon as you are done, and prefer the Quest insecure-origin flag. Build 443+: save the printed host in the LAN page's Cloudflare tunnel box, or the phone refuses the tunnel (421). |
| `rclone\Mount-PhoneL.cmd` | **Day-to-day** launcher → `Mount-LoopSegmentsRclone.ps1` |
| `rclone\Serve-PhoneDlna.cmd` | **Day-to-day** launcher → `Serve-LoopSegmentsRcloneDlna.ps1` (Quest Network) |
| `rclone\Unstick-PhoneL.cmd` | Kill dead phone mount + restart Explorer |
| `rclone\Mount-LoopSegmentsRclone.ps1` | **`-TestOnly`** / mount / **`-Remove`** / **`-Unstick`** / **`-Quick`** / LAN watch / **`-RemovePort80Proxy`** |
| `rclone\Serve-LoopSegmentsRcloneDlna.ps1` | **`-TestOnly`** / `rclone serve dlna` / **`-Remove`** / **`-Quick`** / **`-Hidden`** (companion default) / LAN watch |
| `%TEMP%\loopsegments-rclone-mount.log` | live rclone mount log (copied to `rclone\loopsegments-rclone-mount.log` on quit) |
| `%TEMP%\loopsegments-rclone-dlna.log` | live rclone DLNA serve log |
| `pcloud_web_companion\Run-PCloudWebCompanion.ps1` | PC companion: gateway subnet check/reboot, USB-launch Loop Segments, sync profile, start Chromium, Quest control |
| `quest\Watch-LoopSegmentsQuestLanTab.ps1` | Quest Browser over adb + DevTools: `-Once` (the **Open on Quest** button, with `-WaitMinutes 7` so a click on an asleep headset opens the page when it wakes) opens the phone LAN page in a signed-in **normal tab** and checks `isSecureContext` there (fixes the insecure-origin flag only when false); `-EnsureFlags` fixes the flag through `chrome://flags` (by hand); `-ResetFlags` resets all `chrome://flags` entries and restarts the browser (`quest\Reset-QuestBrowserFlags.ps1` wraps it); `-ClearHistory` deletes the Quest Browser history entries on the phone LAN page and the control page, keeping other history (companion close); a failed quit-time delete goes to quest_tools' detached after-quit helper (`Invoke-QuestHistoryRetry.ps1`: does it once the headset is worn, up to `questHistoryRetryMinutes`, then `quest\Invoke-LoopSegmentsHeldWifiBounce.ps1` runs any Wi-Fi AP bounce the quit held for it); `-KeepAwakeSession` holds the proximity sensor off while the companion runs (only once the headset is awake: it would wake one in standby); `-EnableProximity` turns it back on (companion close); `-SkyboxPush` / `-SkyboxUpdate` / `-ClearSkyboxWebDav` put the phone in SKYBOX as a WebDAV server, move it to the current address, or remove it (the control page buttons; the clear also at companion close; via `quest\QuestSkybox.ps1`). Without a mode it opens the page once, like `-Once` (the old keep-watching mode is gone). Setup: [quest/README.md](quest/README.md). Log `%TEMP%\loopsegments-quest-lantab.log` |
| `quest\Set-LoopSegmentsQuestProximitySensor.ps1` | Flip the Quest proximity sensor (off = headset stays awake on adb and shows a "Proximity sensor OFF" notification, opening the notifications list for 20 s to show it; on = sleeps when taken off, notification removed), show the final state or the error, wait for Enter. First moves this PC to the phone's network if it is on another one (runs `lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1`, like companion startup; `-SkipNetworkCheck` skips it), then waits up to 2 min for the headset on adb (`-WaitSec`); never cycles the PC through other saved Wi-Fi networks (it passes quest_tools' `-NoNetworkCycle`, so the PC stays on the phone's network). `-State On|Off|Toggle` (default Toggle), `-NoWait` |
| `quest\Reset-QuestBrowserFlags.ps1` | Reset all Quest Browser `chrome://flags` entries to their defaults (*Reset all*) and restart Quest Browser (closes its tabs; closed again afterwards if it was not running, its own history / *Recently closed* traces removed), checking the insecure-origin flag is no longer enabled afterwards; the next **Open on Quest** sets that flag again. Like `Set-LoopSegmentsQuestProximitySensor.ps1`: moves this PC to the phone's network first if needed, then waits up to 2 min for the headset on adb. Needs the phone LAN page up and the headset worn. Log `%TEMP%\loopsegments-quest-lantab.log` |
| `quest\Set-LoopSegmentsQuestWifiOff.ps1` | Switch the headset's **Wi-Fi off** now (Settings > Wi-Fi opened first on an awake headset), whatever `questWifiOffOnExit` says; adb drops right after. Like `Set-LoopSegmentsQuestProximitySensor.ps1`: PC onto the phone's network first, waits up to 2 min for the headset on adb. Switch Wi-Fi back on in the headset |
| `quest\QuestToolsPath.ps1` | Finds the **quest_tools** repo (`$env:QUEST_TOOLS_REPO`, else `P:\all_scripts\quest_tools` next to `iOS apps`): the generic headset layer these `quest\` scripts load (adb, finding the headset, proximity sensor, Wi-Fi off, Quest Browser DevTools, SKYBOX database; the sensor / Wi-Fi tools above forward to its copies). Setup and adb trouble: `quest_tools\README.md` |
| `quest\LoopSegmentsControlTiles.ps1` | This repo's tiles on the shared Quest control page (quest_tools `QuestControlHost.ps1`, port `controlPort` / `questControlPort`, default 18766): SKYBOX Push / Update / Clear, Measure LAN (PC ↔ phone), **End session** (companion-only sessions: 3d_playlist_local's `Invoke-PlaylistLocalQuestShutdown.ps1`, else a graceful close of the companion's Chromium; hidden while a 3d_playlist_local workflow's Session Control tile is on the page), recent SKYBOX log; the phone LAN login also signs in. Registered by the companion at startup, removed at close |
| `usb\Launch-LoopSegmentsViaUsb.ps1` | Force-open Loop Segments over USB (`pymobiledevice3`); DVT `--userspace --no-kill-existing` first; skips if already foreground; exit **3** if phone locked |
| `usb\Kill-LoopSegmentsViaUsb.ps1` | Force-quit Loop Segments over USB (DVT kill + SIGKILL, matches `LoopSegments` / `.app` path even when background Keep Alive omits bundle id) — stops Keep Alive / `:8765`; verifies process gone and optionally waits until LAN is down (exit **1** if still up; `-SkipLanCheck` / `-LanWaitSec`) |
| `usb\Prepare-PhoneForSideStoreViaUsb.ps1` | Run by repo-root `deploy.ps1` after it triggers the IPA build (and before the USB install with `-UseLatest` / `-RunId`). iPhone on USB (usbmux) → quits Loop Segments if it is the **foreground** app (`deploy.ps1` always passes `-NoQuit`, and skips this script with `-SkipUsbInstall`: the USB install relaunches the app at the handover, so it stays open during the build; the quit is for running this script by hand) (DVT kill via `usb\Probe-LoopSegmentsForeground.py --kill`; not while an export or the pending queue runs, checked on the LAN page when reachable) → connects LocalDevVPN if its tunnel process is not running (`usb\Connect-LocalDevVPNViaUsb.py`: launches it, its **Auto-connect on launch** connects in ~5 s, then Home Screen) and leaves `%TEMP%\loopsegments-vpn-turned-on.json` so the install switches it back off. Also leaves `%TEMP%\loopsegments-export-busy.json` while an export or the pending queue runs, so the install never restarts the phone then. No router is touched (the phone LAN Wi‑Fi has no gateway on purpose). LocalDevVPN is skipped when the PC-signed install is ready (`lib\Get-LoopSegmentsSigning.ps1`). `-NoQuit`, `-NoVpn`, `-ForceVpn` (connect anyway: the install's SideStore fallback). Always exit 0 |
| `usb\Install-LoopSegmentsIpaViaUsb.ps1` | Run by repo-root `deploy.ps1` after the IPA download. iPhone on USB, not already on the IPA's build (`-Force`: the same build is reinstalled; an IPA older than the phone's build is never installed) → moves the phone and the PC **off** the phone LAN (`phoneLanHost` /24; SideStore signs over Wi‑Fi www, which the phone LAN lacks): phone on it (read over USB from the DVT network monitor: its address on its **TCP** connections over `en0`; none = no www on Wi‑Fi = the phone LAN, since leftover UDP sockets can keep an old address; `wifi-assoc` tells that apart from no Wi‑Fi at all, 5G only, where a bounce is skipped and the script waits for the phone to join a Wi‑Fi, asking you to tap it; every check during these waits prints the phone's state) → PC onto the phone LAN first (the AP's restart command, telnet, only answers there; `netsh wlan connect` to saved profiles, in range first) → `lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 -BouncePhoneLanAp` so the phone hops to another saved Wi‑Fi, (no wait for the bounced AP to come back, which can take minutes; `-NoBounce` skips); PC not on the phone's new /24 → `netsh wlan connect` to `ipaInstallWifiProfile` or each saved profile (in range first; the in-range list is often stale) → quits SideStore and restarts LocalDevVPN (tunnel extension quit, fresh app, Auto-connect, ~12 s; no Loop Segments launch) so every try starts both fresh → checks the phone is still on the install Wi‑Fi (its Wi‑Fi address from `wifi-assoc` — iOS uses a private address per network, and redacts SSID/BSSID — and not dropped to 5G), right before the link and every 10 s until the download starts; right before the link and to confirm a "left" it also compares the phone's network name from its live Wi‑Fi log (`wifi-ssid`: wifid's `CurrentBSS {name - bssid}`, unredacted, but an idle phone may log none for a while) with the PC's; if it left (e.g. back to the phone LAN AP, SideStore -1001) it is moved again, or the try is retried like a cut download → launches the link (a launch refused on a locked phone is retried every 10 s for ~1 min) → serves the IPA once at `http://<PC IP>:8766/<random>/LoopSegments.ipa` (TcpListener: no URL ACL / admin; PowerShell 7 inbound firewall allow) → launches Loop Segments over USB with `-openURL sidestore://install?url=…` (`usb\Open-LinkViaLoopSegments.py`; build **428+** opens it and quits) → you tap **Install** in SideStore → a failed try (download cut short, e.g. -1005 — the phone's network at the cut is logged — or SideStore never finished) is retried once (both re-checked, link reopened, tap again); if that fails too, `-RestartPhoneOnError` (set by `deploy.ps1`, off with `-NoPhoneRestart`) restarts the phone over USB, waits for you to unlock it and for LocalDevVPN to reconnect, then tries a last time (not while an export runs: `%TEMP%\loopsegments-export-busy.json` from the prep) → stops serving after one full download (`-WaitSec`, 300) → waits for the phone to report the new build (checked every 1 s on one USB connection; `-InstallWaitSec`, 180) → if the www check switched LocalDevVPN on (`%TEMP%\loopsegments-vpn-turned-on.json`, under 3 h old), quits LocalDevVPN's tunnel extension (no app launch, so no Face ID prompt), then goes back to the Home Screen, all on one USB connection (`usb\LoopSegments-UsbInfo.py vpn-off`, about 4 s; the VPN connect step also ends on the Home Screen). `-KeepVpn` leaves it on. Nothing moves them back afterwards: the phone usually rejoins the phone LAN by itself once that AP's Wi‑Fi is back (iOS auto-join), and the companion's start-up network check moves the PC, and the phone if still needed. The VPN marker is kept up to 3 h, so a deploy that could not switch the VPN off (e.g. timed out) is cleaned up by the next one, even if the VPN was on when that one started. SideStore's *"Some sources were unable to load"* pop-up is harmless here (sources are not used; it only matters if all fail = no internet). **Tried first:** the [PC-signed USB install](#pc-signed-usb-install-zsign-no-install-tap) (`usb\LoopSegments-UsbSign.py`: no tap, no Wi‑Fi moves); not set up or failed → it connects LocalDevVPN (`Prepare-PhoneForSideStoreViaUsb.ps1 -ForceVpn`) and runs the SideStore flow above. `-NoSignedInstall`, `-SigningP12`, `-SigningCredTarget`. Exit 0 installed / skipped, 1 not confirmed, 2 could not start |
| `usb\LoopSegments-UsbSign.py` | PC-signed USB install. `check <p12> <cred target>` → `READY` / `NO_P12` / `NO_PASSWORD` / `BAD_P12` / `NO_PROFILE` / `NOT_INSTALLED`. `sign-install <ipa> <zsign> <p12> <cred target> <work dir>`: newest matching profile from the phone, SideStore's Info.plist markers, zsign, installation_proxy (120 s limit) → `INSTALLED` / `SIGN_FAILED` / `INSTALL_FAILED`. See [PC-signed USB install](#pc-signed-usb-install-zsign-no-install-tap) |
| `lib\Get-LoopSegmentsSigning.ps1` | Shared by the prep, the install and the signing setup: `windows\signing\signing.p12`, the `LoopSegments-signing` credential, the pinned zsign version + SHA-256, `Find-LoopSegmentsZsign` (`zsignExe`, else `..\env_setup\zsign\zsign.exe` next to the repo, else `windows\signing\zsign\zsign.exe`, else `PATH`), `Invoke-LoopSegmentsSigningCheck`, `Test-LoopSegmentsSignedInstallReady` |
| `usb\Connect-LocalDevVPNViaUsb.py`, `usb\Open-LinkViaLoopSegments.py`, `usb\LoopSegments-UsbInfo.py` | USB helpers (shared code in `usb\loopsegments_dvt.py`): connect LocalDevVPN (launch it; its tunnel extension in the process list = connected), launch Loop Segments with a link, and read the installed / IPA build and VPN tunnel state |
| `usb\Go-IphoneHomeViaUsb.ps1` | Background the app on companion finish (and after the companion's brief USB foreground) if it is still foreground. Runs **`usb\Home-LoopSegmentsViaUsb.py` first**: lock probe, foreground probe, SpringBoard launch (Settings fallback) and post-check in **one Python process over one userspace tunnel** (~3 s to decide vs ~6 s for the old separate probes, which each paid their own tunnel handshake). Anything it cannot settle (tunnel/DVT error, timeout, still foreground) falls back to the per-step path (skip when backgrounded or lock screen; DVT `--userspace` first; HID `--userspace` skipped unless `-TryUserspaceHid`); no USB → skip. Direct run waits for Enter on error; companion/watchdog pass `-NoWaitEnter` (**in-process**, throws `HOME_USB_EXIT:<code>`) and companion pauses itself after a Home fail |
| `usb\Probe-IphoneUnlock.py` / `usb\Resolve-LoopSegmentsBundleId.py` / `usb\Probe-LoopSegmentsForeground.py` | Helpers for USB unlock probe, AltStore bundle-id suffix, and foreground skip |
| `pcloud_web_companion/` | MV3 extension + `_run_chromium.ps1` (see that folder’s README) |
| `sideload\Register-AltServerAtLogon.ps1` | **AltStore only:** AltServer at logon. **SideStore:** skip or `-Unregister` (LocalDevVPN Wi‑Fi refresh; no PC). UsbWatch is a **different** task — unregister with `env_setup\altserver_refresh\usb\Register-IphoneUsbAltServer.ps1 -Unregister` (also kills leftover Watch processes; task-only unregister used to leave an orphan that still started AltServer on plug-in) |
| `sideload\Register-SideloadlyAutoRefresh.ps1` | **Fallback only** — Sideloadly daemon if AltStore fails |
| `archive/` | Legacy `net use` / port-80 proxy, `Sync-FromPhoneLAN.ps1`, optional HTTP **`Copy-ToLoopSegmentsPhoneLAN.ps1`** (no **L:** mount) |

If you previously registered Sideloadly USB-watch tasks, re-run `.\sideload\Register-SideloadlyAutoRefresh.ps1 -WatchUsb` once so the scheduled task points at the new script path.

### Legacy WebDAV mapped to `http://localhost/`

`-ViaPort80Proxy` (archive script) added a **local** `:80` redirect to the phone. Prefer **`http://<phone-ip>:8765/`** + rclone today. Cleanup:

1. Run **elevated**: `.\rclone\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy`
2. **`net use L: /delete /y`** if Explorer still shows an old mapping.

See [../ios/README.md](../ios/README.md) and [../WORKFLOW.md](../WORKFLOW.md).
