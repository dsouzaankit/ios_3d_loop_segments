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
2. **Windows PC** (SideStore: USB once for iloader; AltStore: same Wi‑Fi / USB for refresh)
3. A **`.ipa`** file (see [Get an IPA without a Mac](#get-an-ipa-without-a-mac) below)
4. **[SideStore nightly](#2a-install-with-sidestore-nightly-preferred-when-altstore-flakes)** — preferred when AltStore hits **incorrect data format** / flaky signing (LocalDevVPN + iloader; no AltServer after setup)
5. **[AltServer + AltStore](#2-install-with-altstore-windows)** — still fine if it works on your PC (iTunes + iCloud from Apple + AltServer)
6. **Last resort:** [Sideloadly fallback](#5-sideloadly-last-resort) (iTunes + USB; app-specific passwords **not** supported; login often fails with −22406 / “incorrect password”)

### Trust the developer on iPhone (required once; not weekly)

After **SideStore**, **AltStore**, or Sideloadly installs the app, iOS blocks it until **you** tap **Trust** in Settings. **Apple does not allow the PC or store app to do this for you** — it is a deliberate security step on the phone.

| When | Trust developer in VPN & Device Management? |
|------|---------------------------------------------|
| **First install** | **Yes — required once** |
| **AltStore auto-refresh succeeds** (same app, same Apple ID, before cert dies) | **Usually no** — app keeps opening |
| **Cert expired** (“Unable to Verify App”) then refresh/reinstall | **Often yes** — trust again if iOS shows the profile or “Untrusted Developer” |
| **New IPA / different Apple ID** | **Yes** |
| **Every USB plug-in** | **No** (that’s only **Trust This Computer**, not the developer) |

**Automatic refresh does not remove the first-time trust step.** It only avoids **weekly manual reinstall** on the PC — not this one-time (or occasional) phone setting.

**iOS Shortcut for Trust?** **No.** Shortcuts cannot tap **Trust** or **Allow & Restart** for you — Apple blocks that on purpose. A shortcut might open **Settings** (prefs URLs are unreliable and change per iOS version), but you still must tap trust yourself. **TestFlight** and **MDM/supervised** work devices are different; sideloaded AltStore/SideStore apps are not.

**iOS Shortcut for SideStore refresh?** **Yes (optional)** — SideStore exposes **Refresh All Apps** to Shortcuts; you can schedule a **Personal Automation**. That is **not** the same as Trust (above). Official docs still document **tap 7 DAYS** + LocalDevVPN; Shortcuts automation is a community/supported app action, not the primary install guide. Setup + caveats: [SideStore Shortcuts auto-refresh](../../env_setup/sidestore/README.md#sidestore-shortcuts-auto-refresh-optional).

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

**One-shot on Windows (preferred):** from the repo root (needs [`gh`](https://cli.github.com/) + `gh auth login` + iCloud for Windows):

```powershell
.\deploy.ps1              # trigger ios-build → download → calls copy-to-icloud.ps1
.\deploy.ps1 -UseLatest   # skip trigger; fetch newest successful workflow_dispatch IPA → copy-to-icloud
.\deploy.ps1 -SkipICloud  # local ios\build artifacts\ipa\ only (no iCloud)
.\deploy.ps1 -SkipPhonePrep      # no USB foreground app quit / LocalDevVPN connect after the trigger
.\deploy.ps1 -SkipUsbInstall     # no USB install at all (install from iCloud Downloads)
.\deploy.ps1 -NoPhoneRestart     # USB install: no phone restart after a failed retry
.\reinstall-latest.ps1     # deploy.ps1 -UseLatest -ForceUsbInstall: newest built IPA, no GitHub build, no bump; installs when its build is the same as or newer than the phone's
.\bump-build.ps1           # build number + 1, commit + push, then deploy.ps1 (new IPA, no app changes; a built IPA newer than the USB phone's build is installed with -UseLatest instead; -DryRun / -NoDeploy / -ForceBump)
.\copy-to-icloud.ps1      # iCloud paste only — unique LoopSegments-b{build}-{time}.ipa (like web_auto_parking)
.\copy-to-icloud.ps1 -FetchIfMissing   # if local IPA missing, gh -UseLatest first then paste
```

**Phone prep:** After it triggers the build, if the iPhone is on **USB**, it connects **LocalDevVPN** if it is not (Loop Segments stays open during the build; the USB install relaunches it for the handover; with `-SkipUsbInstall` the phone is left alone): it launches LocalDevVPN over USB, whose **Auto-connect on launch** setting (switch it on once) connects it, then goes back to the Home Screen (`windows\usb\Prepare-PhoneForSideStoreViaUsb.ps1`; `-SkipPhonePrep` turns it off). No router is touched. **USB install (build 428+ on the phone):** after the download, with the iPhone on USB, `deploy.ps1` first moves the **phone and this PC off the phone LAN** (the `phoneLanHost` /24 from the config): if the phone is on it, it bounces that AP so the phone hops to another saved Wi‑Fi, and the PC joins the phone's new network, because SideStore needs www over Wi‑Fi to sign and the phone LAN Wi‑Fi has no gateway (LAN only; the app prefers 5G for internet). This is the opposite of the web companion, which needs both **on** the phone LAN; nothing moves them back after the install: the phone usually rejoins the phone LAN by itself once that AP's Wi‑Fi is back (iOS auto-join prefers it, typically when the phone wakes), and the companion's start-up network check moves the PC, and the phone if still needed — or run **`windows\lan\Invoke-LoopSegmentsCompanionWifiReorientAfterIpa.ps1`** (gateway align + phone LAN recover; USB-foregrounds the app if `:8765` is still down). Pin the network with `ipaInstallWifiProfile` (empty = each saved profile off that subnet, those in range first: Windows' in-range list is often stale). It then serves the IPA once on that network (`http://<PC IP>:8766/<random>/LoopSegments.ipa`, plain TCP listener, no admin) and launches Loop Segments over USB with `-openURL sidestore://install?url=…`. The app opens that link and quits, SideStore shows **Install**: **tap it** (the only manual step). The script waits until the phone reports the new build, then switches **LocalDevVPN back off if this deploy switched it on** (left on if the install is not confirmed). `windows\usb\Install-LoopSegmentsIpaViaUsb.ps1`; Each try first quits SideStore and restarts LocalDevVPN (tunnel and app, about 12 s), so SideStore starts fresh with a new tunnel. Only the handover launches Loop Segments, so with a Face ID lock on it you confirm once per try. A failed install is retried once, then (unless `-NoPhoneRestart`) the phone is restarted over USB — the best fix for SideStore errors other than an offline LocalDevVPN — and after you unlock it, tried a last time. `-SkipUsbInstall` turns it off. The iCloud copy is still made as a fallback.

**PC-signed USB install (tried first, no tap):** when it is set up on this PC (`windows\setup\Set-LoopSegmentsSigning.ps1`: zsign, SideStore's exported certificate in `..\env_setup\zsign\signing.p12`, its password in Credential Manager; the PC setup runs it), the USB install signs the IPA on the PC with that certificate and the phone's newest profile, then installs it over USB in a few seconds. None of the Wi‑Fi moves, LocalDevVPN or Install tap above happen then. The phone prep also skips LocalDevVPN when the signing check passes, and a fallback to SideStore connects it first. Otherwise it falls back to the flow above. Setup, profile expiry and troubleshooting: [windows/README.md → PC-signed USB install](../windows/README.md#pc-signed-usb-install-zsign-no-install-tap).

**USB install notes:** SideStore's pop-up *"Some sources were unable to load"* is harmless here: the install link does not use sources, and since every try starts SideStore fresh it reloads them (the **Sources** tab shows which one failed). It only matters if **all** sources fail, which means SideStore had no internet, and then signing fails too. LocalDevVPN: when a deploy in the last 3 hours switched it on and could not switch it back off (e.g. it timed out), the next deploy switches it off at the end, even though it was on when that deploy started, so the VPN ends as it was before the first attempt.

**`deploy.ps1` reuses `copy-to-icloud.ps1`** for the iCloud step (unless `-SkipICloud`). That helper prunes older `LoopSegments*.ipa` in iCloud Downloads, then copies a **new stamped name** so Files refreshes reliably. Optional override: set **`iCloudDownloads`** in `windows\loop-segments-windows.json`.

**Manual:**

1. Push this repo to **GitHub** (public repos get **unlimited** macOS runner time; private repos share ~2,000 min/month on the free plan).
2. Open the repo → **Actions** → **ios-build** → **Run workflow** (manual run builds the IPA; pushes only run the simulator smoke test).
3. When the run finishes, open the run → **Artifacts** → download **`LoopSegments-ipa`** → unzip → `LoopSegments.ipa`.  
   On this PC you can keep it at `ios\build artifacts\ipa\LoopSegments.ipa` (see [Refresh the IPA later](#refresh-the-ipa-later)), or copy to iCloud Drive → Downloads for AltStore on the phone.
4. Install with [SideStore nightly](#2a-install-with-sidestore-nightly-preferred-when-altstore-flakes) or [AltStore](#2-install-with-altstore-windows).

**Signing on GitHub (optional)**

| Mode | Secrets | Use when |
|------|---------|----------|
| **Unsigned IPA** (default) | none | Re-sign in **SideStore** / **AltStore** with your Apple ID |
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

### 2a. Install with SideStore nightly (preferred when AltStore flakes)

**SideStore setup and troubleshooting** (LocalDevVPN, iloader, free 3-app slots, **incorrect data format**, ping unreachable, 0.7.0 errors, the Nov 2026 **sign-in 503**, iloader reinstall / pairing, Shortcuts auto-refresh) lives in the shared repo: **[../env_setup/sidestore/README.md](../../env_setup/sidestore/README.md)**. Below: Loop Segments only.

Confirmed here: **nightly** fixed the **incorrect data format** that stable and AltStore hit. Keep Loop Segments and Parking as normal sideloaded apps (not LiveContainer guests — background / LAN / Keep Alive need a real install).

**Install Loop Segments:**

1. Put a **fully local** `LoopSegments.ipa` on the phone (wait out iCloud stubs; or USB / Safari download).
2. LocalDevVPN → **Connect**.
3. **SideStore → My Apps → +** → pick the IPA (or Files → Share → SideStore).
4. [Trust developer](#trust-the-developer-on-iphone-required-once-not-weekly) if prompted.
5. Refresh: tap the **7 DAYS** counter (LocalDevVPN still on). **No PC** for weekly refresh or after expiry — PC only if the pairing file dies (iloader). Optional: [Shortcuts auto-refresh](../../env_setup/sidestore/README.md#sidestore-shortcuts-auto-refresh-optional) instead of remembering the tap.

**Install hangs on an existing Loop Segments (update):** SideStore often stalls forever when installing a new IPA **over** the app already on the phone. Try this order (LocalDevVPN on; IPA fully local):

1. **Force-quit Loop Segments** (App Switcher → swipe away) — often unblocks **My Apps → +** without wiping data.
2. If it still hangs: **Delete** Loop Segments from the home screen, then **My Apps → +** again. Same Apple ID keeps the App ID slot; **on-device app data is wiped** (re-export / restore media from PC/`archive` if needed).

This is different from [re-linking after a SideStore reinstall](../../env_setup/sidestore/README.md#reinstall-or-update-sidestore-with-iloader) — there, prefer install-over so data stays.

**PC-signed USB install** (`windows\usb\Install-LoopSegmentsIpaViaUsb.ps1`: the shared [`..\env_setup\zsign`](../../env_setup/zsign/README.md) kit: zsign + `signing.p12` exported from SideStore) installs without a tap but **cannot refresh**: it reuses the newest profile already on the phone. Only a SideStore sign-in renews the 7-day profile — if that fails, see [sign-in 503](../../env_setup/sidestore/README.md#apple-id-sign-in-fails-with-http-503-since-2026-11-20), and never let SideStore revoke the certificate.

---

### 2. Install with AltStore (Windows)

**AltStore + AltServer setup and troubleshooting** (iTunes + iCloud from Apple, Wi‑Fi sync Plans A–D, Apple Mobile Device Service, weekly refresh, UDID 1006, “incorrect format”, the fix-in-order checklist) lives in the shared repo: **[../env_setup/altserver_refresh/ALTSTORE.md](../../env_setup/altserver_refresh/ALTSTORE.md)**. Below: Loop Segments only.

1. Set up AltServer + AltStore on the PC and phone ([steps](../../env_setup/altserver_refresh/ALTSTORE.md#install-with-altstore-windows)); optional tray at logon: [Register-AltServerAtLogon.ps1](../windows/sideload/Register-AltServerAtLogon.ps1).
2. On the **iPhone**: **AltStore → My Apps → +** → select **`LoopSegments.ipa`** (fully synced from iCloud Downloads). Not **AltServer → Sideload .ipa** on the PC: that leaves it out of My Apps, so no refresh ([why](../../env_setup/altserver_refresh/ALTSTORE.md#app-not-in-altstore--my-apps)).
3. [Trust the developer on iPhone](#trust-the-developer-on-iphone-required-once-not-weekly).

**Verify IPA is OK (only if error code 1007 / 2007):** unzip `LoopSegments.ipa` on PC — should contain `Payload/LoopSegments.app/Info.plist` with `CFBundleIdentifier` = `com.loopsegments.app`. Re-download artifact if corrupt.

### 3. Automate weekly refresh (AltServer + AltStore)

AltStore → **My Apps → Refresh All** (USB, AltServer running) re-signs Loop Segments and AltStore; background Wi‑Fi refresh is flaky on Windows 11. Details: [shared guide](../../env_setup/altserver_refresh/ALTSTORE.md#automate-weekly-refresh-altserver--altstore).

### 4. On the phone after install

1. **[Trust the developer](#trust-the-developer-on-iphone-required-once-not-weekly)** if you have not already.
2. **Settings → Cellular → Loop Segments → On** (cellular pCloud export).
3. **iOS 17+** required. **iOS 26.x:** recent IPA (**1.2.8+** / build **243+** on sign-in).

**App opens then closes immediately?** Reinstall **1.0.5+** IPA (not 1.0.4).

**Old build on screen?** **Actions → ios-build → Run workflow** → download **`LoopSegments-ipa`** → reinstall via AltStore.

Then [WORKFLOW.md](../WORKFLOW.md): export → `Sync-FromPhoneLAN.ps1 -Watch` → DLNA on WLAN.

### 5. Sideloadly (last resort)

Use only when SideStore and AltStore cannot install or refresh. Requires **iTunes (64-bit from Apple)** + USB. See [Sideloadly fallback details](#sideloadly-fallback-details) at the end of this doc.

Brief steps: install iTunes → USB **Trust This Computer** → [Sideloadly](https://sideloadly.io) → drag IPA → enable **Automatic App Refresh** → [trust developer](#trust-the-developer-on-iphone-required-once-not-weekly). Optional PC helper: `.\sideload\Register-SideloadlyAutoRefresh.ps1 -WatchUsb` (see [windows/README.md](../windows/README.md)).

**Login / −22406 / “incorrect password”:** Sideloadly does **not** support app-specific passwords — use the normal Apple ID password + 2FA when prompted. If the browser login works but Sideloadly still rejects the password, that is Sideloadly’s anisette/login bug — use SideStore nightly or AltStore instead.

---

## Refresh the IPA later

Free Apple ID certificates last **~7 days**. Prefer **SideStore** (LocalDevVPN + Refresh, or optional [Shortcuts Automation](../../env_setup/sidestore/README.md#sidestore-shortcuts-auto-refresh-optional)) or **[§3 Automate weekly refresh](#3-automate-weekly-refresh-altserver--altstore)** (AltStore) before apps stop opening.

### If you don’t refresh in time

| What happens | Details |
|--------------|---------|
| **App won’t open** | Tapping the icon shows “Unable to Verify App” / similar, or the app closes immediately. |
| **Your export files** | Usually **still on the phone** in the app’s Documents until you delete the app — but you can’t run a new export until you reinstall/refresh. |
| **PC / DLNA** | **Unchanged** — files already copied or played from the PC are not affected. |
| **Fix** | **SideStore:** LocalDevVPN on → Refresh. **AltStore:** **Refresh All** (AltServer on PC). If the store app itself died, reinstall it first (iloader / AltServer). [Trust developer](#trust-the-developer-on-iphone-required-once-not-weekly) only if iOS asks. |
| **What does not happen** | No charge from Apple, phone is not locked, app does not auto-update from the App Store. |

| Goal | What to do |
|------|------------|
| **Extend the same install** | **SideStore** Refresh (LocalDevVPN; optional [Shortcuts Automation](../../env_setup/sidestore/README.md#sidestore-shortcuts-auto-refresh-optional)) or **AltStore → Refresh All** ([§3](#3-automate-weekly-refresh-altserver--altstore)) |
| **New build** | Repo root: **`.\deploy.ps1`** (or Actions → **ios-build** → **Run workflow**) → wait for iCloud sync → reinstall in SideStore / AltStore |

**Local IPA path (this repo on Windows):**

`ios\build artifacts\ipa\LoopSegments.ipa`

**iCloud path (after `deploy.ps1` / `copy-to-icloud.ps1`):**

`%USERPROFILE%\iCloudDrive\Downloads\LoopSegments-b{build}-{yyyyMMdd-HHmmss}.ipa`  
(older `LoopSegments*.ipa` in that folder are removed first)

**Download latest artifact with GitHub CLI** (after `gh auth login`) — or just `.\deploy.ps1 -UseLatest`:

```powershell
cd "P:\all_scripts\iOS apps\ios_3d_loop_segments"
.\deploy.ps1 -UseLatest
# manual equivalent:
# cd "ios\build artifacts\ipa"
# gh run list --workflow=ios-build.yml --event=workflow_dispatch --status=success --limit 1
# gh run download <RUN_ID> -n LoopSegments-ipa
```

Reinstall with **SideStore** or **AltStore** after iCloud finishes syncing the IPA on the phone.

---

## Sideloadly fallback details

Only if [SideStore](#2a-install-with-sidestore-nightly-preferred-when-altstore-flakes) and [AltStore](#2-install-with-altstore-windows) fail. Requires **iTunes (64-bit from Apple, not Microsoft Store)** + USB.

#### iTunes setup

1. [64-bit iTunes](https://www.apple.com/itunes/download/win64) → restart PC.
2. USB → **Trust This Computer** → phone visible in iTunes once.
3. Install [Sideloadly](https://sideloadly.io).

**iTunes -45054:** quit iTunes → `%ProgramData%\Apple Computer\iTunes` → delete **`adi`** and **`SC Info`** → restart → sign in again ([Apple HT204649](https://support.apple.com/en-us/HT204649)).

#### Install + auto-refresh (Sideloadly Daemon)

1. Sideloadly → drag **`LoopSegments.ipa`** → sign in with Apple ID.
2. Check **Automatic App Refresh** at install.
3. Sideloadly → Settings → **Daemon** / launch at startup.
4. Optional: `.\sideload\Register-SideloadlyAutoRefresh.ps1 -WatchUsb` ([windows/README.md](../windows/README.md)).
5. [Trust developer](#trust-the-developer-on-iphone-required-once-not-weekly).

**Login fails (−22406 / incorrect password)?** Sideloadly does **not** support app-specific passwords. Accept agreement at [developer.apple.com](https://developer.apple.com), update Sideloadly, clear `%LOCALAPPDATA%\cache\sideloadly`, try **Anisette → Remote**. Prefer **SideStore nightly** or AltStore instead.

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
