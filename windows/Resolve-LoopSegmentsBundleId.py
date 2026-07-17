#!/usr/bin/env python3
"""Print the installed Loop Segments bundle id (AltStore may append .TEAMID)."""

from __future__ import annotations

import asyncio
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService


async def resolve(want: str) -> str:
    lockdown = await create_using_usbmux()
    async with InstallationProxyService(lockdown=lockdown) as iproxy:
        apps = await iproxy.get_apps(application_type="User")
        if want in apps:
            return want
        prefix = [bid for bid in apps if bid == want or bid.startswith(want + ".")]
        by_name = [
            bid
            for bid, info in apps.items()
            if (info.get("CFBundleDisplayName") or info.get("CFBundleName") or "")
            == "Loop Segments"
        ]
        pick = prefix + by_name
        if not pick:
            print("NOT_FOUND", file=sys.stderr)
            for bid, info in sorted(apps.items()):
                name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or ""
                if "loop" in (bid + " " + name).lower():
                    print(f"CANDIDATE\t{bid}\t{name}", file=sys.stderr)
            raise SystemExit(2)
        return pick[0]


def main() -> int:
    want = sys.argv[1] if len(sys.argv) > 1 else "com.loopsegments.app"
    print(asyncio.run(resolve(want)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
