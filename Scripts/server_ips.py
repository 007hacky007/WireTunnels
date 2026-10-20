#!/usr/bin/env python3
"""Fetch server IPs, optionally collapsing them into exact IPv4/IPv6 CIDRs.

    python3 Scripts/server_ips.py https://inventory.example.com/servers.json
    python3 Scripts/server_ips.py https://inventory.example.com/servers.json --merge
"""

import argparse
from http.client import HTTPException
import ipaddress
import json
import sys
from urllib.request import urlopen


def extract_ips(payload):
    if not isinstance(payload, dict):
        raise ValueError("Expected a JSON object of server records")
    addresses = []
    for server in payload.values():
        if not isinstance(server, dict) or not isinstance(server.get("ip_all"), str):
            raise ValueError("Each server must have a comma-separated ip_all string")
        for token in server["ip_all"].split(","):
            address = token.strip()
            if address:
                if "%" in address:
                    raise ValueError(f"Scoped IPv6 addresses cannot be used in AllowedIPs: {address}")
                ipaddress.ip_address(address)  # Validate before producing any output.
                addresses.append(address)

    if not addresses:
        raise ValueError("No IP addresses found in ip_all fields")
    return addresses


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("url", help="URL of the JSON server inventory")
    parser.add_argument(
        "--merge", action="store_true",
        help="Deduplicate and collapse into exact CIDRs, sorted IPv4 then IPv6",
    )
    args = parser.parse_args(argv)

    try:
        with urlopen(args.url, timeout=30) as response:
            addresses = extract_ips(json.load(response))
        if args.merge:
            parsed = [ipaddress.ip_address(address) for address in addresses]
            addresses = [
                str(network)
                for version in (4, 6)
                for network in ipaddress.collapse_addresses(
                    address for address in parsed if address.version == version
                )
            ]
    except (HTTPException, OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    sys.stdout.write("\n".join(addresses) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
