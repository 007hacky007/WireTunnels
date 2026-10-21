#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"

grep -q 'operationTimeoutNanoseconds' "$SERVICE" ||
    { echo "XPC tunnel operations need a bounded timeout" >&2; exit 1; }

for method in startTunnel stopTunnel getWgShowOutput copyConfig; do
    block="$(sed -n "/func ${method}/,/^    }/p" "$SERVICE")"
    grep -q 'performHelperOperation' <<<"$block" ||
        { echo "$method must resume when XPC fails" >&2; exit 1; }
done

grep -q 'remoteObjectProxyWithErrorHandler' "$SERVICE" ||
    { echo "The bounded operation wrapper needs an XPC error handler" >&2; exit 1; }
grep -q 'timeoutTask' "$SERVICE" ||
    { echo "The bounded operation wrapper needs a timeout task" >&2; exit 1; }

echo "XPC tunnel operations are interruption-safe"
