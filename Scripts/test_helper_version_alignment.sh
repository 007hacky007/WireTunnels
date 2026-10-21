#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SERVICE="${ROOT_DIR}/WireTunnels/Services/WireGuardCommandService.swift"
HELPER="${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
PLIST="${ROOT_DIR}/WireTunnelsHelper/com.fmdigitech.WireTunnels.helper-Info.plist"

expected=$(sed -n 's/.*expectedHelperVersion = "\([^"]*\)".*/\1/p' "$APP_SERVICE")
reported=$(sed -n 's/.*helperVersionNumber = "\([^"]*\)".*/\1/p' "$HELPER")
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
expected_revision=$(sed -n 's/.*expectedHelperProtocolRevision = "\([^"]*\)".*/\1/p' "$APP_SERVICE")
reported_revision=$(sed -n 's/.*helperProtocolRevisionValue = "\([^"]*\)".*/\1/p' "$HELPER")

test -n "$expected"
test "$expected" = "$reported"
test "$expected" = "$plist_version"
test -n "$expected_revision"
test "$expected_revision" = "$reported_revision"

echo "Helper version alignment checks passed"
