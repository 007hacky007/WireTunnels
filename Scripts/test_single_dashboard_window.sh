#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/WireTunnels/WireTunnelsApp.swift"

grep -q 'Window("WireTunnels", id: "dashboard")' "$APP" ||
    { echo "Dashboard must use a single Window scene" >&2; exit 1; }

if grep -q 'WindowGroup("WireTunnels", id: "dashboard")' "$APP"; then
    echo "Dashboard must not create a new window for every open request" >&2
    exit 1
fi

echo "Single dashboard window checks passed"
