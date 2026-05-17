https://github.com/dsouzaankit/ios_3d_loop_segments/actions/workflows/ios-build.yml

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

1. **Free Apple ID** ([appleid.apple.com](https://appleid.apple.com)) — not the paid Developer Program
2. **Windows PC** + USB cable (same PC you use for `Sync-IphoneSegments.ps1`)
3. **iTunes** from Apple’s website (required for **Sideloadly** — see below; not the Microsoft Store app)
4. A signed **`.ipa`** file (see [Get an IPA without a Mac](#get-an-ipa-without-a-mac) below)
5. **Sideloadly** or **AltStore** on Windows

### 1. Get an IPA without a Mac

Pick one:

**A — GitHub Actions (free macOS minutes)**  

1. Push this repo to **GitHub** (public repos get **unlimited** macOS runner time; private repos share ~2,000 min/month on the free plan).
2. Open the repo → **Actions** → **ios-build** → **Run workflow** (manual run builds the IPA; pushes only run the simulator smoke test).
3. When the run finishes, open the run → **Artifacts** → download **`LoopSegments-ipa`** → unzip → `LoopSegments.ipa`.  
   On this PC you can keep it at `ios\build artifacts\ipa\LoopSegments.ipa` (see [Refresh the IPA later](#refresh-the-ipa-later)).
4. Install on Windows with [Sideloadly](#3-install-with-sideloadly-simple-on-windows) (install [iTunes](#2-install-itunes-on-windows-before-sideloadly) first).

**Signing on GitHub (optional)**

| Mode | Secrets | Use when |
|------|---------|----------|
| **Unsigned IPA** (default) | none | You will re-sign in Sideloadly with your own Apple ID |
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

### 2. Install iTunes on Windows (before Sideloadly)

Sideloadly uses Apple’s USB drivers from **iTunes**. Without it, login often fails (“incorrect password”) or the phone won’t appear.

1. Download **iTunes for Windows** from Apple (pick one):
   - [64-bit Windows](https://www.apple.com/itunes/download/win64) (most PCs)
   - [32-bit Windows](https://www.apple.com/itunes/download/win32) (only if your PC is 32-bit)
2. Run the installer. **Do not** install iTunes from the **Microsoft Store** — use Apple’s link above.
3. Optional but helpful: during setup, also install **iCloud for Windows** if the installer offers it.
4. Restart the PC after install.
5. Plug in the iPhone (USB), unlock it, tap **Trust** on the phone, enter your passcode.
6. Open **iTunes** once — confirm the phone shows up (small phone icon). You don’t need to sync music; seeing the device is enough. Close iTunes.
7. **Optional:** **Account → Sign In** in iTunes (same Apple ID). If you see **error -45054** or **-42110**, fix that first ([below](#itunes-store-error--45054-or--42110)) — Sideloadly can still work if the phone appears in iTunes without Store sign-in.
8. Install [Sideloadly](https://sideloadly.io), then continue below.

#### iTunes Store error -45054 or -42110

Apple’s fix when iTunes says *“We could not complete your iTunes Store request… (-45054)”* ([Apple HT204649](https://support.apple.com/en-us/HT204649)):

1. Quit iTunes.
2. Press **Win+R**, type `%ProgramData%`, press Enter.
3. Turn on **hidden items** (File Explorer → **View** → **Hidden items**).
4. Open **Apple Computer** → **iTunes**.
5. Delete folders **`adi`** and **`SC Info`** (if present).
6. **Restart** the PC.
7. Open iTunes → try **Account → Sign In** again.

If folders are missing or error persists: uninstall iTunes (and **Apple Mobile Device Support** / **Bonjour** if offered), reinstall from [Apple’s 64-bit iTunes](https://www.apple.com/itunes/download/win64) (not Microsoft Store), restart, retry. Correct **date/time** on PC and iPhone.

You do **not** need to buy anything in the Store — sign-in only checks that the PC accepts your Apple ID.

**Later:** For USB file copy in [WORKFLOW.md](../WORKFLOW.md), Windows may use **Apple Devices** instead of iTunes — that’s separate. Sideloadly still needs classic iTunes drivers from step 1–2.

### 3. Install with Sideloadly (simple on Windows)

1. Connect iPhone (USB), unlock, **Trust** the computer (again if asked).
2. On iPhone: **Settings → General → VPN & Device Management** — you will trust the app here after install.
3. Open Sideloadly → select the device → drag **`LoopSegments.ipa`**.
4. Sign in with your **free Apple ID** when asked — use your **normal Apple ID password** (the same one as [appleid.apple.com](https://appleid.apple.com)). **Do not** use an [app-specific password](https://appleid.apple.com) here; Sideloadly only supports those for **paid** developer accounts.
5. If you use **two-factor authentication**, keep the iPhone unlocked — approve the sign-in and enter the **6-digit code** on the PC if Sideloadly asks.
6. Install. If prompted, enter the Apple ID again on the phone.

**Before the app stops opening (~7 days):** run Sideloadly again with the same IPA (or use “Refresh” if the tool offers it). Same steps as install.

**Sideloadly “Apple ID or password is incorrect”** (password works in a browser):

The browser only checks your password. Sideloadly also talks to Apple’s **developer / device** servers and needs iTunes drivers + a one-time developer agreement. Do these **in order**:

1. **Update Sideloadly** to the latest from [sideloadly.io](https://sideloadly.io) (0.60+ fixes many login issues).
2. **Apple Developer (free)** — open [developer.apple.com](https://developer.apple.com) → sign in with the **same** Apple ID → accept the **Apple Developer Agreement** if prompted (no $99 payment required for a personal team).
3. **iTunes** — [64-bit installer](https://www.apple.com/itunes/download/win64) (not Microsoft Store) → restart PC → USB phone → **Trust** → phone visible in iTunes. If **Account → Sign In** fails with **-45054**, follow [iTunes -45054 fix](#itunes-store-error--45054-or--42110) (delete `adi` + `SC Info` under `%ProgramData%\Apple Computer\iTunes`).
4. **Clear Sideloadly cache** — quit Sideloadly → delete folder `%LOCALAPPDATA%\cache\sideloadly` → reopen Sideloadly.
5. **2FA** — unlock iPhone; when sideloading, watch for **Allow** on the phone and a **6-digit code** field in Sideloadly (easy to miss behind the window).
6. **Anisette** — try **Remote**, then **Local** (Advanced). Use normal password, not app-specific.
7. **Retry** — same IPA, retype password (no paste). VPN off. Use the exact email from [appleid.apple.com](https://appleid.apple.com).

| Still failing? | |
|----------------|--|
| Hide My Email (`@privaterelay.appleid.com`) | Use the real Apple ID email in Sideloadly |
| Work/school / child Apple ID | Won’t work — use a personal adult account |
| Windows Defender | Allow Sideloadly; it may quarantine the IPA cache |
| **Plan B** | [AltStore](#4-or-altstore-windows) on Windows (same 7-day refresh idea) |

Quick reference:

| Check | Action |
|--------|--------|
| Password type | **Normal** Apple ID password, not app-specific |
| Apple ID | Full email exactly as on [appleid.apple.com](https://appleid.apple.com) |
| iTunes | Web installer + **sign in inside iTunes** once |
| Developer site | [developer.apple.com](https://developer.apple.com) — accept agreement |

**Sideloadly “Guru Meditation” / `CFBundleIdentifier`:** The IPA must contain `CFBundleIdentifier` and `CFBundleExecutable` in the app’s `Info.plist`. Older CI builds before May 2026 omitted these — **rebuild** (Actions → **ios-build** → **Run workflow**) and download a new `LoopSegments.ipa`. If the error persists with a new IPA, in Sideloadly **Advanced → Anisette → Remote** (not Local) and retry.

### 4. Or: AltStore (Windows)

1. Install [AltServer for Windows](https://altstore.io) (tray app on PC).
2. iPhone and PC on the **same Wi‑Fi** (or USB per AltStore docs).
3. Install **AltStore** on the phone from AltServer.
4. Copy the IPA to the phone (Files / cloud) and open with AltStore, or use AltStore’s install flow for IPAs.
5. Refresh in AltStore **before the 7-day expiry** (PC with AltServer running).

### 5. On the phone after install

- **Settings → Cellular → Loop Segments → On** (cellular pCloud export).
- **Settings → General → VPN & Device Management → Trust** the developer profile if the app won’t open.
- **iOS 17 or newer** required (app won’t run on iOS 16). **iOS 26.x** (including **26.5**): use IPA **1.0.5+** to launch (no embedded FFmpeg). For **export + logs**, sideload **1.1.0** (see version on sign-in screen).

**App opens then closes immediately (no sign-in screen)?** Sideload **1.0.5+** (not 1.0.4 or older with ffmpeg-kit).

**Still shows Build 1.0.5?** GitHub IPA was not rebuilt — push latest `main` and run **Actions → ios-build → Run workflow**, then reinstall the new artifact.

Then follow [WORKFLOW.md](../WORKFLOW.md): export → USB → `Sync-IphoneSegments.ps1` → DLNA on WLAN.

---

## Refresh the IPA later

Free Apple ID certificates last **~7 days**. Refresh **before** the app fails to open.

| Goal | What to do |
|------|------------|
| **Extend the same install** | Sideloadly → same `LoopSegments.ipa` → install or **Refresh** (no GitHub build needed) |
| **New build** (app or workflow changed) | GitHub → **Actions** → **ios-build** → **Run workflow** → download **`LoopSegments-ipa`** |

**Local IPA path (this repo on Windows):**

`ios\build artifacts\ipa\LoopSegments.ipa`

**Download latest artifact with GitHub CLI** (after `gh auth login`):

```powershell
cd P:\all_scripts\ios_3d_loop_segments\ios\build artifacts\ipa
gh run list --workflow=ios-build.yml --limit 1
gh run download <RUN_ID> -n LoopSegments-ipa
```

Use the newest successful **workflow_dispatch** run ID from `gh run list`. Then install with Sideloadly.

---

## Paid Developer Program ($99/year)

Worth it if you want:

| Benefit | Free Apple ID | Paid ($99/yr) |
|---------|---------------|---------------|
| Certificate lifetime | ~7 days | ~1 year |
| TestFlight (install link, no Sideloadly) | No | Yes |
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

Segment export uses **AVFoundation** on the phone, not embedded ffmpeg (ffmpeg-kit does not load on iOS 26). The Windows side only copies finished `3d_op_*.mp4` files — see [../WORKFLOW.md](../WORKFLOW.md).

---

## After install

[WORKFLOW.md](../WORKFLOW.md): cellular export → USB → `..\windows\Sync-IphoneSegments.ps1` → DLNA on WLAN.
