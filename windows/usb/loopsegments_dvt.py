"""Shared USB helpers for the Loop Segments PC scripts (pymobiledevice3 DVT).

Every call tries the iOS 17+ userspace RSD tunnel first (no admin, same path as the USB launch and
Home scripts), then plain lockdown over usbmux.
"""

from __future__ import annotations

from typing import Any, Awaitable, Callable, Optional


async def with_dvt(action: Callable[[Any], Awaitable[Any]]) -> Any:
    """Run action(dvt) over the userspace RSD tunnel, else plain lockdown."""
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider

    errors: list[str] = []
    try:
        from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel

        async with UserspaceRsdTunnel() as rsd:
            async with DvtProvider(rsd) as dvt:
                return await action(dvt)
    except Exception as exc:  # noqa: BLE001
        errors.append(f"userspace:{type(exc).__name__}: {exc}")
    try:
        from pymobiledevice3.lockdown import create_using_usbmux

        lockdown = await create_using_usbmux()
        try:
            async with DvtProvider(lockdown) as dvt:
                return await action(dvt)
        finally:
            try:
                await lockdown.close()
            except Exception:  # noqa: BLE001
                pass
    except Exception as exc:  # noqa: BLE001
        errors.append(f"lockdown:{type(exc).__name__}: {exc}")
    raise RuntimeError(" | ".join(errors))


def is_no_device(message: str) -> bool:
    return "NoDevice" in message or "DeviceNotFound" in message or "MuxException" in message


async def proclist() -> list[dict[str, Any]]:
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo

    async def _run(dvt: Any) -> list[dict[str, Any]]:
        async with DeviceInfo(dvt) as info:
            return await info.proclist()

    return await with_dvt(_run)


async def launch(bundle_id: str, arguments: Optional[list[str]] = None, kill_existing: bool = True) -> int:
    """Launch an app (fresh by default) with optional launch arguments; returns its pid."""
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    async def _run(dvt: Any) -> int:
        async with ProcessControl(dvt) as pc:
            return await pc.launch(bundle_id, arguments=arguments or [], kill_existing=kill_existing)

    return await with_dvt(_run)


async def wifi_ipv4(seconds: float = 6.0) -> Optional[str]:
    """The phone's own Wi-Fi IPv4: the local address of its TCP connections on en0 (Wi-Fi), from
    the DVT network monitor. Exact, unlike pcapd sniffing (which also sees peers such as this PC).
    None when no TCP connection on Wi-Fi shows up within `seconds`: Wi-Fi off, or a Wi-Fi with no
    gateway (the phone LAN, where internet goes over cellular), so callers fall back to pcapd."""
    import asyncio
    import ipaddress
    from collections import Counter

    from pymobiledevice3.services.dvt.instruments.network_monitor import (
        ConnectionDetectionEvent,
        InterfaceDetectionEvent,
        NetworkMonitor,
    )

    async def _run(dvt: Any) -> Optional[str]:
        names: dict[int, str] = {}
        seen: list[tuple[int, str]] = []

        async def _collect() -> None:
            async with NetworkMonitor(dvt) as monitor:
                async for event in monitor:
                    if isinstance(event, InterfaceDetectionEvent):
                        names[event.interface_index] = event.name
                    elif isinstance(event, ConnectionDetectionEvent):
                        # TCP only (kind 1): iOS drops TCP connections when their address goes away,
                        # but UDP sockets (kind 2) can stay bound to a previous Wi-Fi's address.
                        if event.kind != 1:
                            continue
                        addr = getattr(event.local_address.data, "address", None)
                        if isinstance(addr, ipaddress.IPv4Address) and addr.is_private and not addr.is_loopback \
                                and not addr.is_link_local and str(addr) != "0.0.0.0":
                            seen.append((event.interface_index, str(addr)))

        try:
            await asyncio.wait_for(_collect(), timeout=seconds)
        except asyncio.TimeoutError:
            pass
        wifi = [ip for idx, ip in seen if names.get(idx) == "en0"]
        return Counter(wifi).most_common(1)[0][0] if wifi else None

    return await with_dvt(_run)


def _tunnel_pids(procs: list[dict[str, Any]]) -> list[int]:
    """LocalDevVPN's packet-tunnel extension (LocalDevVPN.app/PlugIns/...): running = VPN connected."""
    return [int(p["pid"]) for p in procs
            if isinstance(p.get("pid"), int) and "LocalDevVPN.app/PlugIns/" in str(p.get("realAppName") or "")]


