#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROW="$ROOT_DIR/WireTunnels/Views/Dashboard/TunnelRowView.swift"
DETAIL="$ROOT_DIR/WireTunnels/Views/Dashboard/TunnelDetailView.swift"
MENU="$ROOT_DIR/WireTunnels/Views/MenuBar/MenuBarView.swift"

grep -q 'Toggle(isOn: connectionBinding)' "$ROW" ||
    { echo "Dashboard tunnel rows must use a connection switch" >&2; exit 1; }
grep -q 'Toggle(isOn: connectionBinding)' "$DETAIL" ||
    { echo "Dashboard tunnel details must use a connection switch" >&2; exit 1; }
test "$(grep -c 'Toggle(isOn:' "$MENU")" -ge 2 ||
    { echo "Menu-bar tunnel rows must use connection switches" >&2; exit 1; }

grep -q '\.toggleStyle(\.switch)' "$ROW" ||
    { echo "Dashboard row connection control must use switch styling" >&2; exit 1; }
grep -q '\.toggleStyle(\.switch)' "$DETAIL" ||
    { echo "Dashboard detail connection control must use switch styling" >&2; exit 1; }

if grep -Fq 'Text(tunnel.isActive ? "Disconnect" : "Connect")' "$ROW" ||
    grep -Fq 'Text(live.isActive ? "Disconnect" : "Connect")' "$DETAIL" ||
    grep -Fq 'Button(isActive ? "Disconnect" : "Connect")' "$MENU" ||
    grep -Fq 'Button("Disconnect", action: action)' "$MENU"; then
    echo "Per-tunnel Connect/Disconnect buttons must be replaced by switches" >&2
    exit 1
fi

echo "Tunnel connection switch checks passed"
