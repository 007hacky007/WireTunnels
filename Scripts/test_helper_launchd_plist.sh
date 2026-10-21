#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT_DIR/WireTunnelsHelper/com.fmdigitech.WireTunnels.helper.plist"
EXPECTED_PROGRAM="Contents/Library/LaunchDaemons/com.fmdigitech.WireTunnels.helper"

actual_program=$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$PLIST" 2>/dev/null || true)

if [[ "$actual_program" != "$EXPECTED_PROGRAM" ]]; then
    echo "Expected BundleProgram '$EXPECTED_PROGRAM', got '${actual_program:-<missing>}'" >&2
    exit 1
fi

if /usr/libexec/PlistBuddy -c "Print :Program" "$PLIST" >/dev/null 2>&1; then
    echo "Legacy Program key must not be present for an SMAppService daemon" >&2
    exit 1
fi

echo "Helper launchd plist is configured for SMAppService"

if [[ $# -gt 0 ]]; then
    helper="$1/Contents/Library/LaunchDaemons/com.fmdigitech.WireTunnels.helper"
    identifier=$(codesign -dv --verbose=4 "$helper" 2>&1 | sed -n 's/^Identifier=//p')

    if [[ "$identifier" != "com.fmdigitech.WireTunnels.helper" ]]; then
        echo "Expected helper signing identifier, got '${identifier:-<missing>}'" >&2
        exit 1
    fi

    echo "Embedded helper has the correct signing identifier"
fi
