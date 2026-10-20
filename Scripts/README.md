# Server inventory example

`server_ips.py` uses Python 3's standard library to turn a JSON server inventory
into IP addresses or exact CIDR ranges suitable for preparing `AllowedIPs`.
Supply your own inventory URL; the hostname below is a placeholder.

```sh
# One IP per line, preserving input order, duplicates and IPv6 spelling.
python3 Scripts/server_ips.py https://inventory.example.com/servers.json

# Deduplicate and merge into the largest CIDRs covering exactly the input IPs.
python3 Scripts/server_ips.py https://inventory.example.com/servers.json --merge
```

The inventory must be a JSON object whose values are server records. Each record
must have an `ip_all` string containing comma-separated IPv4 and/or IPv6 addresses.
Empty strings are allowed. See [examples/servers.json](examples/servers.json) for
a complete example using documentation-only addresses.

Run the bundled example locally from the repository root:

```sh
python3 Scripts/server_ips.py "file://$PWD/Scripts/examples/servers.json" --merge
```

Expected output:

```text
192.0.2.4/30
2001:db8::2/127
```

Merged output is sorted with IPv4 before IPv6. Aggregation never fills gaps or
includes addresses absent from the inventory. Isolated addresses become `/32`
or `/128` prefixes.

The script validates the entire inventory before writing output. Missing fields,
invalid or scoped addresses, empty inventories and fetch failures produce an error
on stderr and exit status 1. Network operations use a 30-second socket timeout.
Automation should check the exit status and retain its last good inventory on
failure. Updating a running tunnel and enforcing routing policy are separate
integration work.

Run the regression tests from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_server_ips.py' -v
```
