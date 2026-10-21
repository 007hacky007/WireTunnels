#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
DETAIL="$ROOT_DIR/WireTunnels/Views/Dashboard/TunnelDetailView.swift"
SETUP="$ROOT_DIR/WireTunnels/Views/Dashboard/SetupWizardView.swift"

grep -q 'var updatedTunnels = tunnels' "$MANAGER" ||
    { echo "Status refresh must batch tunnel mutations" >&2; exit 1; }
grep -q 'if updatedTunnels != tunnels' "$MANAGER" ||
    { echo "Status refresh must publish only meaningful tunnel changes" >&2; exit 1; }
! grep -q 'Traffic sample #' "$MANAGER" ||
    { echo "Polling must not append a visible log entry for every traffic sample" >&2; exit 1; }
grep -q 'refreshHelperRegistrationStatus' "$SETUP" ||
    { echo "Setup polling must use the lightweight helper status path" >&2; exit 1; }
grep -q 'ConfigEditorSheetView(tunnel: live)' "$DETAIL" ||
    { echo "The config editor must receive the current tunnel value" >&2; exit 1; }

echo "SwiftUI performance guardrails passed"
