#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MENU_BAR_VIEW="${ROOT_DIR}/WireTunnels/Views/MenuBar/MenuBarView.swift"

grep -q "SettingsLink" "${MENU_BAR_VIEW}"
