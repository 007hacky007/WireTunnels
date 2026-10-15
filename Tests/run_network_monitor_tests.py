#!/usr/bin/env python3
"""Exercise physical-network rules against controlled VPN route observations."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix='wiretunnels-network-tests-') as temporary:
    directory = Path(temporary)
    monitor = (ROOT / 'WireTunnels/Services/NetworkMonitorService.swift').read_text()
    fixture = directory / 'PhysicalNetworkMonitorFixture.swift'
    fixture.write_text((ROOT / 'Tests/PhysicalNetworkMonitorTests.swift').read_text()
        .replace('// PRODUCTION_NETWORK_MONITOR', monitor.replace('import Network\n', '')))
    executable = directory / 'network-monitor-tests'
    subprocess.run([
        'swiftc', '-module-cache-path', str(directory / 'module-cache'),
        str(ROOT / 'WireTunnels/Models/AutoConnectRule.swift'),
        str(ROOT / 'WireTunnels/Models/Tunnel.swift'),
        str(fixture), '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
