#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WG_QUICK="${1:-${ROOT_DIR}/build/wireguard-cache/wg-quick}"
XCODE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

PATH="$XCODE_PATH" /bin/bash \
    "${ROOT_DIR}/Scripts/test_wg_quick_bash3.sh" "$WG_QUICK"
PATH="$XCODE_PATH" /bin/bash \
    "${ROOT_DIR}/Scripts/test_wg_quick_dns_cleanup.sh" "$WG_QUICK"

echo "wg-quick validators run with Xcode's restricted PATH"
