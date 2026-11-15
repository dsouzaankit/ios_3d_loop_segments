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


async def vpn_off(opener_bundle: str, timeout: float = 20.0) -> bool:
    """Switch LocalDevVPN off and return to the Home Screen over ONE DVT connection: launch the
    opener app (Loop Segments 428+) with -openURL localdevvpn://disable, check every second until
    LocalDevVPN's tunnel process is gone, then bring SpringBoard to the front. True = tunnel down."""
    import asyncio
    import time

    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    async def _run(dvt: Any) -> bool:
        async with ProcessControl(dvt) as pc:
            await pc.launch(opener_bundle, arguments=["-openURL", "localdevvpn://disable"], kill_existing=True)
        down = False
        deadline = time.monotonic() + timeout
        async with DeviceInfo(dvt) as info:
            while time.monotonic() < deadline:
                await asyncio.sleep(1)
                procs = await info.proclist()
                if not any("LocalDevVPN.app/PlugIns/" in str(p.get("realAppName") or "") for p in procs):
                    down = True
                    break
        async with ProcessControl(dvt) as pc:
            await pc.launch("com.apple.springboard", kill_existing=False)
        return down

    return await with_dvt(_run)


async def quit_app(bundle_prefix: str, name: str = "") -> list[int]:
    """Quit (kill) every running process whose bundle id starts with bundle_prefix, or whose name
    equals name. One DVT connection. Returns the pids killed (empty = it was not running)."""
    import asyncio

    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    async def _run(dvt: Any) -> list[int]:
        async with DeviceInfo(dvt) as info:
            procs = await info.proclist()
        pids = [int(p["pid"]) for p in procs
                if isinstance(p.get("pid"), int) and (
                    str(p.get("bundleIdentifier") or "").startswith(bundle_prefix)
                    or (name and str(p.get("name") or "") == name))]
        if pids:
            async with ProcessControl(dvt) as pc:
                for pid in pids:
                    await pc.kill(pid)
                await asyncio.sleep(0.5)  # kill is fire-and-forget
        return pids

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
