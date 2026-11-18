#!/usr/bin/env python3
"""Background Loop Segments over USB in one process with one userspace tunnel.

Go-IphoneHomeViaUsb.ps1 used to run separate Python processes for the lock probe, the foreground
probe, the Home press (`dvt launch com.apple.springboard --userspace`) and the post-press check.
Each DVT step opened its own UserspaceRsdTunnel, and that handshake is most of each step's time.
This script opens the tunnel once and does proclist -> launch SpringBoard -> proclist over it
(falling back to Settings if SpringBoard does not take the app out of the foreground).

stdout result line (the caller matches on these):
  HOME_OK             SpringBoard launched, app no longer foreground
  SETTINGS_OK         Settings launched, app no longer foreground
  SKIP_LOCKED         passcode lock screen up (app is already backgrounded)
  SKIP_NOT_FOREGROUND app is not the foreground app
  STILL_FOREGROUND    both launches ran but the app is still frontmost
  FAILED              tunnel / DVT error (details on stderr)

Exit codes: 0 done or skipped, 1 failed (caller falls back to the per-step CLI path),
2 no USB device, 3 phone locked while pressing Home.
"""

from __future__ import annotations

import asyncio
import importlib.util
import sys
import time
from pathlib import Path
from typing import Any

# Same bundle-id / name matching as the standalone foreground probe (hyphenated file name,
# so load it by path).
_probe_path = Path(__file__).resolve().parent / "Probe-LoopSegmentsForeground.py"
_spec = importlib.util.spec_from_file_location("probe_loop_segments_foreground", _probe_path)
_probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_probe)
find_foreground = _probe._find_foreground

WANT = "com.loopsegments.app"
SPRINGBOARD = "com.apple.springboard"
SETTINGS = "com.apple.Preferences"

_LOCK_PROBE_SERVICES = (
    "com.apple.mobile.installation_proxy",
    "com.apple.springboardservices",
)


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


async def _lock_state() -> int:
    """0 unlocked, 2 no device, 3 locked, 1 unknown."""
    from pymobiledevice3.exceptions import PasswordRequiredError
    from pymobiledevice3.lockdown import create_using_usbmux

    try:
        lockdown = await create_using_usbmux()
    except Exception as exc:  # noqa: BLE001
        _log(f"NO_DEVICE: {type(exc).__name__}: {exc}")
        return 2
    locked = ok = 0
    try:
        for name in _LOCK_PROBE_SERVICES:
            try:
                conn = await lockdown.start_lockdown_service(name)
                await conn.close()
                ok += 1
            except PasswordRequiredError as exc:
                locked += 1
                _log(f"LOCKED: {name}: {exc}")
            except Exception as exc:  # noqa: BLE001
                _log(f"PROBE_ERR: {name}: {type(exc).__name__}: {exc}")
    finally:
        try:
            await lockdown.close()
        except Exception:  # noqa: BLE001
            pass
    if locked:
        return 3
    return 0 if ok else 1


async def _left_foreground(device_info: Any, timeout: float = 3.0) -> bool:
    """Poll proclist until the app is no longer frontmost (launch is not instant)."""
    deadline = time.monotonic() + timeout
    while True:
        procs = await device_info.proclist()
        if find_foreground(procs, WANT) is None:
            return True
        if time.monotonic() >= deadline:
            return False
        await asyncio.sleep(0.4)


async def run() -> int:
    t0 = time.monotonic()
    lock = await _lock_state()
    _log(f"[timing] lock probe {time.monotonic() - t0:.1f}s")
    if lock == 2:
        return 2
    if lock == 3:
        print("SKIP_LOCKED")
        return 0

    from pymobiledevice3.exceptions import PasswordRequiredError
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    try:
        async with UserspaceRsdTunnel() as rsd:
            _log(f"[timing] tunnel up {time.monotonic() - t0:.1f}s")
            async with DvtProvider(rsd) as dvt, DeviceInfo(dvt) as device_info, ProcessControl(dvt) as pc:
                hit = find_foreground(await device_info.proclist(), WANT)
                _log(f"[timing] foreground probe {time.monotonic() - t0:.1f}s")
                if hit is None:
                    print("SKIP_NOT_FOREGROUND")
                    return 0
                _log(f"FOREGROUND pid={hit.get('pid')}")
                for bundle, marker in ((SPRINGBOARD, "HOME_OK"), (SETTINGS, "SETTINGS_OK")):
                    pid = await pc.launch(bundle, kill_existing=False)
                    _log(f"[timing] launched {bundle} pid={pid} {time.monotonic() - t0:.1f}s")
                    if await _left_foreground(device_info):
                        _log(f"[timing] backgrounded {time.monotonic() - t0:.1f}s")
                        print(marker)
                        return 0
                    _log(f"still foreground after {bundle}")
                print("STILL_FOREGROUND")
                return 1
    except PasswordRequiredError as exc:
        _log(f"LOCKED: {exc}")
        return 3
    except Exception as exc:  # noqa: BLE001
        _log(f"ERR: {type(exc).__name__}: {exc}")
        print("FAILED")
        return 1


def main() -> int:
    try:
        return asyncio.run(run())
    except KeyboardInterrupt:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
