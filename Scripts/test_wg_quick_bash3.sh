#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WG_QUICK="${1:-${ROOT_DIR}/build/wireguard-cache/wg-quick}"

if [[ ! -f "$WG_QUICK" ]]; then
    echo "wg-quick not found: $WG_QUICK" >&2
    exit 1
fi

output=$(/bin/bash "$WG_QUICK" --help 2>&1) || {
    echo "$output" >&2
    exit 1
}

if [[ "$output" == *"Version mismatch"* ]]; then
    echo "wg-quick still requires Bash 4+" >&2
    exit 1
fi

[[ "$output" == *"Usage: wg-quick"* ]] || {
    echo "wg-quick did not produce its help output under macOS Bash 3" >&2
    echo "$output" >&2
    exit 1
}

if /usr/bin/grep -Eq 'declare -A|local -A|\$BASHPID' "$WG_QUICK"; then
    echo "wg-quick still contains Bash 4-only constructs" >&2
    exit 1
fi

echo "wg-quick is compatible with macOS Bash 3"
