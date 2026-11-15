#!/usr/bin/env python3
"""Make sure LocalDevVPN is connected on the USB iPhone (SideStore needs it to install / refresh).

Connected = the VPN's packet-tunnel extension (LocalDevVPN.app/PlugIns/...) is running (DVT proclist).
Not connected: launch LocalDevVPN over USB (DVT, --userspace tunnel first, then lockdown). Its
"Auto-connect on launch" setting (LocalDevVPN > Settings, switch it on once) then starts the tunnel,
and this waits up to --wait seconds for it, then goes back to the Home Screen.

Prints one result line:
  VPN_ALREADY_CONNECTED
  VPN_CONNECTED          (after the launch)
  VPN_NOT_CONNECTED      (launched, no tunnel: is Auto-connect on?)
  LAUNCH_FAILED
  PROBE_FAILED / NO_DEVICE
Exit codes: 0 connected, 1 not connected / failed, 2 no USB device.
"""

from __future__ import annotations

import asyncio
import sys
import time
from typing import Any

from loopsegments_dvt import go_home, is_no_device, launch, proclist

BUNDLE = "com.jkcoxson.LocalDevVPN"


def _tunnel_up(procs: list[dict[str, Any]]) -> bool:
    return any("LocalDevVPN.app/PlugIns/" in str(p.get("realAppName") or "") for p in procs)


async def run(wait_sec: int) -> int:
    try:
        procs = await proclist()
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if is_no_device(msg):
            print(f"NO_DEVICE\t{msg}")
            return 2
        print(f"PROBE_FAILED\t{msg}")
        return 1
    if _tunnel_up(procs):
        print("VPN_ALREADY_CONNECTED")
        return 0

    try:
        # Fresh launch so the app's launch-time auto-connect runs.
        pid = await launch(BUNDLE, kill_existing=True)
        print(f"LAUNCHED\tpid={pid}", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        print(f"LAUNCH_FAILED\t{exc}")
        return 1

    deadline = time.monotonic() + max(1, wait_sec)
    while time.monotonic() < deadline:
        await asyncio.sleep(2)
        try:
            if _tunnel_up(await proclist()):
                print("VPN_CONNECTED")
                try:
                    await go_home()  # the launch left LocalDevVPN in front
                except Exception as exc:  # noqa: BLE001
                    print(f"HOME_FAILED\t{exc}", file=sys.stderr)
                return 0
        except Exception as exc:  # noqa: BLE001
            print(f"PROCLIST_ERR\t{exc}", file=sys.stderr)
    print("VPN_NOT_CONNECTED")
    return 1


def main() -> int:
    wait = 15
    args = sys.argv[1:]
    if "--wait" in args:
        try:
            wait = int(args[args.index("--wait") + 1])
        except (IndexError, ValueError):
            pass
    try:
        return asyncio.run(run(wait))
    except KeyboardInterrupt:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
