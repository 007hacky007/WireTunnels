#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/WireTunnels.xcodeproj/project.pbxproj"
APP="$ROOT_DIR/WireTunnels/WireTunnelsApp.swift"

if grep -q 'INFOPLIST_KEY_LSUIElement = YES;' "$PROJECT"; then
    echo "WireTunnels must be a regular Dock application" >&2
    exit 1
fi

grep -q 'Window("WireTunnels", id: "dashboard")' "$APP" ||
    { echo "The Dock must reopen the singleton Dashboard window" >&2; exit 1; }

echo "Dock application behavior checks passed"
