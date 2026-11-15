#!/usr/bin/env python3
"""Small USB queries for Install-LoopSegmentsIpaViaUsb.ps1. Prints one line per call.

  installed-build          -> BUILD <CFBundleVersion> <bundle id> <app path> | NOT_INSTALLED | NO_DEVICE <why>
  ipa-build <path.ipa>     -> BUILD <CFBundleVersion> | ERROR <why>   (reads the IPA, no phone needed)
  vpn-tunnel               -> TUNNEL_UP | TUNNEL_DOWN | NO_DEVICE <why>
  home                     -> HOME | HOME_FAILED <why>   (Home Screen to the front)
  wifi-ip                  -> WIFI_IP <ipv4> | NO_WIFI_IP   (the phone's own address on en0, DVT network monitor)
  wait-install <build> <old app path> <timeout s>
                           -> INSTALLED <build> <path> | TIMEOUT   (checks every 1 s on one connection)
  vpn-off                  -> VPN_OFF | VPN_STILL_UP   (localdevvpn://disable via Loop Segments, tunnel
                              check every 1 s, then Home Screen: one DVT connection)
  quit-sidestore           -> QUIT <pids> | NOT_RUNNING   (fresh SideStore for the next install try)
"""

from __future__ import annotations

import asyncio
import plistlib
import sys
import zipfile

from loopsegments_dvt import go_home, is_no_device, proclist, quit_app, resolve_bundle_id, vpn_off, wifi_ipv4


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


async def wait_install(want_build: str, old_path: str, timeout: float) -> int:
    """Check the installed Loop Segments every second over one lockdown connection until it reports
    want_build with an install path other than old_path (a new install, even of the same build)."""
    import time

    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    deadline = time.monotonic() + timeout
    lockdown = None
    try:
        lockdown = await create_using_usbmux()
        while time.monotonic() < deadline:
            try:
                async with InstallationProxyService(lockdown=lockdown) as iproxy:
                    apps = await iproxy.get_apps(application_type="User")
                for bid, info in apps.items():
                    if not (bid == "com.loopsegments.app" or bid.startswith("com.loopsegments.app.")):
                        continue
                    build, path = str(info.get("CFBundleVersion", "")), str(info.get("Path", ""))
                    if build == want_build and path and path != old_path:
                        print(f"INSTALLED\t{build}\t{path}")
                        return 0
            except Exception as exc:  # noqa: BLE001 - mid-install the lookup can fail; keep polling
                print(f"POLL_ERR\t{type(exc).__name__}: {exc}", file=sys.stderr)
                try:
                    if lockdown is not None:
                        await lockdown.close()
                except Exception:  # noqa: BLE001
                    pass
                lockdown = await create_using_usbmux()
            await asyncio.sleep(1)
    except Exception as exc:  # noqa: BLE001
        msg = f"{type(exc).__name__}: {exc}"
        print(("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg)
        return 2
    finally:
        try:
            if lockdown is not None:
                await lockdown.close()
        except Exception:  # noqa: BLE001
            pass
    print("TIMEOUT")
    return 1


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
    if cmd == "wifi-ip":
        try:
            ip = asyncio.run(wifi_ipv4())
        except Exception as exc:  # noqa: BLE001
            msg = f"{type(exc).__name__}: {exc}"
            print(("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg)
            return 2
        print(f"WIFI_IP\t{ip}" if ip else "NO_WIFI_IP")
        return 0 if ip else 1
    if cmd == "wait-install" and len(sys.argv) > 4:
        return asyncio.run(wait_install(sys.argv[2].strip(), sys.argv[3].strip(), float(sys.argv[4])))
    if cmd == "quit-sidestore":
        try:
            # SideStore installs carry the team id: com.SideStore.SideStore.<TEAMID>.
            pids = asyncio.run(quit_app("com.SideStore.SideStore", "SideStore"))
        except Exception as exc:  # noqa: BLE001
            msg = f"{type(exc).__name__}: {exc}"
            print(("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg)
            return 2
        print(f"QUIT\t{','.join(map(str, pids))}" if pids else "NOT_RUNNING")
        return 0
    if cmd == "vpn-off":
        try:
            bundle = asyncio.run(resolve_bundle_id("com.loopsegments.app", "Loop Segments"))
            if not bundle:
                print("NOT_INSTALLED")
                return 1
            down = asyncio.run(vpn_off(bundle))
        except Exception as exc:  # noqa: BLE001
            msg = f"{type(exc).__name__}: {exc}"
            print(("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg)
            return 2
        print("VPN_OFF" if down else "VPN_STILL_UP")
        return 0 if down else 1
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
