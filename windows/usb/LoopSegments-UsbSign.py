#!/usr/bin/env python3
"""Sign LoopSegments.ipa on this PC with SideStore's certificate and install it over USB (no tap).

Used by Install-LoopSegmentsIpaViaUsb.ps1 before it falls back to the SideStore link. Prints one
result line (tab separated) as the last line of output.

  check <p12> <cred target>
      -> READY <bundle id> <profile UUID> <profile expiry, UTC> <cert expiry, UTC>
       | NO_P12 | NO_PASSWORD | BAD_P12 <why> | NOT_INSTALLED | NO_PROFILE <why> | NO_DEVICE <why> | ERROR <why>
  sign-install <ipa> <zsign.exe> <p12> <cred target> <work dir>
      -> INSTALLED <bundle id> | (any of the above) | SIGN_FAILED <why> | INSTALL_FAILED <why>

The certificate: SideStore → Settings → Export Signing Certificate... (the .p12 iloader gave it). Its
password lives in Windows Credential Manager as a generic credential (cmdkey /generic:<target> ...).
The profile: the newest unexpired one on the phone for the installed bundle id (SideStore renews it
on every refresh, so it is read from the phone each time) that lists this certificate and this phone.
The installed bundle id is kept (SideStore adds .TEAMID), and the Info.plist gets the keys SideStore
adds when it signs (sidestore-<bundle id> URL scheme, io.sidestore.Installed.<bundle id> exported
type, ALTBundleIdentifier, ...), so SideStore still
sees the app as its own and keeps it in My Apps.
"""

from __future__ import annotations

import asyncio
import ctypes
import datetime as dt
import os
import subprocess
import sys
from ctypes import wintypes

from loopsegments_dvt import is_no_device, resolve_bundle_id

INSTALL_TIMEOUT_S = 120


def read_credential(target: str) -> str | None:
    """Password of a generic credential in Windows Credential Manager (cmdkey stores UTF-16)."""

    class CREDENTIAL(ctypes.Structure):
        _fields_ = [
            ("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
            ("Comment", wintypes.LPWSTR), ("LastWritten", wintypes.FILETIME),
            ("CredentialBlobSize", wintypes.DWORD), ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
            ("Persist", wintypes.DWORD), ("AttributeCount", wintypes.DWORD),
            ("Attributes", ctypes.c_void_p), ("TargetAlias", wintypes.LPWSTR),
            ("UserName", wintypes.LPWSTR),
        ]

    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    pcred = ctypes.POINTER(CREDENTIAL)()
    if not advapi.CredReadW(target, 1, 0, ctypes.byref(pcred)):  # 1 = CRED_TYPE_GENERIC
        return None
    try:
        blob = ctypes.string_at(pcred.contents.CredentialBlob, pcred.contents.CredentialBlobSize)
    finally:
        advapi.CredFree(pcred)
    try:
        return blob.decode("utf-16-le")
    except UnicodeDecodeError:
        return blob.decode("utf-8", "replace")


def load_p12(path: str, password: str):
    """-> (cert DER, team id, cert expiry). Raises ValueError on a wrong password or a bad file."""
    from cryptography.hazmat.primitives.serialization import Encoding, pkcs12
    from cryptography.x509.oid import NameOID

    with open(path, "rb") as f:
        data = f.read()
    _key, cert, _extra = pkcs12.load_key_and_certificates(data, password.encode("utf-8"))
    if cert is None:
        raise ValueError("no certificate in the .p12")
    ou = cert.subject.get_attributes_for_oid(NameOID.ORGANIZATIONAL_UNIT_NAME)
    team = ou[0].value if ou else ""
    return cert.public_bytes(Encoding.DER), team, cert.not_valid_after_utc


def utc(value) -> dt.datetime:
    return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)


