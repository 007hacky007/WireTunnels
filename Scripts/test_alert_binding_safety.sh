#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for view in \
    "$ROOT_DIR/WireTunnels/Views/MenuBar/MenuBarView.swift" \
    "$ROOT_DIR/WireTunnels/Views/Dashboard/MainDashboardView.swift" \
    "$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"; do
    block="$(sed -n '/private var managerErrorBinding/,/^    }/p' "$view")"
    grep -q 'DispatchQueue.main.async' <<<"$block" ||
        { echo "$(basename "$view") must defer shared error mutation outside SwiftUI updates" >&2; exit 1; }
done

echo "Shared alert bindings defer published-state mutations"