async def _stop_tunnel(dvt: Any, info: Any, timeout: float) -> bool:
    """Quit LocalDevVPN's tunnel extension (DVT kill). Tested: iOS does not restart it by itself,
    and no app has to open a localdevvpn:// link, so a Face ID lock on Loop Segments never prompts."""
    import asyncio
    import time

    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    pids = _tunnel_pids(await info.proclist())
    if not pids:
        return True
    async with ProcessControl(dvt) as pc:
        for pid in pids:
            await pc.kill(pid)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        await asyncio.sleep(1)
        if not _tunnel_pids(await info.proclist()):
            return True
    return False


async def vpn_off(timeout: float = 15.0) -> bool:
    """Switch LocalDevVPN off and return to the Home Screen over ONE DVT connection: quit its tunnel
    extension, then bring SpringBoard to the front. True = tunnel down."""
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    async def _run(dvt: Any) -> bool:
        async with DeviceInfo(dvt) as info:
            down = await _stop_tunnel(dvt, info, timeout)
        async with ProcessControl(dvt) as pc:
            await pc.launch("com.apple.springboard", kill_existing=False)
        return down

    return await with_dvt(_run)


async def vpn_restart(down_timeout: float = 15.0, up_timeout: float = 20.0) -> str:
    """Restart LocalDevVPN (tunnel and app) over ONE DVT connection: quit its tunnel extension, then a
    fresh LocalDevVPN launch whose Auto-connect brings a new tunnel up. Returns 'RESTARTED',
    'DOWN_TIMEOUT' (old tunnel would not stop) or 'UP_TIMEOUT' (no new tunnel: Auto-connect off?)."""
    import asyncio
    import time

    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    async def _run(dvt: Any) -> str:
        async with DeviceInfo(dvt) as info:
            was_up = bool(_tunnel_pids(await info.proclist()))
            if not await _stop_tunnel(dvt, info, down_timeout):
                return "DOWN_TIMEOUT"
            if was_up:
                # iOS still reports the VPN as connected for a moment after its extension is quit, and
                # LocalDevVPN's Auto-connect only connects when it is not: let that status settle.
                await asyncio.sleep(4)
            # Fresh app: its launch-time Auto-connect starts a new tunnel. A second launch covers a
            # first one that still saw the old "connected" status.
            for wait in (up_timeout / 2, up_timeout / 2):
                async with ProcessControl(dvt) as pc:
                    await pc.launch("com.jkcoxson.LocalDevVPN", kill_existing=True)
                deadline = time.monotonic() + wait
                while time.monotonic() < deadline:
                    await asyncio.sleep(1)
                    if _tunnel_pids(await info.proclist()):
                        return "RESTARTED"
        return "UP_TIMEOUT"

    return await with_dvt(_run)


def _bundle_matches(got: str, want: str) -> bool:
    if not got or not want:
        return False
    if got == want or got.startswith(want + ".") or want.startswith(got + "."):
        return True
    base = "com.loopsegments.app"
    if (got == base or got.startswith(base + ".")) and (want == base or want.startswith(base + ".")):
        return True
    return False


def _is_app_proc(proc: dict[str, Any], bundle_prefix: str, name: str = "") -> bool:
    """Match by bundle id, exact/compact name, or (for Loop Segments) realAppName path."""
    bid = str(proc.get("bundleIdentifier") or "").strip()
    if bid.startswith(bundle_prefix) or _bundle_matches(bid, bundle_prefix):
        return True
    proc_name = str(proc.get("name") or "")
    if name and (proc_name == name or proc_name.replace(" ", "") == name.replace(" ", "")):
        return True
    blob = f"{proc_name} {proc.get('realAppName') or ''}".lower().replace(" ", "")
    if name:
        compact = name.lower().replace(" ", "")
        if compact and compact in blob:
            return True
    # Background Keep Alive often has empty bundleIdentifier and name "LoopSegments".
    if bundle_prefix.startswith("com.loopsegments.app") and "loopsegments" in blob:
        return True
    return False


def _pids_for_app(procs: list[dict[str, Any]], bundle_prefix: str, name: str = "") -> list[int]:
    return sorted({
        int(p["pid"]) for p in procs
        if isinstance(p.get("pid"), int) and _is_app_proc(p, bundle_prefix, name)
    })


