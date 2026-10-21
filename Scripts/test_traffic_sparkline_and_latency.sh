#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROW="$ROOT_DIR/WireTunnels/Views/Dashboard/TunnelRowView.swift"
DETAIL="$ROOT_DIR/WireTunnels/Views/Dashboard/TunnelDetailView.swift"
PING="$ROOT_DIR/WireTunnels/Services/PingService.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"

grep -q '^import Charts' "$ROW" ||
    { echo "TunnelRowView must import Charts for the sparkline" >&2; exit 1; }
grep -q 'if tunnel.isActive, !trafficSamples.isEmpty {' "$ROW" ||
    { echo "Sparkline must be gated on isActive and non-empty samples" >&2; exit 1; }
grep -q 'tunnelManager.trafficHistory\[tunnel.id\]' "$ROW" ||
    { echo "Sparkline must reuse the existing trafficHistory data, not collect its own" >&2; exit 1; }

test -f "$PING" ||
    { echo "PingService.swift must exist" >&2; exit 1; }
grep -q 'nonisolated static func measureLatency(host: String) -> \[Double\]' "$PING" ||
    { echo "PingService must expose measureLatency(host:)" >&2; exit 1; }
grep -q '"/sbin/ping"' "$PING" ||
    { echo "PingService must use the system ping binary" >&2; exit 1; }

grep -q 'func testConnection(for tunnel: Tunnel) async -> ConnectionTestResult' "$MANAGER" ||
    { echo "TunnelManager must expose testConnection(for:)" >&2; exit 1; }
grep -q 'guard let endpoint = tunnel.endpoint, let parsed = Self.parseEndpoint(endpoint)' "$MANAGER" ||
    { echo "testConnection must reuse the existing parseEndpoint helper, not a duplicate parser" >&2; exit 1; }

grep -q 'Label("Test Connection"' "$DETAIL" ||
    { echo "TunnelDetailView must offer a Test Connection action" >&2; exit 1; }
grep -q '.disabled(!live.isActive || isTestingConnection)' "$DETAIL" ||
    { echo "Test Connection must be disabled while the tunnel is inactive" >&2; exit 1; }

# Guard against silently reintroducing a third-party download-speed probe, which
# the user explicitly declined in favor of latency-only, own-endpoint-only testing.
for f in "$PING" "$MANAGER" "$DETAIL" "$ROW"; do
    if grep -qE 'https?://' "$f"; then
        echo "$f must not contain a hardcoded external URL — speed test is latency-only against the tunnel's own endpoint" >&2
        exit 1
    fi
done

echo "Traffic sparkline and latency test checks passed"