async def prepare(p12: str, target: str):
    """-> (result line, context dict or None). Context: bundle, team, profile bytes, password."""
    if not os.path.isfile(p12):
        return f"NO_P12\t{p12}", None
    password = read_credential(target)
    if password is None:
        return f"NO_PASSWORD\t{target}", None
    try:
        cert_der, team, cert_exp = load_p12(p12, password)
    except Exception as exc:  # noqa: BLE001
        return f"BAD_P12\t{type(exc).__name__}: {exc}", None
    now = dt.datetime.now(dt.timezone.utc)
    if cert_exp <= now:
        return f"BAD_P12\tcertificate expired {cert_exp:%Y-%m-%d}", None

    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.misagent import MisagentService

    try:
        bundle = await resolve_bundle_id("com.loopsegments.app", "Loop Segments")
        if not bundle:
            return "NOT_INSTALLED", None
        lockdown = await create_using_usbmux()
        try:
            udid = lockdown.udid
            async with MisagentService(lockdown) as mis:
                profiles = await mis.copy_all()
        finally:
            try:
                await lockdown.close()
            except Exception:  # noqa: BLE001
                pass
    except Exception as exc:  # noqa: BLE001
        msg = f"{type(exc).__name__}: {exc}"
        return ("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg, None

    want_app_id = f"{team}.{bundle}"
    for_app = [p for p in profiles
               if (p.plist.get("Entitlements") or {}).get("application-identifier") == want_app_id]
    if not for_app:
        return f"NO_PROFILE\tnone on the phone for {want_app_id} (is the .p12 from this SideStore?)", None
    with_cert = [p for p in for_app if cert_der in (p.plist.get("DeveloperCertificates") or [])]
    if not with_cert:
        return ("NO_PROFILE\tthe phone's profiles for this app list another certificate "
                "(export it again from SideStore)"), None
    usable = [p for p in with_cert
              if utc(p.plist["ExpirationDate"]) > now + dt.timedelta(hours=1)
              and udid in (p.plist.get("ProvisionedDevices") or [])]
    if not usable:
        return "NO_PROFILE\tthe profile has expired - refresh Loop Segments in SideStore first", None
    best = max(usable, key=lambda p: utc(p.plist["ExpirationDate"]))
    exp = utc(best.plist["ExpirationDate"])
    line = (f"READY\t{bundle}\t{best.plist.get('UUID', '')}\t{exp:%Y-%m-%d %H:%M}"
            f"\t{cert_exp:%Y-%m-%d}")
    return line, {"bundle": bundle, "profile": best.buf, "password": password}


def add_sidestore_markers(ipa: str, bundle: str, work: str) -> str:
    """Unpack the IPA to work/Payload/<app> with the Info.plist keys SideStore adds when it signs, and
    return the .app path (zsign signs the folder). Without the `sidestore-<bundle id>` URL scheme,
    SideStore's installed check (canOpenURL) treats the app as deleted and drops it from My Apps."""
    import plistlib
    import shutil
    import zipfile

    root = os.path.join(work, "unpacked")
    shutil.rmtree(root, ignore_errors=True)
    with zipfile.ZipFile(ipa) as z:
        z.extractall(root)
    payload = os.path.join(root, "Payload")
    apps = [d for d in os.listdir(payload) if d.endswith(".app")]
    if len(apps) != 1:
        raise ValueError(f"expected one .app in Payload, found {apps}")
    app = os.path.join(payload, apps[0])
    info_path = os.path.join(app, "Info.plist")
    with open(info_path, "rb") as f:
        raw = f.read()
    fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
    info = plistlib.loads(raw)
    original = info.get("CFBundleIdentifier", "")
    if original and original != bundle:
        info["ALTBundleIdentifier"] = original
    info.setdefault("ALTAppGroups", [])
    info.setdefault("ALTPairingFile", "<insert pairing file here>")
    scheme = f"sidestore-{bundle}"
    types = list(info.get("CFBundleURLTypes") or [])
    if not any(scheme in (t.get("CFBundleURLSchemes") or []) for t in types):
        types.append({"CFBundleTypeRole": "Editor", "CFBundleURLName": bundle,
                      "CFBundleURLSchemes": [scheme]})
    info["CFBundleURLTypes"] = types
    # Newer SideStore checks this exported type (not just the URL scheme) to see the app installed.
    ut_id = f"io.sidestore.Installed.{bundle}"
    uts = list(info.get("UTExportedTypeDeclarations") or [])
    if not any(t.get("UTTypeIdentifier") == ut_id for t in uts):
        uts.append({"UTTypeConformsTo": [], "UTTypeDescription": "AltStore Installed App",
                    "UTTypeIconFiles": [], "UTTypeIdentifier": ut_id, "UTTypeTagSpecification": {}})
    info["UTExportedTypeDeclarations"] = uts
    with open(info_path, "wb") as f:
        plistlib.dump(info, f, fmt=fmt)
    return app


async def install(ipa: str) -> str:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    try:
        lockdown = await create_using_usbmux()
        try:
            async with InstallationProxyService(lockdown=lockdown) as iproxy:
                # A stuck installd (seen once: it never answered until the phone was restarted)
                # must not hang the deploy.
                await asyncio.wait_for(iproxy.install_from_local(ipa, "Install"), INSTALL_TIMEOUT_S)
        finally:
            try:
                await lockdown.close()
            except Exception:  # noqa: BLE001
                pass
    except asyncio.TimeoutError:
        return (f"INSTALL_FAILED\tthe phone's installer did not finish within {INSTALL_TIMEOUT_S} s "
                "(restart the phone)")
    except Exception as exc:  # noqa: BLE001
        return f"INSTALL_FAILED\t{type(exc).__name__}: {exc}"
    return ""


async def sign_install(ipa: str, zsign: str, p12: str, target: str, work: str) -> int:
    line, ctx = await prepare(p12, target)
    if ctx is None:
        print(line)
        return 1
    print(line)
    os.makedirs(work, exist_ok=True)
    prov = os.path.join(work, "app.mobileprovision")
    out = os.path.join(work, "LoopSegments-signed.ipa")
    for f in (prov, out):
        if os.path.exists(f):
            os.remove(f)
    with open(prov, "wb") as f:
        f.write(ctx["profile"])
    try:
        app = add_sidestore_markers(ipa, ctx["bundle"], work)
    except Exception as exc:  # noqa: BLE001
        print(f"SIGN_FAILED\tInfo.plist: {type(exc).__name__}: {exc}")
        return 1
    try:
        # -b keeps SideStore's bundle id; entitlements come from the profile.
        proc = subprocess.run(
            [zsign, "-q", "-k", p12, "-p", ctx["password"], "-m", prov, "-b", ctx["bundle"],
             "-o", out, app],
            # cwd: zsign writes .zsign_cache/ into the current folder.
            capture_output=True, text=True, timeout=300, cwd=work)
    except Exception as exc:  # noqa: BLE001
        print(f"SIGN_FAILED\t{type(exc).__name__}: {exc}")
        return 1
    if proc.returncode != 0 or not os.path.isfile(out):
        why = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip().splitlines()
        print(f"SIGN_FAILED\t{why[-1] if why else proc.returncode}")
        return 1
    err = await install(out)
    try:
        os.remove(out)
    except OSError:
        pass
    if err:
        print(err)
        return 1
    print(f"INSTALLED\t{ctx['bundle']}")
    return 0


def main() -> int:
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "check":
        line, ctx = asyncio.run(prepare(a[1], a[2]))
        print(line)
        return 0 if ctx else 1
    if len(a) == 6 and a[0] == "sign-install":
        return asyncio.run(sign_install(*a[1:]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
