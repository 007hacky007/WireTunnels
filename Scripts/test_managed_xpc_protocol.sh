#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PROTOCOL="${ROOT_DIR}/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift"
HELPER_PROTOCOL="${ROOT_DIR}/WireTunnelsHelper/WireguardHelperProtocol.swift"

for method in \
    listManagedTunnels \
    installManagedTunnel \
    updateManagedTunnel \
    deleteManagedTunnel \
    stageManagedConfig \
    markManagedTunnelConnected \
    markManagedTunnelDisconnected \
    listManagedTunnelUsers \
    helperProtocolRevision
do
    grep -q "func ${method}" "$APP_PROTOCOL"
    grep -q "func ${method}" "$HELPER_PROTOCOL"
done

for method in installManagedTunnel updateManagedTunnel deleteManagedTunnel
do
    grep -q "func ${method}.*authorization: Data" "$APP_PROTOCOL"
    grep -q "func ${method}.*authorization: Data" "$HELPER_PROTOCOL"
done

grep -q "func listManagedTunnelUsers.*authorization: Data" "$APP_PROTOCOL"
grep -q "func listManagedTunnelUsers.*authorization: Data" "$HELPER_PROTOCOL"

echo "Managed XPC protocol checks passed"
