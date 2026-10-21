#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"

if ! grep -q 'helperCheckTimeoutNanoseconds: UInt64 = 3_000_000_000' "$SERVICE"; then
    echo "Helper health check must define a three-second timeout" >&2
    exit 1
fi

if ! grep -q 'CommandError.helperCheckTimedOut' "$SERVICE"; then
    echo "Helper health check must resume with a timeout error" >&2
    exit 1
fi

echo "Helper health check has a bounded timeout"
