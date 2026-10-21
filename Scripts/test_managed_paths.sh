#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

grep -q 'managedRoot' "${ROOT_DIR}/WireTunnels/Services/AppPaths.swift"
grep -q 'managedConfigDir' "${ROOT_DIR}/WireTunnels/Services/AppPaths.swift"
grep -q 'managedMetadataFile' "${ROOT_DIR}/WireTunnels/Services/AppPaths.swift"
grep -q 'managedRoot' "${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
grep -q 'managedConfigDir' "${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
grep -q 'managedMetadataFile' "${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"

echo "Managed path checks passed"
