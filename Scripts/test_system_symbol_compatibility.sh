#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"

if grep -q 'folder\.badge\.magnifyingglass' "$SETTINGS"; then
    echo "Settings must not use the unavailable folder.badge.magnifyingglass symbol" >&2
    exit 1
fi

grep -q 'Label("Reveal in Finder", systemImage: "folder")' "$SETTINGS" ||
    { echo "Reveal in Finder must use a compatible folder symbol" >&2; exit 1; }

echo "System symbol compatibility checks passed"
