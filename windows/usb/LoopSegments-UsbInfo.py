#!/usr/bin/env python3
"""Small USB queries for Install-LoopSegmentsIpaViaUsb.ps1. Prints one line per call.

  installed-build          -> BUILD <CFBundleVersion> <bundle id> <app path> | NOT_INSTALLED | NO_DEVICE <why>
  ipa-build <path.ipa>     -> BUILD <CFBundleVersion> | ERROR <why>   (reads the IPA, no phone needed)
  vpn-tunnel               -> TUNNEL_UP | TUNNEL_DOWN | NO_DEVICE <why>
  home                     -> HOME | HOME_FAILED <why>   (Home Screen to the front)
"""

from __future__ import annotations

import asyncio
import plistlib
import sys
import zipfile

from loopsegments_dvt import go_home, is_no_device, proclist, resolve_bundle_id


async def installed_build() -> int:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    try:
        bundle = await resolve_bundle_id("com.loopsegments.app", "Loop Segments")
        if not bundle:
            print("NOT_INSTALLED")
            return 1
        lockdown = await create_using_usbmux()
        try:
            async with InstallationProxyService(lockdown=lockdown) as iproxy:
                apps = await iproxy.get_apps(application_type="User")
        finally:
            try:
                await lockdown.close()
            except Exception:  # noqa: BLE001
                pass
    except Exception as exc:  # noqa: BLE001
        msg = f"{type(exc).__name__}: {exc}"
        print(("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg)
        return 2
    info = apps.get(bundle) or {}
    # Path (…/Bundle/Application/<UUID>/…) changes on every install, even of the same build.
    print(f"BUILD\t{info.get('CFBundleVersion', '')}\t{bundle}\t{info.get('Path', '')}")
    return 0


def ipa_build(path: str) -> int:
    try:
        with zipfile.ZipFile(path) as z:
            name = next(n for n in z.namelist()
                        if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist"))
            info = plistlib.loads(z.read(name))
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR\t{type(exc).__name__}: {exc}")
        return 1
    print(f"BUILD\t{info.get('CFBundleVersion', '')}")
    return 0


async def vpn_tunnel() -> int:
    try:
        procs = await proclist()
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        print(("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg)
        return 2
    up = any("LocalDevVPN.app/PlugIns/" in str(p.get("realAppName") or "") for p in procs)
    print("TUNNEL_UP" if up else "TUNNEL_DOWN")
    return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "installed-build":
        return asyncio.run(installed_build())
    if cmd == "ipa-build" and len(sys.argv) > 2:
        return ipa_build(sys.argv[2])
    if cmd == "vpn-tunnel":
        return asyncio.run(vpn_tunnel())
    if cmd == "home":
        try:
            asyncio.run(go_home())
        except Exception as exc:  # noqa: BLE001
            print(f"HOME_FAILED\t{type(exc).__name__}: {exc}")
            return 1
        print("HOME")
        return 0
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
