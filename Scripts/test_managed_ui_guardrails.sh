#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROW="${ROOT_DIR}/WireTunnels/Views/Dashboard/TunnelRowView.swift"
DETAIL="${ROOT_DIR}/WireTunnels/Views/Dashboard/TunnelDetailView.swift"
IMPORT="${ROOT_DIR}/WireTunnels/Views/Config/ImportConfigView.swift"
MANAGER="${ROOT_DIR}/WireTunnels/Services/TunnelManager.swift"
LIST="${ROOT_DIR}/WireTunnels/Views/Dashboard/TunnelListView.swift"
DASHBOARD="${ROOT_DIR}/WireTunnels/Views/Dashboard/MainDashboardView.swift"

grep -q 'lock.fill' "$ROW"
grep -q 'Shared' "$ROW"
grep -q 'Visible to all users' "$DETAIL"
grep -q 'Make Shared' "$DETAIL"
grep -q 'Connected Users' "$DETAIL"
grep -q 'currentUserIsAdministrator' "$DETAIL"
grep -q 'deleteManagedTunnel' "$DETAIL"
grep -q 'ImportDestination' "$IMPORT"
grep -q 'importManagedConfig' "$IMPORT"
grep -q 'case shared = "Shared"' "$DASHBOARD"
grep -q 'sharedTunnels' "$LIST"
grep -q 'await loadManagedTunnels()' "$MANAGER"
grep -q 'helperNeedsReplacement(version:' "$MANAGER"
grep -q 'helperProtocolRevision' "${ROOT_DIR}/WireTunnels/Services/WireGuardCommandService.swift"
grep -q 'savePersonalTunnelsOnly' "$MANAGER"
! grep -q 'repository.save(tunnels)' "$MANAGER"

echo "Managed UI guardrail checks passed"
