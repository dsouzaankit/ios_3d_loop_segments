#!/usr/bin/env python3
"""Exit 0 if Loop Segments is already the foreground app over USB (DVT proclist).

Exit codes:
  0  FOREGROUND — app already frontmost; caller may skip relaunch
  1  NOT_FOREGROUND / probe inconclusive — caller should launch
  2  No USB device / lockdown failure
"""

from __future__ import annotations

import asyncio
import sys
from typing import Any, Optional


def _bundle_matches(got: str, want: str) -> bool:
    if not got or not want:
        return False
    if got == want:
        return True
    # AltStore / Sideloadly may append .TEAMID to either side of the comparison.
    if got.startswith(want + ".") or want.startswith(got + "."):
        return True
    base = "com.loopsegments.app"
    if got == base or got.startswith(base + "."):
        if want == base or want.startswith(base + "."):
            return True
    return False


def _is_loop_segments_proc(proc: dict[str, Any], want: str) -> bool:
    bid = str(proc.get("bundleIdentifier") or "").strip()
    if _bundle_matches(bid, want):
        return True
    name = str(proc.get("name") or "")
    real = str(proc.get("realAppName") or "")
    blob = f"{name} {real}".lower()
    return "loopsegments" in blob.replace(" ", "") or "loop segments" in blob


def _find_foreground(processes: list[dict[str, Any]], want: str) -> Optional[dict[str, Any]]:
    for proc in processes:
        if not _is_loop_segments_proc(proc, want):
            continue
        if proc.get("foregroundRunning") is True:
            return proc
    return None


async def _proclist_via_userspace() -> list[dict[str, Any]]:
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider

    async with UserspaceRsdTunnel() as rsd:
        async with DvtProvider(rsd) as dvt, DeviceInfo(dvt) as device_info:
            return await device_info.proclist()


async def _proclist_via_lockdown() -> list[dict[str, Any]]:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider

    lockdown = await create_using_usbmux()
    try:
        async with DvtProvider(lockdown) as dvt, DeviceInfo(dvt) as device_info:
            return await device_info.proclist()
    finally:
        try:
            await lockdown.close()
        except Exception:  # noqa: BLE001
            pass


async def probe(want: str) -> int:
    errors: list[str] = []
    processes: Optional[list[dict[str, Any]]] = None

    for label, factory in (
        ("userspace", _proclist_via_userspace),
        ("lockdown", _proclist_via_lockdown),
    ):
        try:
            processes = await factory()
            print(f"PROCLIST_OK:{label}", file=sys.stderr)
            break
        except Exception as exc:  # noqa: BLE001
            msg = f"{type(exc).__name__}: {exc}"
            errors.append(f"{label}:{msg}")
            print(f"PROCLIST_ERR:{label}: {msg}", file=sys.stderr)

    if processes is None:
        joined = " | ".join(errors)
        if any(("NoDevice" in e or "DeviceNotFound" in e or "MuxException" in e) for e in errors):
            print(f"NO_DEVICE: {joined}", file=sys.stderr)
            return 2
        print(f"PROBE_FAILED: {joined}", file=sys.stderr)
        return 1

    hit = _find_foreground(processes, want)
    if hit is not None:
        pid = hit.get("pid", "?")
        bid = hit.get("bundleIdentifier") or hit.get("name") or want
        print(f"FOREGROUND\t{bid}\tpid={pid}")
        return 0

    # Helpful for logs: running but not frontmost vs not running.
    running = [p for p in processes if _is_loop_segments_proc(p, want)]
    if running:
        p0 = running[0]
        print(
            f"NOT_FOREGROUND\t{p0.get('bundleIdentifier') or p0.get('name')}\t"
            f"pid={p0.get('pid')}\tforegroundRunning={p0.get('foregroundRunning')}"
        )
    else:
        print("NOT_FOREGROUND\tnot_running")
    return 1


def main() -> int:
    want = sys.argv[1] if len(sys.argv) > 1 else "com.loopsegments.app"
    try:
        return asyncio.run(probe(want))
    except KeyboardInterrupt:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
