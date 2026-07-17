# Build and install without owning a Mac

Apple still requires a **signed IPA** to run on a physical iPhone. You do **not** have to join the **$99/year** Developer Program for personal testing — a **free Apple ID** is enough, with a **~7-day** reinstall cycle.

| Path | Cost | Best for |
|------|------|----------|
| **[Free Apple ID + sideload (Windows)](#-0-install-on-your-iphone-free-apple-id)** | $0 | You have a PC, no Mac, okay refreshing weekly |
| **[Paid Developer + TestFlight](#paid-developer-program-99year)** | $99/year | Longer-lived installs, easier cloud CI, no weekly refresh |

You still need **something running macOS once** (or in the cloud) to **compile** the app. After that, install can be entirely from **Windows**.

---

## $0 — Install on your iPhone (free Apple ID)

### What you get

- Install **Loop Segments** on **your own** iPhone
- **No** App Store, **no** $99 fee
- App certificate expires in **~7 days** → reinstall or refresh before it stops opening
- Apple limits **3** sideloaded apps per free account at once

### What you need

1. **Free Apple ID** ([appleid.apple.com](https://appleid.apple.com)) — not the paid Developer Program; sign in at [developer.apple.com](https://developer.apple.com) once and **accept the free developer agreement** (no $99)
2. **Windows PC** on the **same Wi‑Fi** as the phone (AltStore + `Sync-FromPhoneLAN.ps1`)
3. A **`.ipa`** file (see [Get an IPA without a Mac](#get-an-ipa-without-a-mac) below)
4. **[AltServer + AltStore](#2-install-with-altstore-primary--windows)** — primary (iTunes + iCloud from Apple + AltServer)
5. **Last resort:** [Sideloadly fallback](#5-sideloadly-fallback-only-if-altstore-fails) (iTunes + USB)

### Trust the developer on iPhone (required once; not weekly)

After **AltStore** (or Sideloadly fallback) installs the app, iOS blocks it until **you** tap **Trust** in Settings. **Apple does not allow the PC or AltStore to do this for you** — it is a deliberate security step on the phone.

| When | Trust developer in VPN & Device Management? |
|------|---------------------------------------------|
| **First install** | **Yes — required once** |
| **AltStore auto-refresh succeeds** (same app, same Apple ID, before cert dies) | **Usually no** — app keeps opening |
| **Cert expired** (“Unable to Verify App”) then refresh/reinstall | **Often yes** — trust again if iOS shows the profile or “Untrusted Developer” |
| **New IPA / different Apple ID** | **Yes** |
| **Every USB plug-in** | **No** (that’s only **Trust This Computer**, not the developer) |

**Automatic refresh does not remove the first-time trust step.** It only avoids **weekly manual reinstall** on the PC — not this one-time (or occasional) phone setting.

**iOS Shortcut?** **No.** Shortcuts cannot tap **Trust** or **Allow & Restart** for you — Apple blocks that on purpose. A shortcut might open **Settings** (prefs URLs are unreliable and change per iOS version), but you still must tap trust yourself. **TestFlight** and **MDM/supervised** work devices are different; sideloaded AltStore apps are not.

| When | What to trust |
|------|----------------|
| USB cable to PC | **Trust This Computer** (only if using USB tools such as Sideloadly fallback) |
| First app launch | **Developer profile** in Settings (below) |

**Steps (iOS 16 / 17 / 18 — same path):**

1. On the iPhone, open **Settings**.
2. Tap **General**.
3. Tap **VPN & Device Management**  
   *(Older iOS may label this **Profiles & Device Management** or **Device Management**.)*
4. Under **DEVELOPER APP**, tap the profile — usually your **Apple ID email**, or **AltStore** if the tool name appears.
5. Tap **Trust “…”** (the name shown on that screen).
6. Confirm **Trust** in the popup.
7. Press the Home button or swipe up, then open **Loop Segments** from the home screen.

**If the app still won’t open:**

| Symptom | Try |
|---------|-----|
| **Unable to Trust “iPhone Developer: you@…”** (or similar with your Apple ID email) | **Settings → General → VPN & Device Management** → under **DEVELOPER APP** tap that email → **Trust “…”** → confirm **Trust** → open Loop Segments from the home screen. |
| **Loop Segments / developer profile not listed yet** | Normal right after install or before the first failed open. Wait for AltStore to show **Complete**, open (or fail-open) Loop Segments once, leave Settings and come back — the **DEVELOPER APP** email entry often appears only then. Trust it, then open the app again. |
| No **VPN & Device Management** entry at all | Install did not finish — reinstall from AltStore and wait for “Complete”. |
| **Untrusted Developer** when tapping the icon | Repeat steps 1–6 above; profile may appear only after the first failed launch. |
| **Unable to Verify App** after ~7 days | Certificate expired — [refresh the IPA](#refresh-the-ipa-later), then trust again if iOS shows a new profile. |
| Profile missing after refresh | **Settings → General → VPN & Device Management** → trust the **new** entry (old one may be gone). |

You only need to trust again if iOS shows **Untrusted Developer** / **Unable to Verify App**, or after a **failed** expiry — not on every successful auto-refresh.

### 1. Get an IPA without a Mac

Pick one:

**A — GitHub Actions (free macOS minutes)**  

1. Push this repo to **GitHub** (public repos get **unlimited** macOS runner time; private repos share ~2,000 min/month on the free plan).
2. Open the repo → **Actions** → **ios-build** → **Run workflow** (manual run builds the IPA; pushes only run the simulator smoke test).
3. When the run finishes, open the run → **Artifacts** → download **`LoopSegments-ipa`** → unzip → `LoopSegments.ipa`.  
   On this PC you can keep it at `ios\build artifacts\ipa\LoopSegments.ipa` (see [Refresh the IPA later](#refresh-the-ipa-later)).
4. Install with [AltStore](#2-install-with-altstore-primary--windows).

**Signing on GitHub (optional)**

| Mode | Secrets | Use when |
|------|---------|----------|
| **Unsigned IPA** (default) | none | Re-sign in **AltStore** with your Apple ID |
| **Signed IPA** | `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` | You want the IPA already signed with the same Apple ID used in CI |

For **signed** builds, add [repository secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions):

| Secret | Value |
|--------|--------|
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APP_SPECIFIC_PASSWORD` | [App-specific password](https://appleid.apple.com) (not your login password) |
| `APPLE_TEAM_ID` | 10-character **Personal Team** ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership details |

Workflow: [`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml).

**B — Codemagic free tier**  
Connect the repo, use [codemagic.yaml](../codemagic.yaml). In Codemagic → Code signing, choose **Apple ID** (personal team / free account) instead of a paid membership. Download the IPA from the build.

**C — One cloud Mac session**  
Rent MacinCloud / MacStadium for an hour, run `xcodegen generate`, open Xcode, sign with **Personal Team** (free Apple ID), **Product → Archive → Distribute → Development**, export IPA.

### 2. Install with AltStore (primary — Windows)

Wi‑Fi + **AltServer**. AltStore’s [Windows guide](https://faq.altstore.io/getting-started/how-to-install-altstore-windows) requires **iTunes + iCloud from Apple** (not Microsoft Store) — needed for refresh/sign-in, not only for Sideloadly.

1. Install [AltServer for Windows](https://altstore.io).
2. Install [iTunes 64-bit](https://www.apple.com/itunes/download/win64) + [iCloud for Windows](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe) from Apple; sign **iCloud** in with your Apple ID.
3. **One-time Wi‑Fi pairing** (USB first) — see [Wi‑Fi sync checkbox](#wifi-sync-for-altstore-one-time) below.
4. Enable **AltServer at logon** (installer option, or [Register-AltServerAtLogon.ps1](../windows/Register-AltServerAtLogon.ps1)).
5. iPhone and PC on the **same Wi‑Fi** (USB for first AltStore install is OK — [AltStore FAQ](https://faq.altstore.io)).
6. AltServer tray → **Install AltStore** on the phone.
7. Sign in to AltStore with your **free Apple ID**.
8. On the **iPhone**: **AltStore → My Apps → +** → select **`LoopSegments.ipa`** (see [App IDs vs My Apps](#loop-segments-not-in-altstore--my-apps) — do **not** sideload the IPA from **AltServer on PC** if you want refresh in My Apps).
9. [Trust the developer on iPhone](#trust-the-developer-on-iphone-required-once-not-weekly).

**Loop Segments not in AltStore → My Apps?**

**App IDs list ≠ My Apps.** Tap **View App IDs** (from My Apps) — that shows Apple’s **developer slots** your Apple ID has used (`com.loopsegments.app` can appear there). That does **not** mean AltStore is **managing** the app for refresh.

| Install method | Home screen icon? | In **My Apps**? | **Refresh** in AltStore? |
|----------------|-------------------|-----------------|---------------------------|
| **AltStore → My Apps → +** → pick IPA on phone | Yes | **Yes** | **Yes** |
| **Files → Share → AltStore → Install** | Yes | Usually **yes** | **Yes** |
| **AltServer tray → Sideload .ipa** (from PC) | Yes | **No** | **No** — uses App ID only |
| **Sideloadly** | Yes | **No** | Use Sideloadly daemon |

If Loop Segments is on the home screen and **`com.loopsegments.app` is in App IDs** but **not** on the My Apps list, you almost certainly installed from **AltServer on the PC**, not from **inside AltStore on the phone**.

**Fix — reinstall from AltStore on the iPhone (USB OK for signing; install UI must be on phone):**

1. Delete **Loop Segments** from the home screen (long-press → Remove App). This frees an App ID slot after it expires, or immediately if you have spare slots.
2. Copy **`LoopSegments.ipa`** to the iPhone (**Files** app — iCloud Drive, USB transfer to Files, etc.).
3. On the iPhone, open **AltStore** (not AltServer on PC) → **My Apps** → **+** (top left) → select **`LoopSegments.ipa`** → install with your Apple ID.  
   **Or:** Files → tap IPA → **Share** → **AltStore** → Install.
4. **Do not** use AltServer’s **Sideload .ipa** / drag-to-device on Windows for Loop Segments if you want My Apps tracking.
5. PC can stay on with **AltServer** in the tray (USB or Wi‑Fi) while AltStore on the phone performs the install — that’s fine.
6. **Loop Segments** should appear on **My Apps** with a refresh countdown.

**Still missing from My Apps after + install?**

| Check | Action |
|-------|--------|
| Name | **Loop Segments** (display name), not only bundle id in App IDs |
| Same Apple ID | AltStore **Settings** = Apple ID used at install |
| 3 active apps (free) | AltStore + Loop Segments + one other max — remove unused sideload |
| Developer Mode (iOS 16+) | **Settings → Privacy & Security → Developer Mode → On** |
| Stale copy | Fresh IPA from **Actions → ios-build → Run workflow** |

**Reinstall so My Apps tracks it (summary):**

1. Delete **Loop Segments** from the iPhone home screen (long-press → Remove App).
2. PC: **AltServer** running; phone on same Wi‑Fi; open **AltStore** (signed in).
3. In AltStore: **My Apps** tab → **+** (top left) → pick **`LoopSegments.ipa`** from Files/iCloud, **or** Files app → IPA → **Share** → **AltStore** → **Install**.
4. Wait until AltStore shows install complete — **Loop Segments** should appear under **My Apps**.
5. [Trust developer](#trust-the-developer-on-iphone-required-once-not-weekly) if prompted.

If **+** install fails with **incorrect data format**, see [Fix install / refresh](#fix-install--refresh--do-in-order-usb) below — try **iTunes → Account → Authorizations → Deauthorize → Authorize** first (USB; confirmed working). Otherwise check **Store iCloud** or unsigned-in iTunes, not the IPA. If error is **1007** only, use a fresh IPA from **Actions → ios-build → Run workflow** (build **243+**). Do not mix Sideloadly and AltStore for the same app.

#### Wi‑Fi sync for AltStore (one-time) — often broken on Windows 11

**Goal:** Let AltServer see the iPhone **over Wi‑Fi** so **Refresh** works without USB. You are **not** syncing music.

**Your situation matches two common Windows problems:**

| Symptom | Cause |
|---------|--------|
| **iTunes: no phone icon / no Summary** | **Apple Devices**, **Apple Music**, or **Apple TV** from the **Microsoft Store** often **disable** device management in classic iTunes. |
| **Apple Devices: checkbox unchecks after unplugging USB** | Broken or incomplete **USB trust / pairing** on the PC (known Apple Devices bug). Wi‑Fi pairing never saved. |

### Plan A — Classic iTunes only (try this if you want Wi‑Fi refresh)

1. **Uninstall** from Windows: **Apple Devices**, **Apple Music**, **Apple TV** (Microsoft Store versions).
2. Install **[iTunes 64-bit](https://www.apple.com/itunes/download/win64)** from Apple’s website (**not** Microsoft Store).
3. Keep **[iCloud for Windows](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe)** (Apple direct) — signed in with your Apple ID.
4. **Restart PC.**
5. USB → unlock → **Trust** → open **iTunes** → small **phone icon** (top-left) → **Summary** → **Options** section → ☑ **Sync with this [device] over Wi‑Fi** → **Apply** → wait until Apply finishes.
6. **Do not click Eject** in iTunes (that removes the icon; Wi‑Fi sync can stay on).
7. Unplug USB. Same Wi‑Fi → reopen iTunes → phone icon should reappear in the sidebar within a minute.

**Summary visible but Wi‑Fi sync still fails?**

USB + iTunes Summary working means AMDS is healthy. Wireless discovery is a **second** step — pairing over the LAN.

| Test | Pass | Fail → try below |
|------|------|------------------|
| Unplug USB, same network, reopen **iTunes** (wait 1–2 min) | Phone icon returns | Pairing not saved or LAN blocked |
| iPhone **Settings → General → iTunes Wi‑Fi Sync** | Shows PC name + **Sync Now** | Checkbox never committed — redo USB ritual |
| **AltServer** tray → **Install AltStore** (unplugged) | iPhone in list | Same as iTunes Wi‑Fi fail |

**USB ritual (re-save Wi‑Fi pairing):**

1. USB → unlock → **Trust** → open **iTunes** → phone icon → **Summary**.
2. **Uncheck** “Sync with this [device] over Wi‑Fi” → **Apply** → wait until finished.
3. **Check** it again → **Apply** → wait until finished (do **not** click **Eject**).
4. Leave cable connected **30–60 seconds**, then unplug.
5. Phone on **same Wi‑Fi** as PC, **unlocked**, reopen iTunes.

**Common blockers (Windows 11):**

| Blocker | Fix |
|---------|-----|
| **PC on Ethernet, phone on Wi‑Fi** | Apple documents Wi‑Fi sync as unreliable when the PC is **not on Wi‑Fi** — connect the **PC to the same Wi‑Fi** (or use Plan B USB refresh). |
| **Guest Wi‑Fi / AP isolation** | Use main LAN; disable client isolation on router. |
| **Firewall** | Allow **iTunes**, **Bonjour Service**, **AltServer** on **Private** networks. Open **UDP 5353** (mDNS/Bonjour) and **TCP 3689** ([Apple ports](https://support.apple.com/HT202944)). Restart **Bonjour Service** after firewall changes. |
| **Public network profile** | **Settings → Network** → Wi‑Fi/Ethernet → **Private**. |
| **iPhone Private Wi‑Fi Address** | **Settings → Wi‑Fi → (i) your network** → turn **Private Address** **Off** for home LAN (retry pairing once). |
| **Stale pairing** | Quit iTunes → delete `%ProgramData%\Apple\Lockdown\*` → USB re-trust → repeat USB ritual above. |
| **VPN** | Off on PC and phone during test. |
| **Proxy / Clash / TUN** | **Clash for Windows** (or any system VPN/TUN) blocks **Bonjour/mDNS** (UDP 5353) — phone won’t reappear after USB unplug even on the same Wi‑Fi. **Quit Clash completely** (tray → Exit; confirm `clash-core-service` stopped) or enable **Bypass LAN / Allow LAN** in Clash → retest. Your PC showed **Clash** adapter active alongside **ATT-WIFI** — disable proxy for the pairing test. |

**Phone never reappears after unplug (PC already on Wi‑Fi)?**

Work through in order:

1. **Quit Clash / VPN** on PC (and phone). Restart **Bonjour Service** → reopen iTunes.
2. Confirm iPhone uses the **same SSID** as PC (not guest network); **Private Wi‑Fi Address → Off** on that network.
3. **Stale Lockdown:** quit iTunes → delete contents of `%ProgramData%\Apple\Lockdown\` → USB → **Trust** again → USB ritual (uncheck/check Wi‑Fi → Apply → wait 60s plugged in → unplug).
4. iPhone **Settings → General → iTunes Wi‑Fi Sync** — must list the PC after step 3. If still “connect with cable…”, pairing failed.
5. **Windows Firewall → Allow an app:** enable **iTunes**, **Bonjour**, **AltServer** on **Private**; or temporarily turn firewall off **once** to confirm (turn back on after test).
6. Router: disable **AP isolation / guest mode** for the LAN.

Still no wireless icon → **[Plan B](#plan-b--skip-wi-fi-sync-refresh-over-usb-works-when-checkbox-wont-stick)** (USB refresh weekly).

**Services (if still no Wi‑Fi):** `Win+R` → `services.msc` → **Apple Mobile Device Service** and **Bonjour Service** → Startup type **Automatic** → **Start**.

**Apple Mobile Device Service not in `services.msc`?**

That service is **not** a separate Windows feature — it is installed by **iTunes from Apple’s website** (the full `iTunes64Setup.exe`). The **Microsoft Store** iTunes / **Apple Devices** stack often **does not register** this service, or a partial uninstall removed it while leaving iTunes + USB drivers behind.

**Confirmed:** If AMDS is missing, **repairing or re-running the installer on top of existing iTunes is not enough** — you must **fully uninstall iTunes and related Apple components**, restart, then **reinstall** with `iTunes64Setup.exe` (admin). Only then does **Apple Mobile Device Service** reappear in `services.msc`.

| Check | Healthy | Broken (common) |
|-------|---------|-----------------|
| `services.msc` | **Apple Mobile Device Service** listed | **Missing** |
| `C:\Program Files\Common Files\Apple\Mobile Device Support\` | `AppleMobileDeviceService.exe` present | Only `Drivers\` + `NetDrivers\` (no `.exe`) |
| USB | May still work via `usbaapl64` driver | Wi‑Fi pairing / AltServer LAN detection usually **fail** |

**Fix — full uninstall, then reinstall iTunes stack (admin):**

1. Quit iTunes, iCloud, AltServer. **Do not** open **Apple Devices** after this (it strips AMDS again).
2. **Settings → Apps → Installed apps** — uninstall **all** of these, **in order** (skip any not listed):
   - **Apple Devices**, **Apple Music**, **Apple TV** (Microsoft Store) **first**
   - **iTunes**
   - **Apple Mobile Device Support**
   - **Bonjour**
   - **Apple Application Support** (64-bit)
   - **Apple Application Support** (32-bit)
3. **Restart PC** (required — service registration happens on clean install).
4. Run **`iTunes64Setup.exe`** from [Apple 64-bit download](https://www.apple.com/itunes/download/win64) (**not** Microsoft Store). Right-click → **Run as administrator**.
5. **Restart PC** again. Confirm in `services.msc`: **Apple Mobile Device Service** → **Automatic** → **Running**. File: `C:\Program Files\Common Files\Apple\Mobile Device Support\AppleMobileDeviceService.exe`.
6. Reinstall **[iCloud for Windows](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe)** (Apple direct) → sign in. **iTunes → Account → Authorizations → Deauthorize → Authorize** (AltStore signing).
7. If service still missing after step 5: USB → trust → right-click `C:\Program Files\Common Files\Apple\Mobile Device Support\Drivers\usbaapl64.inf` → **Install** → restart → repeat steps 3–5 (full uninstall first if iTunes was left installed).

**Note:** AltStore **USB install/refresh can still work** without AMDS if signing (iTunes + iCloud) is OK — but **Wi‑Fi device detection** and classic iTunes **Summary** almost always need this service.

**Apple Devices app removes Apple Mobile Device Support (“older version”)?**

Yes — **by design**. The Microsoft Store **Apple Devices** app ships its **own** device stack and, on first launch or update, prompts to remove **Apple Mobile Device Support** / **Apple Mobile Device Service** from the classic **iTunes64Setup.exe** install, calling it an older component.

| Stack | `services.msc` AMDS | iTunes phone icon | Apple Devices Wi‑Fi checkbox | AltStore Wi‑Fi refresh |
|-------|---------------------|-------------------|------------------------------|------------------------|
| **iTunes only** (Apple website) | Usually **yes** | **Yes** | N/A (uninstall Store app) | Best chance |
| **Apple Devices** (Microsoft Store) | **Removed** on install | **No** (crippled iTunes) | USB OK; Wi‑Fi often flaky | Usually **no** |
| **Both installed** | Apple Devices **wins** and strips AMDS | Broken | Broken | Broken |

**You cannot keep both.** For AltStore + optional Wi‑Fi refresh, pick **iTunes-only (Plan A)**:

1. **Uninstall first:** **Apple Devices**, **Apple Music**, **Apple TV** (Microsoft Store) — before or after removing leftover iTunes pieces.
2. **Do not** open / reinstall **Apple Devices** after `iTunes64Setup.exe`.
3. Run **`Downloads\iTunes64Setup.exe`** → **Run as administrator** → restart → confirm **Apple Mobile Device Service** in `services.msc`.
4. Device management: **iTunes** (phone icon → Summary), not Apple Devices.

If you **need** Apple Devices for backups, accept **Plan B (USB refresh only)** — do not expect AMDS or reliable AltStore Wi‑Fi.

### Plan B — Skip Wi‑Fi sync; refresh over USB (works when checkbox won’t stick)

Wi‑Fi pairing is **optional** for AltStore if you refresh **with the cable** ~once a week:

1. **AltServer** running on PC.
2. iPhone **USB** → unlock → **Trust**.
3. Open **AltStore** on the phone → **My Apps → Refresh All** (or refresh **AltStore** first, then Loop Segments).

No iTunes Summary checkbox required for this path. Keep **iCloud for Windows** signed in (helps “data isn’t in the correct format” errors).

### Plan C — Apple Devices checkbox keeps resetting

If you prefer **Apple Devices** over iTunes but **Show this iPhone when on Wi-Fi** won’t stay checked:

1. On iPhone: **Settings → General → Transfer or Reset → Reset → Reset Location & Privacy** (re-trust PC), **or** forget the PC and trust again on next USB plug-in.
2. Quit Apple Devices / iTunes / AltServer.
3. Delete pairing data (if present): `%ProgramData%\Apple\Lockdown\*` (old trust certs) — only if comfortable re-trusting; skip if unsure.
4. Delete `%ProgramData%\Apple Computer\iTunes\adi` → restart PC.
5. USB → Apple Devices → check **Show this iPhone when on Wi-Fi** → **Apply** → leave phone plugged in 30s before unplugging.

If it **still** resets → use **Plan B (USB refresh)** or [Sideloadly fallback](#5-sideloadly-fallback-only-if-altstore-fails).

### Plan D — AltServer still can’t see phone on Wi‑Fi

Unlock iPhone, then restart **Apple Mobile Device Service** (`services.msc` → restart, or admin PowerShell):

```powershell
Restart-Service -Name 'Apple Mobile Device Service' -Force
```

AltServer tray → **Install AltStore** — your phone name should appear in the list when pairing works.

**AltStore install fails?** Accept the agreement at [developer.apple.com](https://developer.apple.com), use a personal Apple ID, turn VPN off, keep AltServer in the tray, use a fresh IPA (build **243+** / **1.2.8+**). Last resort: [Sideloadly fallback](#5-sideloadly-fallback-only-if-altstore-fails).

### 3. Automate weekly refresh (AltServer + AltStore)

AltStore can **re-sign Loop Segments (and itself)** before the free **~7-day** cert expires. This is the **recommended** automation path — no iTunes, no Sideloadly daemon.

**Does AltServer refresh automatically when it sees the iPhone (USB or Wi‑Fi)?**

**No.** AltServer does **not** watch for device connect and re-sign apps by itself.

```text
AltStore (iPhone)  ──requests refresh──►  AltServer (PC)  ──signs──►  apps updated
```

| Path | Who starts refresh | Automatic? |
|------|-------------------|------------|
| **Wi‑Fi** | **AltStore** (background, before expiry) | **Sometimes** — same Wi‑Fi, AltServer running, Background App Refresh on; iOS may delay |
| **USB** | **You** — open AltStore → **My Apps → Refresh All** | **No** — cable only helps AltServer be reachable; no plug-in-and-refresh |

[Register-AltServerAtLogon.ps1](../windows/Register-AltServerAtLogon.ps1) only keeps **AltServer in the tray** at logon; it does not trigger refresh on USB attach. For USB-only refresh without opening AltStore manually, use [Sideloadly fallback](#5-sideloadly-fallback-only-if-altstore-fails) (daemon refreshes on USB when enrolled).

| Piece | Role |
|-------|------|
| **AltServer** (PC tray) | Signs apps when the phone is reachable on the LAN |
| **AltStore** (iPhone) | Requests refresh for installed apps, including **itself** |
| **Same Wi‑Fi** | Phone and PC on one network (refresh does **not** run on cellular-only away from home) |
| **Background App Refresh** | **Settings → AltStore → On** and **Settings → General → Background App Refresh → AltStore → On** |

**One-time setup**

1. **AltServer** running at Windows logon ([Register-AltServerAtLogon.ps1](../windows/Register-AltServerAtLogon.ps1) if the installer did not add it).
2. iPhone **Background App Refresh** enabled for AltStore (above).
3. After install, open AltStore once on Wi‑Fi so it pairs with AltServer.

**What happens automatically**

- When the phone is on the **same Wi‑Fi** as the PC and AltServer is up, AltStore tries to refresh apps **in the background** before expiry.
- **AltStore** and **Loop Segments** both use ~7-day certs — refresh **AltStore first** if you refresh manually (**My Apps → Refresh All**).

**Not 100% guaranteed** on Wi‑Fi (iOS may delay background work; broken pairing). **Reliable habit:** **USB + Refresh All** weekly, or fix Wi‑Fi with [Plan A](#plan-a--classic-itunes-only-try-this-if-you-want-wi-fi-refresh) above.

**If refresh failed / app expired**

1. PC on, AltServer in tray, same Wi‑Fi as phone.
2. AltStore → **Refresh All** (or reinstall **AltStore** from AltServer, then refresh Loop Segments).
3. [Trust developer](#trust-the-developer-on-iphone-required-once-not-weekly) again only if iOS shows **Untrusted Developer** / **Unable to Verify App**.

**AltStore Patreon** (optional, paid to AltStore’s authors) adds more app slots and stronger background refresh; free Apple ID still means **~7-day** Apple certs.

**Refresh failed: “The data couldn’t be read because it isn’t in the correct format”**

Same message on **Install** (My Apps → +) or **Refresh** — almost always **AltServer ↔ Apple login** (invalid *anisette*), **not** a broken Loop Segments IPA. AltStore expected JSON from Apple and got garbage or an HTML error page.

| AltStore error (if shown) | Meaning |
|---------------------------|---------|
| **2013** / **3023** / anisette invalid | iCloud/iTunes from **Microsoft Store**, or not signed in, or stale `adi` cache |
| **1007** / **2007** app invalid format | Rare for our IPA — re-download `LoopSegments.ipa` from GitHub Actions |

### Fix install / refresh — do in order (USB)

| Step | Action |
|------|--------|
| 1 | **Uninstall Microsoft Store** **iCloud** (and Store **iTunes** if present). Install **[iTunes 64-bit](https://www.apple.com/itunes/download/win64)** + **[iCloud](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe)** from **Apple’s website only** ([AltStore FAQ](https://faq.altstore.io/altstore-classic/troubleshooting-guide)) |
| 2 | **Restart PC** after installing. |
| 3 | Open **iCloud for Windows** → sign in → leave it running (tray). **Same Apple ID** as AltStore on the phone. |
| 4 | Open **iTunes** → accept agreement → **Account → Sign In** with that Apple ID. |
| 5 | **iTunes → Account → Authorizations → Deauthorize This Computer** → then **Authorize This Computer**. Quit iTunes. *(Confirmed fix for USB install/refresh “incorrect data format” on Windows 11.)* |
| 6 | Quit AltServer, iTunes, iCloud. Delete **all files** in `%ProgramData%\Apple Computer\iTunes\adi` (not the folder). Restart PC. Sign in **iCloud** + **iTunes** again. |
| 7 | **AltServer** → right-click → **Run as administrator** → allow **private networks** in Windows Firewall. |
| 8 | Phone **USB** → unlock → **Trust** → open **AltStore** on phone (same Apple ID). |
| 9 | Install: **My Apps → +** → `LoopSegments.ipa` (fresh from **Actions → ios-build → Run workflow** if unsure). |

**Still failing?**

| Extra step | Action |
|------------|--------|
| Re-authorize again | Repeat step 5 if you cleared `adi` or reinstalled iTunes after authorizing |
| Services | `services.msc` → **Apple Mobile Device Service** → Automatic + **Running** |
| Date/time | PC and iPhone set to automatic / correct timezone |
| VPN / DNS | Off VPN; try phone on **same Wi‑Fi** as PC during install (USB + Wi‑Fi together is OK) |
| Developer agreement | [developer.apple.com](https://developer.apple.com) → sign in → accept agreement |
| Store iCloud required | If you **must** keep Store iCloud: [AltStore “Windows Store iCloud” workaround](https://faq.altstore.io/altstore-classic/troubleshooting-guide) (copy Apple support folders before swapping) |
| Bypass AltStore sign | Install **Loop Segments** with [Sideloadly](#5-sideloadly-fallback-only-if-altstore-fails) + **Automatic App Refresh** (USB daemon) |

**Verify IPA is OK (only if error code 1007 / 2007):** unzip `LoopSegments.ipa` on PC — should contain `Payload/LoopSegments.app/Info.plist` with `CFBundleIdentifier` = `com.loopsegments.app`. Re-download artifact if corrupt.

If refresh still fails after the above, use [Sideloadly fallback](#5-sideloadly-fallback-only-if-altstore-fails) for install/refresh until AltStore works. Official guide: [AltStore on Windows](https://faq.altstore.io/getting-started/how-to-install-altstore-windows).

### 4. On the phone after install

1. **[Trust the developer](#trust-the-developer-on-iphone-required-once-not-weekly)** if you have not already.
2. **Settings → Cellular → Loop Segments → On** (cellular pCloud export).
3. **iOS 17+** required. **iOS 26.x:** recent IPA (**1.2.8+** / build **243+** on sign-in).

**App opens then closes immediately?** Reinstall **1.0.5+** IPA (not 1.0.4).

**Old build on screen?** **Actions → ios-build → Run workflow** → download **`LoopSegments-ipa`** → reinstall via AltStore.

Then [WORKFLOW.md](../WORKFLOW.md): export → `Sync-FromPhoneLAN.ps1 -Watch` → DLNA on WLAN.

### 5. Sideloadly (fallback only if AltStore fails)

Use only when AltStore cannot install or refresh. Requires **iTunes (64-bit from Apple)** + USB. See [Sideloadly fallback details](#sideloadly-fallback-details) at the end of this doc.

Brief steps: install iTunes → USB **Trust This Computer** → [Sideloadly](https://sideloadly.io) → drag IPA → enable **Automatic App Refresh** → [trust developer](#trust-the-developer-on-iphone-required-once-not-weekly). Optional PC helper: `.\Register-SideloadlyAutoRefresh.ps1 -WatchUsb` (see [windows/README.md](../windows/README.md)).

---

## Refresh the IPA later

Free Apple ID certificates last **~7 days**. See **[§3 Automate weekly refresh](#3-automate-weekly-refresh-altserver--altstore)** (AltStore, primary) before apps stop opening.

### If you don’t refresh in time

| What happens | Details |
|--------------|---------|
| **App won’t open** | Tapping the icon shows “Unable to Verify App” / similar, or the app closes immediately. |
| **Your export files** | Usually **still on the phone** in the app’s Documents until you delete the app — but you can’t run a new export until you reinstall/refresh. |
| **PC / DLNA** | **Unchanged** — files already copied or played from the PC are not affected. |
| **Fix** | **AltStore:** **Refresh All** (AltServer on PC, same Wi‑Fi). If AltStore died, reinstall from AltServer first. [Trust developer](#trust-the-developer-on-iphone-required-once-not-weekly) only if iOS asks. |
| **What does not happen** | No charge from Apple, phone is not locked, app does not auto-update from the App Store. |

| Goal | What to do |
|------|------------|
| **Extend the same install** | **AltStore → Refresh All** on home Wi‑Fi ([§3](#3-automate-weekly-refresh-altserver--altstore)) |
| **New build** | GitHub → **Actions** → **ios-build** → **Run workflow** → **`LoopSegments-ipa`** → reinstall in AltStore |

**Local IPA path (this repo on Windows):**

`ios\build artifacts\ipa\LoopSegments.ipa`

**Download latest artifact with GitHub CLI** (after `gh auth login`):

```powershell
cd P:\all_scripts\ios_3d_loop_segments\ios\build artifacts\ipa
gh run list --workflow=ios-build.yml --limit 1
gh run download <RUN_ID> -n LoopSegments-ipa
```

Use the newest successful **workflow_dispatch** run ID from `gh run list`. Reinstall with **AltStore**.

---

## Sideloadly fallback details

Only if [AltStore](#2-install-with-altstore-primary--windows) fails. Requires **iTunes (64-bit from Apple, not Microsoft Store)** + USB.

#### iTunes setup

1. [64-bit iTunes](https://www.apple.com/itunes/download/win64) → restart PC.
2. USB → **Trust This Computer** → phone visible in iTunes once.
3. Install [Sideloadly](https://sideloadly.io).

**iTunes -45054:** quit iTunes → `%ProgramData%\Apple Computer\iTunes` → delete **`adi`** and **`SC Info`** → restart → sign in again ([Apple HT204649](https://support.apple.com/en-us/HT204649)).

#### Install + auto-refresh (Sideloadly Daemon)

1. Sideloadly → drag **`LoopSegments.ipa`** → sign in with Apple ID.
2. Check **Automatic App Refresh** at install.
3. Sideloadly → Settings → **Daemon** / launch at startup.
4. Optional: `.\Register-SideloadlyAutoRefresh.ps1 -WatchUsb` ([windows/README.md](../windows/README.md)).
5. [Trust developer](#trust-the-developer-on-iphone-required-once-not-weekly).

**Login fails?** Accept agreement at [developer.apple.com](https://developer.apple.com), update Sideloadly, clear `%LOCALAPPDATA%\cache\sideloadly`, try **Anisette → Remote**. Prefer fixing AltStore instead.

---

## Paid Developer Program ($99/year)

Worth it if you want:

| Benefit | Free Apple ID | Paid ($99/yr) |
|---------|---------------|---------------|
| Certificate lifetime | ~7 days | ~1 year |
| TestFlight (install link, no AltStore) | No | Yes |
| Cloud CI signing | Awkward | Straightforward |
| More devices / apps for dev | Tight limits | Higher limits |

### TestFlight path (paid)

1. Enroll at [developer.apple.com/programs](https://developer.apple.com/programs/).
2. Build in **Codemagic** or **GitHub Actions** with App Store Connect API key / distribution cert.
3. Upload to **TestFlight**, install from the TestFlight app on your iPhone.

Details: Codemagic [iOS code signing](https://docs.codemagic.io/yaml-code-signing/signing-ios/), same [codemagic.yaml](../codemagic.yaml).

---

## Build options (all paths)

### Codemagic

1. [codemagic.io](https://codemagic.io) → connect repo.
2. [codemagic.yaml](../codemagic.yaml) runs `xcodegen` (no ffmpeg SPM on iOS 26).
3. Code signing: **free Apple ID** *or* paid team.
4. Download IPA (free/sideload) or publish TestFlight (paid).

### GitHub Actions

[`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml) — **push** runs a simulator smoke build; **Run workflow** produces a device **IPA** artifact (unsigned by default, or signed with Apple ID secrets).

### Cloud Mac (one session)

```bash
brew install xcodegen
cd ios && xcodegen generate && open LoopSegments.xcodeproj
```

**Signing & Capabilities** → Team: your **Personal Team** (free). Archive → export IPA.

---

## Export note

Segment export uses **AVFoundation** on the phone, not embedded ffmpeg (ffmpeg-kit does not load on iOS 26). The Windows side only copies finished `op_*.mp4` files — see [../WORKFLOW.md](../WORKFLOW.md).

---

## After install

[WORKFLOW.md](../WORKFLOW.md): cellular export → `..\windows\Sync-FromPhoneLAN.ps1` → DLNA on WLAN.
