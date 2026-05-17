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
3. A signed **`.ipa`** file (see [Get an IPA without a Mac](#get-an-ipa-without-a-mac) below)
4. **Sideloadly** or **AltStore** on Windows

### 1. Get an IPA without a Mac

Pick one:

**A — GitHub Actions (free macOS minutes)**  

1. Push this repo to **GitHub** (public repos get **unlimited** macOS runner time; private repos share ~2,000 min/month on the free plan).
2. Open the repo → **Actions** → **ios-build** → **Run workflow** (manual run builds the IPA; pushes only run the simulator smoke test).
3. When the run finishes, open the run → **Artifacts** → download **`LoopSegments-ipa`** → unzip → `LoopSegments.ipa`.  
   On this PC you can keep it at `ios\build artifacts\ipa\LoopSegments.ipa` (see [Refresh the IPA later](#refresh-the-ipa-later)).
4. Install on Windows with [Sideloadly](#2-install-with-sideloadly-simple-on-windows) (it re-signs with **your** free Apple ID).

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

### 2. Install with Sideloadly (simple on Windows)

1. Install [Sideloadly](https://sideloadly.io) on the PC.
2. Connect iPhone (USB), unlock, **Trust** the computer.
3. On iPhone: **Settings → General → VPN & Device Management** — you will trust the app here after install.
4. Open Sideloadly → select the device → drag **`LoopSegments.ipa`**.
5. Sign in with your **free Apple ID** when asked.
6. Install. If prompted, enter the Apple ID again on the phone.

**Before the app stops opening (~7 days):** run Sideloadly again with the same IPA (or use “Refresh” if the tool offers it). Same steps as install.

**Sideloadly “Guru Meditation” / `CFBundleIdentifier`:** The IPA must contain `CFBundleIdentifier` and `CFBundleExecutable` in the app’s `Info.plist`. Older CI builds before May 2026 omitted these — **rebuild** (Actions → **ios-build** → **Run workflow**) and download a new `LoopSegments.ipa`. If the error persists with a new IPA, in Sideloadly **Advanced → Anisette → Remote** (not Local) and retry.

### 3. Or: AltStore (Windows)

1. Install [AltServer for Windows](https://altstore.io) (tray app on PC).
2. iPhone and PC on the **same Wi‑Fi** (or USB per AltStore docs).
3. Install **AltStore** on the phone from AltServer.
4. Copy the IPA to the phone (Files / cloud) and open with AltStore, or use AltStore’s install flow for IPAs.
5. Refresh in AltStore **before the 7-day expiry** (PC with AltServer running).

### 4. On the phone after install

- **Settings → Cellular → Loop Segments → On** (cellular pCloud export).
- **Settings → General → VPN & Device Management → Trust** the developer profile if the app won’t open.

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
2. [codemagic.yaml](../codemagic.yaml) runs `xcodegen` + **ffmpeg-kit** SPM.
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

## ffmpeg-kit note

The project uses [ffmpeg-kit-spm](https://github.com/tylerjonesio/ffmpeg-kit-spm) (**min** build). If export fails with a missing muxer, switch `ios/project.yml` to a **full** FFmpeg-Kit binary (see [ios/README.md](README.md)).

---

## After install

[WORKFLOW.md](../WORKFLOW.md): cellular export → USB → `..\windows\Sync-IphoneSegments.ps1` → DLNA on WLAN.
