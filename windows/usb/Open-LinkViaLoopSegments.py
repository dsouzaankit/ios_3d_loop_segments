#!/usr/bin/env python3
"""Open a sidestore:// (or shortcuts://) link on the USB iPhone by launching Loop Segments with it.

Over USB the PC can launch an app but not open a link, so this launches Loop Segments (fresh) with
`-openURL <link>`. Build 428+ opens that link and quits itself 1.5 s later (LaunchURLOpener.swift).
Older builds just launch and ignore the argument.

Usage: Open-LinkViaLoopSegments.py <link>
Prints one result line: LAUNCHED <bundle> pid=<n> | NOT_INSTALLED | LAUNCH_FAILED <why> | NO_DEVICE <why>
Exit codes: 0 launched, 1 failed, 2 no USB device.
"""

from __future__ import annotations

import asyncio
import sys

from loopsegments_dvt import is_no_device, launch, resolve_bundle_id


async def run(link: str) -> int:
    try:
        bundle = await resolve_bundle_id("com.loopsegments.app", "Loop Segments")
    except Exception as exc:  # noqa: BLE001
        msg = f"{type(exc).__name__}: {exc}"
        print(("NO_DEVICE\t" if is_no_device(msg) else "LAUNCH_FAILED\t") + msg)
        return 2 if is_no_device(msg) else 1
    if not bundle:
        print("NOT_INSTALLED")
        return 1
    try:
        pid = await launch(bundle, arguments=["-openURL", link], kill_existing=True)
    except Exception as exc:  # noqa: BLE001
        print(f"LAUNCH_FAILED\t{exc}")
        return 1
    print(f"LAUNCHED\t{bundle}\tpid={pid}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: Open-LinkViaLoopSegments.py <sidestore://...>", file=sys.stderr)
        return 1
    return asyncio.run(run(sys.argv[1]))


if __name__ == "__main__":
    raise SystemExit(main())