async def quit_app(bundle_prefix: str, name: str = "") -> list[int]:
    """Quit (kill) every running process for bundle_prefix / name. One DVT connection.
    Returns the pids killed (empty = it was not running). Matches realAppName too — background
    Keep Alive processes often omit bundleIdentifier and use name LoopSegments (no space)."""
    import asyncio

    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    async def _run(dvt: Any) -> list[int]:
        async with DeviceInfo(dvt) as info:
            procs = await info.proclist()
        pids = _pids_for_app(procs, bundle_prefix, name)
        if not pids:
            # InstallationProxy-resolved id may differ from prefix; ask ProcessControl directly.
            async with ProcessControl(dvt) as pc:
                try:
                    pid = int(await pc.process_identifier_for_bundle_identifier(bundle_prefix))
                except Exception:  # noqa: BLE001
                    pid = 0
                if pid > 0:
                    pids = [pid]
        if pids:
            async with ProcessControl(dvt) as pc:
                for pid in pids:
                    try:
                        await pc.kill(pid)
                    except Exception:  # noqa: BLE001
                        pass
                    try:
                        await pc.signal(pid, 9)  # SIGKILL — kill() alone can leave audio apps up
                    except Exception:  # noqa: BLE001
                        pass
                await asyncio.sleep(0.8)
        return pids

    return await with_dvt(_run)


async def quit_loop_segments(retries: int = 3) -> dict[str, Any]:
    """Force-quit Loop Segments and verify it is gone (needed to stop Keep Alive / :8765)."""
    import asyncio

    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    prefix = "com.loopsegments.app"
    display = "Loop Segments"

    async def _run(dvt: Any) -> dict[str, Any]:
        bundle = await resolve_bundle_id(prefix, display) or prefix
        killed: list[int] = []
        async with DeviceInfo(dvt) as info, ProcessControl(dvt) as pc:
            for attempt in range(max(1, retries)):
                procs = await info.proclist()
                pids = set(_pids_for_app(procs, prefix, display))
                try:
                    pid = int(await pc.process_identifier_for_bundle_identifier(bundle))
                    if pid > 0:
                        pids.add(pid)
                except Exception:  # noqa: BLE001
                    pass
                if not pids:
                    return {
                        "ok": True,
                        "killed": killed,
                        "stillRunning": False,
                        "bundle": bundle,
                        "attempts": attempt + 1,
                    }
                for pid in sorted(pids):
                    try:
                        await pc.kill(pid)
                    except Exception:  # noqa: BLE001
                        pass
                    try:
                        await pc.signal(pid, 9)
                    except Exception:  # noqa: BLE001
                        pass
                    if pid not in killed:
                        killed.append(pid)
                await asyncio.sleep(0.8 + 0.4 * attempt)
            procs = await info.proclist()
            left = _pids_for_app(procs, prefix, display)
            try:
                pid = int(await pc.process_identifier_for_bundle_identifier(bundle))
                if pid > 0 and pid not in left:
                    left.append(pid)
            except Exception:  # noqa: BLE001
                pass
            return {
                "ok": not left,
                "killed": killed,
                "stillRunning": bool(left),
                "remainingPids": left,
                "bundle": bundle,
                "attempts": retries,
            }

    return await with_dvt(_run)


async def go_home() -> int:
    """Bring the Home Screen to the front (DVT launch of SpringBoard, keeping it running), which
    backgrounds whatever app is in front. Same path as usb\\Go-IphoneHomeViaUsb.ps1."""
    return await launch("com.apple.springboard", kill_existing=False)


async def resolve_bundle_id(want: str, display_name: str = "") -> Optional[str]:
    """Installed bundle id for want (SideStore / AltStore may append .TEAMID), else None."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    lockdown = await create_using_usbmux()
    try:
        async with InstallationProxyService(lockdown=lockdown) as iproxy:
            apps = await iproxy.get_apps(application_type="User")
    finally:
        try:
            await lockdown.close()
        except Exception:  # noqa: BLE001
            pass
    if want in apps:
        return want
    for bid in apps:
        if bid.startswith(want + "."):
            return bid
    if display_name:
        for bid, info in apps.items():
            if (info.get("CFBundleDisplayName") or info.get("CFBundleName") or "") == display_name:
                return bid
    return None
