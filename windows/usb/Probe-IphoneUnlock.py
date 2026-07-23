#!/usr/bin/env python3
"""Exit 0 if iPhone is unlocked for developer/USB work; exit 3 if passcode-locked."""

from __future__ import annotations

import asyncio
import sys

from pymobiledevice3.exceptions import PasswordRequiredError
from pymobiledevice3.lockdown import create_using_usbmux

# Services that typically refuse StartService while the passcode lock screen is up.
_PROBE_SERVICES = (
    "com.apple.mobile.installation_proxy",
    "com.apple.afc",
    "com.apple.springboardservices",
)


async def probe() -> int:
    try:
        lockdown = await create_using_usbmux()
    except Exception as exc:  # noqa: BLE001 — surface to caller
        print(f"NO_DEVICE: {exc}", file=sys.stderr)
        return 2

    locked_hits = 0
    ok_hits = 0
    last_err = ""
    for name in _PROBE_SERVICES:
        try:
            conn = await lockdown.start_lockdown_service(name)
            await conn.close()
            ok_hits += 1
        except PasswordRequiredError as exc:
            locked_hits += 1
            last_err = str(exc)
            print(f"LOCKED: {name}: {exc}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            last_err = f"{type(exc).__name__}: {exc}"
            print(f"PROBE_ERR: {name}: {last_err}", file=sys.stderr)

    if locked_hits > 0 and ok_hits == 0:
        print("PHONE_LOCKED", file=sys.stderr)
        return 3
    if locked_hits > 0:
        # Mixed results — treat as locked to be safe before app launch.
        print("PHONE_LOCKED", file=sys.stderr)
        return 3
    if ok_hits == 0:
        print(f"PROBE_FAILED: {last_err}", file=sys.stderr)
        return 1

    print("UNLOCKED")
    return 0


def main() -> int:
    return asyncio.run(probe())


if __name__ == "__main__":
    raise SystemExit(main())
