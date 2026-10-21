#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"
PROTO_APP="$ROOT_DIR/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift"
PROTO_HELPER="$ROOT_DIR/WireTunnelsHelper/WireguardHelperProtocol.swift"
COMMAND_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
TUNNEL="$ROOT_DIR/WireTunnels/Models/Tunnel.swift"
WARNING="$ROOT_DIR/WireTunnels/Models/TunnelWarning.swift"

diff "$PROTO_APP" "$PROTO_HELPER" >/dev/null ||
    { echo "Both WireguardHelperProtocol.swift copies must stay byte-identical" >&2; exit 1; }
grep -q 'func syncKillSwitch(entries: Data, reply: @escaping (Bool, String?) -> Void)' "$PROTO_APP" ||
    { echo "XPC protocol must expose syncKillSwitch" >&2; exit 1; }

grep -q 'func syncKillSwitch(entries: Data, reply: @escaping (Bool, String?) -> Void)' "$HELPER" ||
    { echo "HelperTool must implement syncKillSwitch" >&2; exit 1; }
grep -q 'isValidInterfaceName' "$HELPER" && grep -q 'isValidIPLiteral' "$HELPER" ||
    { echo "Kill switch entries must be validated before building PF rules" >&2; exit 1; }
grep -q '(1...65535).contains(entry.endpointPort)' "$HELPER" ||
    { echo "Kill switch must validate the endpoint port range" >&2; exit 1; }
if grep -q 'pfctl.*"-d"' "$HELPER"; then
    echo "Kill switch must never disable PF globally, only flush its own anchor" >&2
    exit 1
fi
grep -q '"-F", "all"' "$HELPER" ||
    { echo "Disabling the kill switch must flush its own anchor" >&2; exit 1; }

grep -q 'func syncKillSwitch(entries: \[KillSwitchEntry\]) async throws' "$COMMAND_SERVICE" ||
    { echo "WireGuardCommandService must expose a client-side syncKillSwitch" >&2; exit 1; }

grep -q 'var killSwitchEnabled: Bool' "$TUNNEL" ||
    { echo "Tunnel must have a killSwitchEnabled field" >&2; exit 1; }
grep -q 'var isKillSwitchEnabled: Bool' "$TUNNEL" ||
    { echo "Tunnel must expose a scope-aware isKillSwitchEnabled accessor" >&2; exit 1; }
grep -q 'decodeIfPresent(Bool.self, forKey: .killSwitchEnabled) ?? false' "$TUNNEL" ||
    { echo "killSwitchEnabled must decode with a false fallback for old saved tunnels" >&2; exit 1; }

grep -q 'private var killSwitchArmedTunnelIDs: Set<UUID>' "$MANAGER" ||
    { echo "TunnelManager must track which tunnels are currently kill-switch armed" >&2; exit 1; }
grep -q 'func updateKillSwitch(for tunnel: Tunnel, enabled: Bool)' "$MANAGER" ||
    { echo "TunnelManager must expose a personal-tunnel kill switch toggle" >&2; exit 1; }
grep -q 'func updateManagedKillSwitch(for tunnel: Tunnel, enabled: Bool) async throws' "$MANAGER" ||
    { echo "TunnelManager must expose an admin-gated managed kill switch toggle" >&2; exit 1; }
grep -q 'Only an administrator can change the kill switch for a shared tunnel' "$MANAGER" ||
    { echo "Managed kill switch changes must be admin-gated" >&2; exit 1; }

# The unexpected-drop branch must NOT disarm the kill switch — that's the feature.
awk '/\/\/ Not in wg show → not active/,/^            }$/' "$MANAGER" > /tmp/wiretunnels_drop_branch.$$
if grep -q 'killSwitchArmedTunnelIDs.remove' /tmp/wiretunnels_drop_branch.$$; then
    echo "Kill switch must stay armed through an unexpected drop, not be disarmed" >&2
    rm -f /tmp/wiretunnels_drop_branch.$$
    exit 1
fi
rm -f /tmp/wiretunnels_drop_branch.$$

grep -q 'killSwitchArmedTunnelIDs.removeAll()' "$MANAGER" ||
    { echo "App launch must flush stale kill switch state before polling starts" >&2; exit 1; }

grep -q 'case killSwitchBlocking(String)' "$WARNING" ||
    { echo "TunnelWarning must have a killSwitchBlocking case" >&2; exit 1; }

echo "Kill switch checks passed"
