#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsAppRoutingModel.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

// Round trip.
let rule = AppRoutingRule(
    bundleIdentifier: "com.example.App",
    appName: "Example",
    appPath: "/Applications/Example.app",
    tunnelID: UUID(),
    isEnabled: false,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
)
let decoded = try decoder.decode(AppRoutingRule.self, from: encoder.encode(rule))
check(decoded == rule, "rule must round-trip")
check(decoded.schemaVersion == AppRoutingRule.currentSchemaVersion, "schema version must round-trip")
check(decoded.isEnabled == false, "isEnabled must round-trip")

// Minimal legacy JSON: only required keys.
let minimal = """
{
  "id": "B4D9A9BE-A3DB-4E9E-84F0-546DFC7EF630",
  "bundleIdentifier": "com.example.Legacy",
  "appName": "Legacy",
  "appPath": "/Applications/Legacy.app",
  "tunnelID": "0E1A3F55-2C0B-4C57-BF65-6F8D8C2E7C11"
}
"""
let legacy = try decoder.decode(AppRoutingRule.self, from: Data(minimal.utf8))
check(legacy.schemaVersion == 1, "missing schemaVersion must default to 1")
check(legacy.isEnabled == true, "missing isEnabled must default to true")
check(legacy.onTunnelDown == .block, "missing onTunnelDown must default to block")

// Unknown fallback value: must not silently become something permissive. Either the decode
// fails (rule skipped by the repository, never applied) or it maps to .block.
let unknown = """
{
  "id": "B4D9A9BE-A3DB-4E9E-84F0-546DFC7EF631",
  "bundleIdentifier": "com.example.Future",
  "appName": "Future",
  "appPath": "/Applications/Future.app",
  "tunnelID": "0E1A3F55-2C0B-4C57-BF65-6F8D8C2E7C11",
  "onTunnelDown": "allowDirect"
}
"""
if let future = try? decoder.decode(AppRoutingRule.self, from: Data(unknown.utf8)) {
    check(future.onTunnelDown == .block, "unknown fallback must never decode as a non-blocking value")
}

// Required keys missing => decode failure (so the repository skips instead of inventing a rule).
check((try? decoder.decode(AppRoutingRule.self, from: Data("{}".utf8))) == nil, "empty object must not decode")
print("OK")
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnels/Models/AppRoutingRule.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_app_routing_model"

"${TEST_DIR}/test_app_routing_model"
