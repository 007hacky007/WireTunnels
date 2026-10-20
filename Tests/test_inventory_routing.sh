#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wiretunnels-inventory-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "$test_dir/modules" \
    Shared/InventoryRouting.swift \
    WireTunnels/Models/AutoConnectRule.swift WireTunnels/Models/Tunnel.swift \
    WireTunnels/Services/InventoryCommandService.swift \
    WireTunnels/Services/WireGuardConfigParser.swift WireTunnels/Services/TunnelInventoryIntegration.swift \
    WireTunnelsHelper/InventoryRouteSocket.swift WireTunnelsHelper/InventoryRoutingService.swift \
    Tests/InventoryAppFixture.swift Tests/InventoryRoutingTests.swift -o "$test_dir/tests"
"$test_dir/tests"
