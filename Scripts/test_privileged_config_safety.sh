#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"

grep -q 'validateConfigContents(contents)' "$HELPER" ||
    { echo "Helper must validate staged config contents independently" >&2; exit 1; }
runtime_validation_count="$(grep -c 'validateConfigContents(contents)' "$HELPER")"
[ "$runtime_validation_count" -ge 2 ] ||
    { echo "Helper must also revalidate existing runtime configs before execution" >&2; exit 1; }
grep -q '"preup", "postup", "predown", "postdown"' "$HELPER" ||
    { echo "Helper must reject every wg-quick shell hook" >&2; exit 1; }
grep -q 'DispatchQueue.global(qos: .utility).async' "$HELPER" &&
grep -q 'readDataToEndOfFile()' "$HELPER" ||
    { echo "Helper must drain command pipes while the child process is running" >&2; exit 1; }

echo "Privileged config and process safety checks passed"
