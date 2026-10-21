#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsModelTest.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" -typecheck \
    "${ROOT_DIR}/WireTunnels/Models/AutoConnectRule.swift" \
    "${ROOT_DIR}/WireTunnels/Models/Tunnel.swift"

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

let legacyJSON = """
{
  "id": "B4D9A9BE-A3DB-4E9E-84F0-546DFC7EF630",
  "name": "Legacy",
  "configPath": "/tmp/legacy.conf",
  "isActive": false,
  "isFavorite": false,
  "autostart": false,
  "allowedIPs": [],
  "dns": [],
  "rxBytes": 0,
  "txBytes": 0,
  "createdAt": "2026-06-12T12:00:00Z",
  "updatedAt": "2026-06-12T12:00:00Z"
}
"""

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let tunnel = try decoder.decode(Tunnel.self, from: Data(legacyJSON.utf8))

guard tunnel.autoConnectRule == AutoConnectRule() else {
    fatalError("Legacy tunnels must receive the default auto-connect rule")
}
guard tunnel.scope == .personal else {
    fatalError("Legacy tunnels must default to personal scope")
}
guard tunnel.managedPolicy == nil else {
    fatalError("Legacy personal tunnels must not receive managed policy")
}

var managed = Tunnel(name: "Managed", configPath: "/Library/Application Support/WireTunnels/managed/configs/Managed.conf")
managed.scope = .managed
managed.managedPolicy = ManagedTunnelPolicy(usersCanConnect: true, usersCanDisconnect: false)
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let managedData = try encoder.encode(managed)
let decodedManaged = try decoder.decode(Tunnel.self, from: managedData)
guard decodedManaged.scope == .managed,
      decodedManaged.managedPolicy?.usersCanDisconnect == false else {
    fatalError("Managed tunnel scope and policy must round-trip")
}

let legacyRuleJSON = """
{
  "enabled": true,
  "interface": "wifi",
  "wifiSSIDs": ["Office"]
}
"""

let legacyRule = try decoder.decode(AutoConnectRule.self, from: Data(legacyRuleJSON.utf8))
guard legacyRule.action == .connect else {
    fatalError("Saved on-demand rules without an action must default to connect")
}

let blacklistRule = AutoConnectRule(
    enabled: true,
    interface: .wifi,
    action: .disconnect,
    wifiSSIDs: ["Office"]
)
guard blacklistRule.action == .disconnect else {
    fatalError("On-demand rules must support disconnect blacklist mode")
}
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnels/Models/AutoConnectRule.swift" \
    "${ROOT_DIR}/WireTunnels/Models/Tunnel.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_tunnel_model"

"${TEST_DIR}/test_tunnel_model"
