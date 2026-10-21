#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsConfigValidationTest.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    guard condition() else {
        fatalError(message, file: file, line: line)
    }
}

let parser = WireGuardConfigParser()

let missingValues = parser.parse(string: """
[Interface]
DNS = 1.1.1.1

[Peer]
Endpoint = vpn.example.com:51820
""")

require(!missingValues.isValid, "A config missing required values must be invalid")
require(
    Set(missingValues.validationErrors) == [
        .missingPrivateKey,
        .missingAddress,
        .missingPeerPublicKey,
        .missingAllowedIPs
    ],
    "Every missing required value must produce a typed blocking error"
)
require(missingValues.warnings.isEmpty, "Present optional values must not warn")

let malformedSections = parser.parse(string: """
[FakeInterface]
PrivateKey = private-key
Address = 10.0.0.2/32

[NotPeer]
PublicKey = peer-key
AllowedIPs = 0.0.0.0/0
""")

require(!malformedSections.isValid, "Only exact Interface and Peer section names are valid")
require(
    Set(malformedSections.validationErrors) == [
        .missingPrivateKey,
        .missingAddress,
        .missingPeerPublicKey,
        .missingAllowedIPs
    ],
    "Malformed section names must not satisfy required fields"
)

let explicitlyEmpty = parser.parse(string: """
[Interface]
PrivateKey =
Address = , ,
DNS = ,

[Peer]
PublicKey =
Endpoint =
AllowedIPs = ,
""")

require(!explicitlyEmpty.isValid, "Explicitly empty required values must be invalid")
require(
    Set(explicitlyEmpty.validationErrors) == [
        .missingPrivateKey,
        .missingAddress,
        .missingPeerPublicKey,
        .missingAllowedIPs
    ],
    "Empty assignments must be treated as missing required values"
)
require(
    Set(explicitlyEmpty.warnings) == [.missingDNS, .missingEndpoint],
    "Empty optional assignments must retain non-blocking warnings"
)

let warningOnly = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32

[Peer]
PublicKey = first-peer-key
AllowedIPs = 0.0.0.0/0

[Peer]
PublicKey = ignored-peer-key
AllowedIPs = 10.0.0.0/8
""")

require(warningOnly.isValid, "Non-blocking warnings must not invalidate a config")
require(warningOnly.validationErrors.isEmpty, "A valid config must have no blocking errors")
require(
    Set(warningOnly.warnings) == [
        .missingDNS,
        .missingEndpoint,
        .fullTunnel,
        .multiplePeers
    ],
    "DNS, endpoint, full tunnel, and multiple peers must remain warnings"
)

let privilegedHooks = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32
PreUp = touch /tmp/wiretunnels-root-hook

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
PostDown = rm -rf /tmp/example
""")

require(!privilegedHooks.isValid, "wg-quick shell hooks must be rejected")
require(
    Set(privilegedHooks.validationErrors) == [
        .unsupportedDirective("PreUp"),
        .unsupportedDirective("PostDown")
    ],
    "Every privileged hook directive must produce a blocking validation error"
)

print("Configuration validation checks passed")
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnels/Services/WireGuardConfigParser.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_config_validation"

"${TEST_DIR}/test_config_validation"
