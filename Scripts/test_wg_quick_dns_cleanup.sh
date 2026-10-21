#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WG_QUICK="${1:-${ROOT_DIR}/build/wireguard-cache/wg-quick}"

if [[ ! -f "$WG_QUICK" ]]; then
    echo "wg-quick not found: $WG_QUICK" >&2
    exit 1
fi

/usr/bin/grep -Fq 'DNS_STATE_DIR=' "$WG_QUICK" || {
    echo "wg-quick does not persist the pre-tunnel DNS state" >&2
    exit 1
}

cmd_down=$(
    sed -n '/^cmd_down() {/,/^}/p' "$WG_QUICK"
)

[[ "$cmd_down" == *"del_dns"* ]] || {
    echo "wg-quick down does not restore DNS synchronously" >&2
    exit 1
}

if /usr/bin/grep -Fq 'sleep 2 && set_dns &' "$WG_QUICK"; then
    echo "wg-quick can reapply VPN DNS from an orphaned delayed process" >&2
    exit 1
fi

echo "wg-quick restores DNS during tunnel shutdown"
