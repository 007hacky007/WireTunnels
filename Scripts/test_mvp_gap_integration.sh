#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
IMPORT="$ROOT_DIR/WireTunnels/Views/Config/ImportConfigView.swift"
NEW_TUNNEL="$ROOT_DIR/WireTunnels/Views/Config/NewTunnelView.swift"
DASHBOARD="$ROOT_DIR/WireTunnels/Views/Dashboard/MainDashboardView.swift"
SETTINGS="$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"

test "$(grep -c 'guard parsed\.isValid' "$MANAGER")" -ge 3 ||
    { echo "Import, create, and update must reject invalid configurations" >&2; exit 1; }
grep -q 'parsed\.warnings' "$IMPORT" ||
    { echo "Import UI must display warnings from the selected config" >&2; exit 1; }
grep -q 'guard await statusMonitor\.refresh()' "$MANAGER" ||
    { echo "Tunnel state must only change after a successful status refresh" >&2; exit 1; }
grep -q 'NotificationService' "$MANAGER" ||
    { echo "Tunnel operations must emit user notifications" >&2; exit 1; }
grep -q 'showRawOutput' "$MANAGER" ||
    { echo "Status refresh must honor the raw output preference" >&2; exit 1; }
grep -q 'resetUserData' "$MANAGER" ||
    { echo "TunnelManager must clear its in-memory state after app-data reset" >&2; exit 1; }
grep -q 'generateKeyPair' "$NEW_TUNNEL" ||
    { echo "New Tunnel must generate a WireGuard key pair" >&2; exit 1; }
grep -q 'tunnelManager\.errorMessage' "$DASHBOARD" ||
    { echo "Dashboard must present app-wide operation errors" >&2; exit 1; }
grep -q 'resetUserData' "$SETTINGS" ||
    { echo "Settings reset must synchronize TunnelManager state" >&2; exit 1; }

echo "MVP gap integration checks passed"
