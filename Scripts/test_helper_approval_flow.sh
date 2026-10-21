#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
SETTINGS="$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"

grep -q 'daemonService.status == .requiresApproval' "$SERVICE" ||
    { echo "Service must expose requiresApproval status" >&2; exit 1; }
grep -q 'SMAppService.openSystemSettingsLoginItems()' "$SERVICE" ||
    { echo "Service must open Login Items settings" >&2; exit 1; }
grep -q '@Published var helperRequiresApproval' "$MANAGER" ||
    { echo "Manager must publish helper approval state" >&2; exit 1; }
grep -q 'Enable Helper' "$SETTINGS" ||
    { echo "Settings must present an Enable Helper action" >&2; exit 1; }

echo "Helper approval flow is exposed in the UI"
