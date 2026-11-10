#!/usr/bin/env python3
"""Check whether the Minecraft server is reachable and print its status.

The script performs a Server List Ping, which is exactly what the Minecraft
client does when it shows a server in its server list. It therefore proves
reachability from the outside without starting the game.

Usage:
    python check_status.py <HOST>[:<PORT>]

The port defaults to 8888, the port this project publishes.

Exit codes:
    0  server answered
    1  server did not answer
    2  wrong command line arguments
"""

from __future__ import annotations

import argparse
import sys

try:
    from mcstatus import JavaServer
except ModuleNotFoundError:
    print(
        "The 'mcstatus' package is missing. Install it with:\n"
        "    pip install --requirement requirements.txt",
        file=sys.stderr,
    )
    sys.exit(2)

DEFAULT_PORT = 8888


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check whether a Minecraft Java Edition server is reachable.",
    )
    parser.add_argument(
        "address",
        help=f"server address as HOST or HOST:PORT (default port: {DEFAULT_PORT})",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    address = arguments.address

    if ":" not in address:
        address = f"{address}:{DEFAULT_PORT}"

    try:
        server = JavaServer.lookup(address)
        status = server.status()
    except Exception as error:  # noqa: BLE001 - any failure means unreachable
        print(f"FAILED  {address} is not reachable: {error}")
        return 1

    print(f"OK      {address} is online")
    print(f"        version:  {status.version.name}")
    print(f"        players:  {status.players.online}/{status.players.max}")
    print(f"        motd:     {status.motd.to_plain()}")
    print(f"        latency:  {status.latency:.0f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
