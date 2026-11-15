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
